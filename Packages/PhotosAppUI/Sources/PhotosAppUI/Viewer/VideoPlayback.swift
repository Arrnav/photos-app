import AVFoundation
import Core
import Photos
import UIKit

/// Plays one viewer page's video. Its layer lives inside the page's zoom container, so
/// pinch-zoom works on video exactly as on photos and the two can't conflict. Created
/// when the page becomes a video page and torn down with it, so it can't get stuck.
@MainActor
final class VideoPlayback {
    let player = AVPlayer()
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue; onChange?() }
    }
    var loops = UserDefaults.standard.bool(forKey: PhotosSettings.loopVideos)
    /// Called on play/pause, progress and readiness changes (for the controls).
    var onChange: (() -> Void)?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    /// True while the video plays on an AirPlay device.
    private(set) var isExternal = false
    /// Called when AirPlay starts or stops for this player.
    var onExternalPlaybackChange: ((Bool) -> Void)?
    private var loadTask: Task<Void, Never>?
    private var phoneRequest: PHImageRequestID?
    private var wantsPlay = false

    init() {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.onChange?()
            }
        }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in
                guard let self, self.isExternal != active else { return }
                self.isExternal = active
                self.onExternalPlaybackChange?(active)
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.onChange?()
            }
        }
    }

    func tearDown() {
        loadTask?.cancel()
        if let phoneRequest { PHImageManager.default().cancelImageRequest(phoneRequest) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil
        rateObservation = nil
        externalObservation = nil
        onChange = nil
        onExternalPlaybackChange = nil
    }

    /// A video on the phone (PhotoKit handles slow-motion compositions and iCloud downloads).
    func loadPhoneVideo(localID: String) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        phoneRequest = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
            guard let item else { return }
            Task { @MainActor in self?.use(item) }
        }
    }

    /// A Cloud video, streamed with range requests (the original file; no transcoding).
    func loadStream(url: URL, headers: [String: String]) {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        use(AVPlayerItem(asset: asset))
    }

    /// A local file (e.g. a downloaded original or a Live Photo's motion part).
    func loadFile(_ url: URL) {
        use(AVPlayerItem(url: url))
    }

    private func use(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            let failed = item.status == .failed ? item.error?.localizedDescription : nil
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self else { return }
                if let failed { Log.media.error("Video failed: \(failed, privacy: .public)") }
                self.isReady = ready
                if ready { self.duration = seconds.isFinite ? seconds : 0 }
                if ready, self.wantsPlay { self.player.play() }
                self.onChange?()
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.seek(to: .zero)
                if self.loops { self.player.play() } else { self.wantsPlay = false }
            }
        }
    }

    /// Continues from the same moment with another source (e.g. a URL an AirPlay receiver can open).
    func switchSource(to url: URL) {
        let time = player.currentTime()
        let resume = wantsPlay || isPlaying
        use(AVPlayerItem(url: url))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if resume { play() }
    }

    func play() {
        wantsPlay = true
        // Plays through the silent switch.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if isReady { player.play() }
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func togglePlay() {
        isPlaying || wantsPlay ? pause() : play()
    }

    /// `fraction` 0…1. Precise seeks when the finger stops; quick ones while scrubbing.
    func seek(toFraction fraction: Double, precise: Bool) {
        guard duration > 0 else { return }
        let time = CMTime(seconds: duration * min(max(fraction, 0), 1), preferredTimescale: 600)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = time.seconds
        onChange?()
    }

    /// Evenly spaced frames for the scrubber, generated off the main thread.
    func thumbnails(count: Int, height: CGFloat) async -> [UIImage] {
        guard let asset = player.currentItem?.asset else { return [] }
        return await Self.frames(of: asset, count: count, maxSide: height * 3).map(UIImage.init(cgImage:))
    }

    @concurrent
    private static func frames(of asset: AVAsset, count: Int, maxSide: CGFloat) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }
        var images: [CGImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration.seconds * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) { images.append(image) }
        }
        return images
    }
}

/// A view backed by an `AVPlayerLayer`, sized like the photo it replaces.
final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
