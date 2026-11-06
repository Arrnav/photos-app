import Core
import CoreGraphics
import Foundation
import CloudCore

public struct MediaError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 404: the server has no file for this size yet (still processing) or the asset is gone.
        case notFound
        case unauthorized
        case server
        case network
        case offline
        case undecodable
        /// A recent attempt failed; waiting before asking the server again.
        case backingOff
    }

    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    static let offline = MediaError(kind: .offline, message: "Not connected to the server.")
}

/// Downloads bytes for a URL request. Replaced in tests.
public protocol MediaDownloader: Sendable {
    func download(_ request: URLRequest) async throws -> Data
}

public struct URLSessionDownloader: MediaDownloader {
    let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil // MediaCache owns caching
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    public func download(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MediaError(kind: .server, message: "Unexpected response loading an image.")
            }
            switch http.statusCode {
            case 200:
                return data
            case 401:
                throw MediaError(kind: .unauthorized, message: "The server rejected the sign-in while loading an image (401).")
            case 404:
                throw MediaError(kind: .notFound, message: "The server has no preview for this item yet (404). It may still be processing.")
            default:
                throw MediaError(kind: .server, message: "The server returned \(http.statusCode) while loading an image.")
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MediaError(kind: .network, message: "Loading an image failed: \(NetworkErrorDescription.describe(error))")
        }
    }
}

/// Loads server thumbnails and previews: memory cache → disk cache → network.
///
/// - Disk reads and decoding run concurrently off the actor; the actor only
///   coordinates downloads.
/// - Concurrent requests for the same image share one download, network use is
///   capped by a `RequestLimiter`, and a download is cancelled once nobody waits for it.
/// - Failures are remembered with backoff so missing thumbnails (e.g. still being
///   generated on the server) are not re-requested on every scroll. Passing a
///   different `revision` (the asset's thumbhash) clears the memory: a new
///   thumbhash means the server has produced new thumbnails.
public actor RemoteImagePipeline {
    public typealias SourceProvider = @Sendable () async -> MediaSource?

    private nonisolated let disk: DiskCache
    private nonisolated let memory: DecodedImageCache
    private let limiter: RequestLimiter
    private let downloader: any MediaDownloader
    private let source: SourceProvider
    private let backoff: BackoffPolicy

    private struct InFlight {
        let id: UUID
        let task: Task<Data, any Error>
        /// Waiters that have not been cancelled. The download is cancelled when this reaches 0.
        var activeWaiters: Int
    }
    private var inFlight: [String: InFlight] = [:]

    private struct Failure {
        let error: MediaError
        let attempts: Int
        let retryAt: ContinuousClock.Instant
        let revision: String?
    }
    private var failures: [String: Failure] = [:]

    public init(
        cacheDirectory: URL,
        downloader: any MediaDownloader,
        maxConcurrentDownloads: Int = 4,
        memoryLimitBytes: Int = 150 * 1024 * 1024,
        backoff: BackoffPolicy = .default,
        source: @escaping SourceProvider
    ) {
        disk = DiskCache(directory: cacheDirectory)
        memory = DecodedImageCache(costLimit: memoryLimitBytes)
        limiter = RequestLimiter(limit: maxConcurrentDownloads)
        self.downloader = downloader
        self.source = source
        self.backoff = backoff
    }

    /// A decoded image already in memory, for synchronous use while configuring a cell.
    public nonisolated func cachedImage(assetID: String, size: CloudImageSize, maxPixelSize: Int) -> CGImage? {
        memory.image(for: Self.memoryKey(assetID, size, maxPixelSize))
    }

    @concurrent
    public nonisolated func image(
        assetID: String,
        size: CloudImageSize,
        maxPixelSize: Int,
        revision: String? = nil,
        priority: RequestPriority = .visible
    ) async throws -> CGImage {
        let memoryKey = Self.memoryKey(assetID, size, maxPixelSize)
        if let cached = memory.image(for: memoryKey) { return cached }

        let diskKey = Self.diskKey(assetID, size)
        let data: Data
        if let stored = disk.data(for: diskKey) {
            data = stored
        } else {
            data = try await download(assetID: assetID, size: size, revision: revision, priority: priority)
        }
        try Task.checkCancellation()
        guard let image = ImageDecoder.decode(data, maxPixelSize: maxPixelSize) else {
            disk.remove(diskKey)
            throw MediaError(kind: .undecodable, message: "An image from the server could not be decoded.")
        }
        memory.insert(image, for: memoryKey)
        return image
    }

    /// The image from the memory or disk cache only; never touches the network
    /// (dense grid levels, where thousands of tiles are on screen).
    @concurrent
    public nonisolated func diskCachedImage(assetID: String, size: CloudImageSize, maxPixelSize: Int) async -> CGImage? {
        let memoryKey = Self.memoryKey(assetID, size, maxPixelSize)
        if let cached = memory.image(for: memoryKey) { return cached }
        guard let data = disk.data(for: Self.diskKey(assetID, size)),
              let image = ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
        else { return nil }
        memory.insert(image, for: memoryKey)
        return image
    }

    /// Warms the disk cache without decoding (used for prefetching).
    @concurrent
    public nonisolated func prefetch(assetID: String, size: CloudImageSize, revision: String? = nil) async {
        guard disk.data(for: Self.diskKey(assetID, size)) == nil else { return }
        _ = try? await download(assetID: assetID, size: size, revision: revision, priority: .prefetch)
    }

    public func trimDiskCache(toBytes maxBytes: Int) {
        disk.trim(toBytes: maxBytes)
    }

    public nonisolated func diskCacheSize() -> Int {
        disk.size()
    }

    public func clearMemory() {
        memory.removeAll()
        failures.removeAll()
    }

    /// Forgets all failures, e.g. after reconnecting to the server.
    public func resetFailures() {
        failures.removeAll()
    }

    /// Number of items currently waiting out a failure, by kind (for diagnostics).
    public func failureCounts() -> [MediaError.Kind: Int] {
        failures.values.reduce(into: [:]) { $0[$1.error.kind, default: 0] += 1 }
    }

    private func download(
        assetID: String,
        size: CloudImageSize,
        revision: String?,
        priority: RequestPriority
    ) async throws -> Data {
        let key = Self.diskKey(assetID, size)
        if let data = disk.data(for: key) { return data }

        if let failure = failures[key] {
            if failure.revision == revision, ContinuousClock.now < failure.retryAt {
                throw MediaError(kind: .backingOff, message: failure.error.message)
            }
        }

        let entry: InFlight
        if var existing = inFlight[key], existing.activeWaiters > 0 {
            existing.activeWaiters += 1
            inFlight[key] = existing
            entry = existing
        } else {
            let task = Task { [limiter, downloader, source, disk] in
                try await limiter.run(priority: priority) {
                    guard let current = await source() else { throw MediaError.offline }
                    let data = try await downloader.download(current.imageRequest(assetID: assetID, size: size))
                    disk.store(data, for: key)
                    return data
                }
            }
            entry = InFlight(id: UUID(), task: task, activeWaiters: 1)
            inFlight[key] = entry
        }

        do {
            let data = try await withTaskCancellationHandler {
                defer { finished(key, id: entry.id) }
                return try await entry.task.value
            } onCancel: {
                Task { await self.waiterCancelled(key, id: entry.id) }
            }
            failures[key] = nil
            return data
        } catch let error as MediaError {
            recordFailure(error, key: key, revision: revision)
            throw error
        }
    }

    private func recordFailure(_ error: MediaError, key: String, revision: String?) {
        // Being offline or signed out is handled elsewhere and shouldn't stick to each image.
        guard error.kind != .offline, error.kind != .backingOff else { return }
        let previous = failures[key]
        let attempts = (previous?.revision == revision ? previous?.attempts ?? 0 : 0) + 1
        let delay = backoff.delay(for: error.kind, attempt: attempts)
        failures[key] = Failure(error: error, attempts: attempts, retryAt: .now + delay, revision: revision)
    }

    /// The shared task has completed (or was cancelled), so later requests use the disk cache or start afresh.
    private func finished(_ key: String, id: UUID) {
        if inFlight[key]?.id == id { inFlight[key] = nil }
    }

    private func waiterCancelled(_ key: String, id: UUID) {
        guard var entry = inFlight[key], entry.id == id else { return }
        entry.activeWaiters -= 1
        inFlight[key] = entry
        if entry.activeWaiters <= 0 { entry.task.cancel() }
    }

    static func diskKey(_ assetID: String, _ size: CloudImageSize) -> String {
        "\(assetID).\(size.rawValue)"
    }

    static func memoryKey(_ assetID: String, _ size: CloudImageSize, _ maxPixelSize: Int) -> String {
        "\(assetID).\(size.rawValue).\(maxPixelSize)"
    }
}

/// How long to wait before asking the server again for an image that failed.
public struct BackoffPolicy: Sendable {
    /// Delays for successive attempts; the last one repeats.
    public var notFound: [Duration]
    public var other: [Duration]

    public init(notFound: [Duration], other: [Duration]) {
        self.notFound = notFound
        self.other = other
    }

    /// Missing thumbnails usually mean the server is still generating them, so they
    /// back off for longer; network and server errors retry sooner.
    public static let `default` = BackoffPolicy(
        notFound: [.seconds(60), .seconds(120), .seconds(300), .seconds(600)],
        other: [.seconds(10), .seconds(30), .seconds(60)]
    )

    func delay(for kind: MediaError.Kind, attempt: Int) -> Duration {
        let steps = kind == .notFound ? notFound : other
        guard let last = steps.last else { return .zero }
        return attempt - 1 < steps.count ? steps[max(0, attempt - 1)] : last
    }
}

/// NSCache of decoded images, costed by bitmap bytes. Thread-safe.
final class DecodedImageCache: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    init(costLimit: Int) {
        cache.totalCostLimit = costLimit
    }

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, for key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
