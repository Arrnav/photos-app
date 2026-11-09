import CoreGraphics
import Foundation
import ImageIO
import CloudCore
import Testing
import UniformTypeIdentifiers
@testable import MediaCache

/// A PNG of the given size, for decode tests.
func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Records downloads; optionally waits for `release()` before answering.
final class FakeDownloader: MediaDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var pendingRelease = false
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled = 0

    init(payload: Data, gated: Bool = false) {
        self.payload = payload
        self.gated = gated
    }

    var count: Int { lock.withLock { requests.count } }
    var cancelledCount: Int { lock.withLock { cancelled } }

    func download(_ request: URLRequest) async throws -> Data {
        lock.withLock { requests.append(request) }
        if gated {
            await withCheckedContinuation { continuation in
                let releaseNow = lock.withLock {
                    if pendingRelease { return true }
                    gate = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
        }
        if Task.isCancelled {
            lock.withLock { cancelled += 1 }
            throw CancellationError()
        }
        return payload
    }

    func release() {
        let continuation = lock.withLock {
            pendingRelease = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "mediacache-tests-\(UUID().uuidString)")
}

private let source = MediaSource.test()

@Suite struct RemoteImagePipelineTests {
    @Test func downloadsDecodesAndCaches() async throws {
        let downloader = FakeDownloader(payload: makePNG(width: 400, height: 300))
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader) { source }

        let image = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 200)
        #expect(max(image.width, image.height) == 200)
        #expect(downloader.requests.first?.url?.absoluteString == "https://media.test/a1/thumbnail")
        #expect(downloader.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 200)
        #expect(downloader.count == 1)
        #expect(pipeline.cachedImage(assetID: "a1", size: .thumbnail, maxPixelSize: 200) != nil)
    }

    @Test func diskCacheSurvivesNewPipeline() async throws {
        let directory = tempDirectory()
        let downloader = FakeDownloader(payload: makePNG(width: 64, height: 64))
        _ = try await RemoteImagePipeline(cacheDirectory: directory, downloader: downloader) { source }
            .image(assetID: "a1", size: .thumbnail, maxPixelSize: 64)
        _ = try await RemoteImagePipeline(cacheDirectory: directory, downloader: downloader) { source }
            .image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        #expect(downloader.count == 1)
    }

    @Test func concurrentRequestsShareOneDownload() async throws {
        let downloader = FakeDownloader(payload: makePNG(width: 64, height: 64), gated: true)
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader) { source }
        async let first = pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 64)
        async let second = pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        try await Task.sleep(for: .milliseconds(50))
        downloader.release()
        _ = try await (first, second)
        #expect(downloader.count == 1)
    }

    @Test func cancellingTheOnlyWaiterCancelsTheDownload() async throws {
        let downloader = FakeDownloader(payload: makePNG(width: 64, height: 64), gated: true)
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader) { source }
        let task = Task { try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 64) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        downloader.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(downloader.cancelledCount == 1)
    }

    @Test func downloadContinuesWhileAnotherWaiterRemains() async throws {
        let downloader = FakeDownloader(payload: makePNG(width: 64, height: 64), gated: true)
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader) { source }
        let cancelled = Task { try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 64) }
        let kept = Task { try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 64) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(50))
        downloader.release()
        _ = try await kept.value
        #expect(downloader.cancelledCount == 0)
    }

    @Test func diskOnlyLookupNeverDownloads() async throws {
        let directory = tempDirectory()
        let downloader = FakeDownloader(payload: makePNG(width: 64, height: 64))
        let pipeline = RemoteImagePipeline(cacheDirectory: directory, downloader: downloader) { source }
        #expect(await pipeline.diskCachedImage(assetID: "a1", size: .thumbnail, maxPixelSize: 64) == nil)
        #expect(downloader.count == 0)
        await pipeline.prefetch(assetID: "a1", size: .thumbnail)
        let fresh = RemoteImagePipeline(cacheDirectory: directory, downloader: downloader) { source }
        #expect(await fresh.diskCachedImage(assetID: "a1", size: .thumbnail, maxPixelSize: 32) != nil)
        #expect(downloader.count == 1)
    }

    @Test func noSourceMeansOfflineError() async {
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: FakeDownloader(payload: Data())) { nil }
        await #expect(throws: MediaError.offline) {
            _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 64)
        }
    }

    @Test func undecodableDataIsNotKeptOnDisk() async throws {
        let directory = tempDirectory()
        let downloader = FakeDownloader(payload: Data("not an image".utf8))
        let pipeline = RemoteImagePipeline(cacheDirectory: directory, downloader: downloader) { source }
        await #expect(throws: MediaError.self) {
            _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 64)
        }
        #expect(DiskCache(directory: directory).data(for: "a1.thumbnail") == nil)
    }
}

/// Fails with 404 a given number of times, then succeeds.
final class FlakyDownloader: MediaDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private let payload: Data
    private(set) var calls = 0

    init(failures: Int, payload: Data) {
        failuresLeft = failures
        self.payload = payload
    }

    var callCount: Int { lock.withLock { calls } }

    func download(_ request: URLRequest) async throws -> Data {
        let fail = lock.withLock {
            calls += 1
            if failuresLeft > 0 { failuresLeft -= 1; return true }
            return false
        }
        if fail { throw MediaError(kind: .notFound, message: "not generated yet") }
        return payload
    }
}

@Suite struct FailureBackoffTests {
    private let slowBackoff = BackoffPolicy(notFound: [.seconds(600)], other: [.seconds(600)])

    @Test func missingThumbnailIsNotRequestedAgainDuringBackoff() async throws {
        let downloader = FlakyDownloader(failures: 1, payload: makePNG(width: 32, height: 32))
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader, backoff: slowBackoff) { source }
        await #expect(throws: MediaError(kind: .notFound, message: "not generated yet")) {
            _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        }
        for _ in 0..<5 {
            await #expect(throws: MediaError.self) {
                _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
            }
        }
        #expect(downloader.callCount == 1)
        #expect(await pipeline.failureCounts()[.notFound] == 1)
    }

    @Test func newRevisionRetriesImmediately() async throws {
        let downloader = FlakyDownloader(failures: 1, payload: makePNG(width: 32, height: 32))
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader, backoff: slowBackoff) { source }
        _ = try? await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32, revision: nil)
        // The server generated the thumbnail; sync brought a thumbhash.
        _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32, revision: "newhash")
        #expect(downloader.callCount == 2)
    }

    @Test func retriesAfterBackoffExpires() async throws {
        let downloader = FlakyDownloader(failures: 1, payload: makePNG(width: 32, height: 32))
        let quick = BackoffPolicy(notFound: [.milliseconds(50)], other: [.milliseconds(50)])
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader, backoff: quick) { source }
        _ = try? await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        try await Task.sleep(for: .milliseconds(80))
        _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        #expect(downloader.callCount == 2)
    }

    @Test func resetFailuresAllowsImmediateRetry() async throws {
        let downloader = FlakyDownloader(failures: 1, payload: makePNG(width: 32, height: 32))
        let pipeline = RemoteImagePipeline(cacheDirectory: tempDirectory(), downloader: downloader, backoff: slowBackoff) { source }
        _ = try? await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        await pipeline.resetFailures()
        _ = try await pipeline.image(assetID: "a1", size: .thumbnail, maxPixelSize: 32)
        #expect(downloader.callCount == 2)
    }
}

@Suite struct RequestLimiterTests {
    @Test func neverExceedsTheLimit() async throws {
        let limiter = RequestLimiter(limit: 4)
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var current = 0
            var peak = 0
            func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
            func leave() { lock.withLock { current -= 1 } }
        }
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await limiter.run(priority: .prefetch) {
                        counter.enter()
                        try await Task.sleep(for: .milliseconds(10))
                        counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counter.peak == 4)
        #expect(await limiter.activeCount == 0)
    }

    @Test func visibleRequestsJumpTheQueue() async throws {
        let limiter = RequestLimiter(limit: 1)
        final class Order: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
        }
        let order = Order()
        let blocker = Task { try await limiter.run(priority: .visible) { try await Task.sleep(for: .milliseconds(100)) } }
        try await Task.sleep(for: .milliseconds(20))
        let prefetch = Task { try await limiter.run(priority: .prefetch) { order.append("prefetch") } }
        try await Task.sleep(for: .milliseconds(20))
        let visible = Task { try await limiter.run(priority: .visible) { order.append("visible") } }
        _ = try await (blocker.value, prefetch.value, visible.value)
        #expect(order.values == ["visible", "prefetch"])
    }

    @Test func cancelledWaiterDoesNotRun() async throws {
        let limiter = RequestLimiter(limit: 1)
        let blocker = Task { try await limiter.run(priority: .visible) { try await Task.sleep(for: .milliseconds(80)) } }
        try await Task.sleep(for: .milliseconds(20))
        let waiter = Task { try await limiter.run(priority: .visible) { "ran" } }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        try await blocker.value
        #expect(await limiter.activeCount == 0)
    }
}

@Suite struct DiskCacheTests {
    @Test func trimRemovesOldestFirst() throws {
        let cache = DiskCache(directory: tempDirectory())
        let blob = Data(repeating: 1, count: 1000)
        for name in ["old", "middle", "new"] { cache.store(blob, for: name) }
        let old = Date.now.addingTimeInterval(-3000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.url(for: "old").path)
        try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(1000)], ofItemAtPath: cache.url(for: "middle").path)

        #expect(cache.trim(toBytes: 2000) == 1)
        #expect(cache.data(for: "old") == nil)
        #expect(cache.data(for: "middle") != nil)
        #expect(cache.data(for: "new") != nil)
    }
}

@Suite struct ThumbHashTests {
    // Thumbhashes in the format Immich sends (base64).
    static let samples = ["1QcSHQRnh493V4dIh4eXh1h4kJUI", "3OcRJYB4d3h/iIeHeEh3eIhw+j3A", "VvYRNQRod3x3B4iHeHhYiHeAiQUo"]

    @Test(arguments: samples)
    func decodesToSmallImageMatchingAspectRatio(hash: String) throws {
        let bytes = Array(try #require(Data(base64Encoded: hash)))
        let rgba = try #require(ThumbHash.decode(bytes))
        #expect(max(rgba.width, rgba.height) == 32)
        #expect(rgba.pixels.count == rgba.width * rgba.height * 4)
        let ratio = try #require(ThumbHash.approximateAspectRatio(bytes))
        #expect(abs(Double(rgba.width) / Double(rgba.height) - ratio) < 0.2)
        #expect(ThumbHash.image(base64: hash) != nil)
    }

    @Test func rejectsInvalidInput() {
        #expect(ThumbHash.image(base64: "") == nil)
        #expect(ThumbHash.image(base64: "not base64!") == nil)
        #expect(ThumbHash.decode([1, 2, 3]) == nil)
    }

    @Test func neverCrashesOnRandomBytes() {
        var generator = SystemRandomNumberGenerator()
        for length in 0..<40 {
            for _ in 0..<50 {
                let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
                _ = ThumbHash.decode(bytes)
            }
        }
    }
}
