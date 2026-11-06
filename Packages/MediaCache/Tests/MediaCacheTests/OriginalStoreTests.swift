import Foundation
import CloudCore
import Testing
@testable import MediaCache

/// Writes fixed bytes to a temp file, reporting progress; optionally waits to be released.
final class FakeFileDownloader: FileDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls: [URLRequest] = []

    init(bytes: Data, gated: Bool = false) {
        self.bytes = bytes
        self.gated = gated
    }

    var callCount: Int { lock.withLock { calls.count } }

    func download(_ request: URLRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { calls.append(request) }
        progress(0.5)
        if gated {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)")
        try bytes.write(to: url)
        progress(1)
        return url
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

private let mediaSource = MediaSource.test()

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "originals-\(UUID().uuidString)")
}

@Suite struct OriginalStoreTests {
    @Test func downloadsUnderTheOriginalNameAndReuses() async throws {
        let downloader = FakeFileDownloader(bytes: Data("heic".utf8))
        let store = OriginalStore(directory: folder(), downloader: downloader) { mediaSource }
        let url = try await store.file(assetID: "a1", fileName: "IMG_0001.HEIC")
        #expect(url.lastPathComponent == "IMG_0001.HEIC")
        #expect(try Data(contentsOf: url) == Data("heic".utf8))
        #expect(downloader.calls.first?.url?.absoluteString == "https://media.test/a1/original")
        #expect(downloader.calls.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        _ = try await store.file(assetID: "a1", fileName: "IMG_0001.HEIC")
        #expect(downloader.callCount == 1)
        #expect(store.cachedFile(assetID: "a1") == url)
    }

    @Test func concurrentRequestsShareOneDownloadAndProgress() async throws {
        let downloader = FakeFileDownloader(bytes: Data("x".utf8), gated: true)
        let store = OriginalStore(directory: folder(), downloader: downloader) { mediaSource }
        final class Seen: @unchecked Sendable {
            let lock = NSLock(); var values: [Double] = []
            func add(_ v: Double) { lock.withLock { values.append(v) } }
        }
        let seen = Seen()
        async let a = store.file(assetID: "a1", fileName: "a.mov") { seen.add($0) }
        async let b = store.file(assetID: "a1", fileName: "a.mov")
        try await Task.sleep(for: .milliseconds(50))
        downloader.release()
        let (first, second) = try await (a, b)
        #expect(first == second)
        #expect(downloader.callCount == 1)
        #expect(seen.lock.withLock { seen.values.contains(1) })
    }

    @Test func cancellingTheOnlyWaiterCancelsTheDownload() async throws {
        let downloader = FakeFileDownloader(bytes: Data("x".utf8), gated: true)
        let directory = folder()
        let store = OriginalStore(directory: directory, downloader: downloader) { mediaSource }
        let task = Task { try await store.file(assetID: "a1", fileName: "a.jpg") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try await Task.sleep(for: .milliseconds(30))
        downloader.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.cachedFile(assetID: "a1") == nil)
    }

    @Test func unsafeNamesAreCleaned() {
        #expect(OriginalStore.safeFileName("../evil/name.jpg", fallback: "id") == "id")
        #expect(OriginalStore.safeFileName("a/b:c.jpg", fallback: "id") == "a_b_c.jpg")
        #expect(OriginalStore.safeFileName("  ", fallback: "id") == "id")
        #expect(OriginalStore.safeFileName(".hidden", fallback: "id") == "id")
    }

    @Test func offlineFailsReadably() async {
        let store = OriginalStore(directory: folder(), downloader: FakeFileDownloader(bytes: Data())) { nil }
        await #expect(throws: MediaError.offline) {
            _ = try await store.file(assetID: "a1", fileName: "a.jpg")
        }
    }
}
