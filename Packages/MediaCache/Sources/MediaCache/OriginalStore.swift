import Core
import Foundation
import CloudCore

/// Downloads a URL straight to a temporary file, reporting progress 0...1. Replaced in tests.
public protocol FileDownloader: Sendable {
    func download(_ request: URLRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// `URLSession` download tasks: bytes go to disk, so large originals and videos never sit in memory.
public struct URLSessionFileDownloader: FileDownloader {
    let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    public func download(_ request: URLRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    if let error = error as? URLError {
                        if error.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: MediaError(kind: .network, message: "Downloading the original failed: \(NetworkErrorDescription.describe(error))"))
                        }
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let location, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: MediaError(kind: .server, message: "The server sent an unexpected response for the original."))
                        return
                    }
                    guard http.statusCode == 200 else {
                        let kind: MediaError.Kind = http.statusCode == 401 ? .unauthorized : http.statusCode == 404 ? .notFound : .server
                        continuation.resume(throwing: MediaError(kind: kind, message: "The server returned \(http.statusCode) for the original."))
                        return
                    }
                    // The system deletes `location` when this handler returns, so move it now.
                    let kept = FileManager.default.temporaryDirectory.appending(path: "original-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    progress(value.fractionCompleted)
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }
}

/// Original files from the server (`GET /assets/{id}/original`), kept on disk under
/// their original file name so sharing them keeps the name and all metadata.
/// Downloads are shared per asset, limited to two at a time, cancelled when nobody
/// waits, and the store is trimmed oldest-first to a size limit.
public actor OriginalStore {
    public typealias SourceProvider = @Sendable () async -> MediaSource?

    private nonisolated let directory: URL
    /// Kept Offline: originals that stay until they're no longer wanted (never trimmed).
    private nonisolated let offlineDirectory: URL?
    private let downloader: any FileDownloader
    private let source: SourceProvider
    private let limiter = RequestLimiter(limit: 2)
    private nonisolated let trimmer: DiskCache

    private struct InFlight {
        let id = UUID()
        let task: Task<URL, any Error>
        var waiters: Int
        let progress: ProgressRelay
    }
    private var inFlight: [String: InFlight] = [:]

    public init(directory: URL, offlineDirectory: URL? = nil, downloader: any FileDownloader, source: @escaping SourceProvider) {
        self.directory = directory
        self.offlineDirectory = offlineDirectory
        self.downloader = downloader
        self.source = source
        trimmer = DiskCache(directory: directory)
    }

    /// The original if it's already on the phone (kept offline, or cached).
    public nonisolated func cachedFile(assetID: String) -> URL? {
        if let offlineDirectory, let kept = Self.firstFile(in: Self.folder(for: assetID, in: offlineDirectory)) { return kept }
        let folder = folder(for: assetID)
        guard let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path).first(where: { !$0.hasPrefix(".") }) else {
            return nil
        }
        let url = folder.appending(path: name)
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
        return url
    }

    /// The original on disk, downloading it if needed. `progress` receives 0...1.
    public func file(
        assetID: String,
        fileName: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        if let cached = cachedFile(assetID: assetID) { return cached }

        let entry: InFlight
        if var existing = inFlight[assetID] {
            existing.waiters += 1
            inFlight[assetID] = existing
            entry = existing
        } else {
            let relay = ProgressRelay()
            let destinationFolder = folder(for: assetID)
            let safeName = Self.safeFileName(fileName, fallback: assetID)
            let task = Task { [limiter, downloader, source] in
                try await limiter.run(priority: .visible) {
                    guard let current = await source() else { throw MediaError.offline }
                    let temp = try await downloader.download(current.originalRequest(assetID: assetID)) { value in
                        relay.send(value)
                    }
                    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                    let destination = destinationFolder.appending(path: safeName)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    return destination
                }
            }
            entry = InFlight(task: task, waiters: 1, progress: relay)
            inFlight[assetID] = entry
        }
        entry.progress.add(progress)

        return try await withTaskCancellationHandler {
            defer { finished(assetID, id: entry.id) }
            return try await entry.task.value
        } onCancel: {
            Task { await self.waiterCancelled(assetID, id: entry.id) }
        }
    }

    // MARK: Keep Offline

    /// Keeps the original on this iPhone until `removeOffline` (moved from the cache if it's
    /// there, else downloaded when nothing more urgent is waiting).
    public func keepOffline(assetID: String, fileName: String) async throws {
        guard let offlineDirectory else { return }
        let target = Self.folder(for: assetID, in: offlineDirectory)
        if Self.firstFile(in: target) != nil { return }
        let safeName = Self.safeFileName(fileName, fallback: assetID)
        let cachedFolder = folder(for: assetID)
        try FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
        if Self.firstFile(in: cachedFolder) != nil, (try? FileManager.default.moveItem(at: cachedFolder, to: target)) != nil {
            return
        }
        let temp = try await limiter.run(priority: .background) { [downloader, source] in
            guard let current = await source() else { throw MediaError.offline }
            return try await downloader.download(current.originalRequest(assetID: assetID)) { _ in }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let destination = target.appending(path: safeName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// Asset IDs kept offline.
    public nonisolated func offlineAssetIDs() -> Set<String> {
        guard let offlineDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: offlineDirectory.path) else { return [] }
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    /// No longer kept offline: back into the ordinary cache, so it can be trimmed.
    public func removeOffline(_ assetIDs: some Sequence<String>) {
        guard let offlineDirectory else { return }
        for id in assetIDs {
            let kept = Self.folder(for: id, in: offlineDirectory)
            let cached = folder(for: id)
            if (try? FileManager.default.moveItem(at: kept, to: cached)) == nil {
                try? FileManager.default.removeItem(at: kept)
            }
        }
    }

    public nonisolated func offlineSize() -> Int {
        guard let offlineDirectory else { return 0 }
        return DiskCache(directory: offlineDirectory).size()
    }

    private static func folder(for assetID: String, in directory: URL) -> URL {
        directory.appending(path: assetID.replacingOccurrences(of: "/", with: "_"), directoryHint: .isDirectory)
    }

    private static func firstFile(in folder: URL) -> URL? {
        guard let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path).first(where: { !$0.hasPrefix(".") }) else { return nil }
        return folder.appending(path: name)
    }

    /// Removes these assets' cached originals (not those kept offline).
    public func forget(assetIDs: some Sequence<String>) {
        for id in assetIDs { try? FileManager.default.removeItem(at: folder(for: id)) }
    }

    public func trim(toBytes maxBytes: Int) {
        trimmer.trim(toBytes: maxBytes)
    }

    public nonisolated func size() -> Int {
        trimmer.size()
    }

    private func finished(_ assetID: String, id: UUID) {
        if inFlight[assetID]?.id == id { inFlight[assetID] = nil }
    }

    private func waiterCancelled(_ assetID: String, id: UUID) {
        guard var entry = inFlight[assetID], entry.id == id else { return }
        entry.waiters -= 1
        inFlight[assetID] = entry
        if entry.waiters <= 0 { entry.task.cancel() }
    }

    private nonisolated func folder(for assetID: String) -> URL {
        directory.appending(path: assetID.replacingOccurrences(of: "/", with: "_"), directoryHint: .isDirectory)
    }

    static func safeFileName(_ name: String, fallback: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? fallback : cleaned
    }
}

/// Fans one download's progress out to every waiter.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (Double) -> Void] = []
    private var last: Double = 0

    func add(_ handler: @escaping @Sendable (Double) -> Void) {
        let current = lock.withLock {
            handlers.append(handler)
            return last
        }
        handler(current)
    }

    func send(_ value: Double) {
        let targets = lock.withLock {
            last = value
            return handlers
        }
        for handler in targets { handler(value) }
    }
}
