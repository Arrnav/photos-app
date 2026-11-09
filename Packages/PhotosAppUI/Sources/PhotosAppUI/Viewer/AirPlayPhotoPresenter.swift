import AVFoundation
import Core
import UIKit

/// One-tap AirPlay for photos (experimental). Public APIs can't send a still
/// image over AirPlay, so while an AirPlay device is selected, each photo is rendered on
/// the phone into a short clip at TV resolution and played to the TV with AVPlayer's
/// external playback; swiping swaps the clip. Videos play to the TV from their own page.
@MainActor
final class AirPlayPhotoPresenter {
    private let player = AVPlayer()
    private let playerView: PlayerView
    private var routeObserver: NSObjectProtocol?
    private var renderTask: Task<Void, Never>?
    private var shownKey: String?
    private(set) var isRouteActive = false
    /// Called when an AirPlay device is selected or deselected.
    var onRouteChange: ((Bool) -> Void)?

    nonisolated private static let clipSize = CGSize(width: 1920, height: 1080)
    nonisolated private static let folder = FileManager.default.temporaryDirectory.appending(path: "airplay-clips", directoryHint: .isDirectory)

    init() {
        playerView = PlayerView(player: player)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.actionAtItemEnd = .pause
        player.isMuted = true
        isRouteActive = Self.airPlayRouteSelected()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        }
    }

    /// The (invisible) layer the clips play in; AirPlay needs it in the window.
    func attach(to view: UIView) {
        playerView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        playerView.alpha = 0.01
        view.insertSubview(playerView, at: 0)
        // A playback session (mixing with other audio) so the route picker can select AirPlay.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func stop() {
        renderTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerView.removeFromSuperview()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func airPlayRouteSelected() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    private func routeChanged() {
        let active = Self.airPlayRouteSelected()
        guard active != isRouteActive else { return }
        isRouteActive = active
        Log.media.info("AirPlay route \(active ? "selected" : "ended", privacy: .public)")
        if !active {
            player.pause()
            player.replaceCurrentItem(with: nil)
            shownKey = nil
        }
        onRouteChange?(active)
    }

    /// Shows a photo on the TV (no-op unless AirPlay is selected).
    func show(_ image: UIImage, key: String) {
        guard isRouteActive, key != shownKey, let cgImage = image.cgImage else { return }
        shownKey = key
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let start = ContinuousClock.now
            do {
                let url = try await Self.clip(for: cgImage, key: key)
                guard let self, !Task.isCancelled, self.shownKey == key else { return }
                self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                self.player.play()
                Log.media.info("AirPlay photo ready in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            } catch is CancellationError {
            } catch {
                Log.media.error("AirPlay photo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A video page is showing: it plays to the TV itself.
    func yieldToVideo() {
        renderTask?.cancel()
        shownKey = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Renders (or reuses) a 3-second H.264 clip of the photo, letterboxed on black.
    @concurrent
    private static func clip(for image: CGImage, key: String) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let url = folder.appending(path: "\(safe)-\(image.width)x\(image.height).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let temp = folder.appending(path: UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(clipSize.width),
            AVVideoHeightKey: Int(clipSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(clipSize.width),
            kCVPixelBufferHeightKey as String: Int(clipSize.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CancellationError() }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CancellationError() }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw CancellationError() }
        draw(image, into: buffer)
        // The same frame at the start and the end: the TV holds it.
        for seconds in [0.0, 3.0] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CancellationError() }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    nonisolated private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        let canvas = CGRect(origin: .zero, size: clipSize)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(canvas)
        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height))
    }
}
