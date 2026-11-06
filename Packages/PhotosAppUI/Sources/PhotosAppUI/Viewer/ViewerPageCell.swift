import Core
import MediaCache
import Persistence
import Photos
import UIKit

/// What a page needs to load its images.
struct ViewerMedia {
    let pipeline: RemoteImagePipeline
    let originals: OriginalStore
    /// True on the home network: the original (sharper, HDR) is fetched once a
    /// page has settled. Otherwise only when zooming in.
    let loadsOriginalWhenSettled: () -> Bool
    /// Photos on the phone load from PhotoKit instead.
    let phone: PhoneImages?
    /// Where a Cloud video streams from (nil while offline).
    let videoStream: (String) -> (url: URL, headers: [String: String])?
    /// A Cloud Live Photo's motion part (its asset id and file name).
    let motionPart: (String) -> (id: String, fileName: String)?
    /// A URL an AirPlay receiver can open for a Cloud video (it can't send the app's sign-in).
    let airPlayURL: (String) async throws -> URL
    /// Called when a video page goes away (temporary AirPlay links are deleted).
    let releaseAirPlay: () -> Void
}

/// Live Photos the user switched to Off (viewed as stills), kept on this phone.
enum LivePhotoSettings {
    private static let key = "viewer.liveOff"

    static func isOff(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }

    static func setOff(_ off: Bool, id: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if off { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

/// One full-screen page: a zoomable photo that loads in stages — the grid's tile
/// image at once, then the server preview, then the original (sharp and HDR).
final class ViewerPageCell: UICollectionViewCell {
    static let reuseIdentifier = "ViewerPageCell"

    let zoomView = ZoomingImageView()
    private let playGlyph = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let originalSpinner = UIActivityIndicatorView(style: .medium)

    private(set) var item: TimelineItem?
    private var fileName = ""
    private var media: ViewerMedia?
    private var previewTask: Task<Void, Never>?
    private var originalTask: Task<Void, Never>?
    private var settleWork: DispatchWorkItem?
    private var quality = Quality.none
    /// Kept so a page that scrolls away can drop its (large) original and fall back to this.
    private var previewImage: UIImage?
    private var phoneRequest: PHImageRequestID?

    private enum Quality: Int, Comparable {
        case none, placeholder, preview, original
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    var onPlayTapped: (() -> Void)?
    /// The page's video player, while it's the current page of a video.
    private(set) var video: VideoPlayback?
    private var live: LivePhotoPlayback?
    /// Long-press subject lift, Live Text and Look Up (VisionKit).
    private let subjectLift = SubjectLift()
    /// Press and hold plays a Live Photo (only enabled on Live Photos, so stills get subject lift).
    private let livePress = UILongPressGestureRecognizer()
    private var playerView: PlayerView?
    /// Called when the video starts, stops or advances (the viewer updates its controls).
    var onVideoChange: (() -> Void)?
    /// Single tap (after double-tap has had its chance): the viewer toggles its bars.
    var onSingleTap: (() -> Void)?
    /// Half the gap between pages; the photo is inset so neighbouring pages don't touch.
    var horizontalInset: CGFloat = 0 {
        didSet { if horizontalInset != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(zoomView)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: zoomView.doubleTapRecognizer)
        zoomView.addGestureRecognizer(singleTap)
        // Press and hold plays a Live Photo.
        livePress.addTarget(self, action: #selector(pressed(_:)))
        livePress.minimumPressDuration = 0.25
        zoomView.addGestureRecognizer(livePress)

        playGlyph.tintColor = .white
        playGlyph.preferredSymbolConfiguration = .init(pointSize: 64, weight: .regular)
        playGlyph.layer.shadowOpacity = 0.3
        playGlyph.layer.shadowRadius = 6
        playGlyph.isUserInteractionEnabled = true
        playGlyph.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(playTapped)))
        playGlyph.isAccessibilityElement = true
        playGlyph.accessibilityLabel = String(localized: "Play video")
        playGlyph.accessibilityTraits = .button
        contentView.addSubview(playGlyph)

        originalSpinner.color = .white
        originalSpinner.hidesWhenStopped = true
        contentView.addSubview(originalSpinner)

        zoomView.onNeedsSharperImage = { [weak self] in self?.loadOriginal() }
        subjectLift.attach(to: zoomView.imageView)
        zoomView.imageView.isAccessibilityElement = true
        zoomView.imageView.accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = contentView.bounds.insetBy(dx: horizontalInset, dy: 0)
        if zoomView.frame != frame { zoomView.frame = frame }
        playGlyph.sizeToFit()
        playGlyph.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let insets = contentView.safeAreaInsets
        originalSpinner.center = CGPoint(x: contentView.bounds.maxX - 28, y: insets.top + 64)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        subjectLift.reset()
        stopVideo()
        stopLive()
        cancelLoads()
        item = nil
        quality = .none
        previewImage = nil
        originalSpinner.stopAnimating()
    }

    private func cancelLoads() {
        media?.phone?.cancel(phoneRequest)
        phoneRequest = nil
        previewTask?.cancel()
        previewTask = nil
        originalTask?.cancel()
        originalTask = nil
        settleWork?.cancel()
        settleWork = nil
    }

    func configure(item: TimelineItem, details: AssetDetails?, placeholder: UIImage?, media: ViewerMedia) {
        self.item = item
        self.media = media
        fileName = details?.asset.originalFileName ?? "\(item.id).jpg"
        let pixelWidth = CGFloat(details?.exif?.exifImageWidth ?? details?.asset.width ?? 0)
        zoomView.prepare(aspectRatio: item.aspectRatio, fullPixelWidth: pixelWidth)
        zoomView.imageView.preferredImageDynamicRange = .standard
        zoomView.imageView.accessibilityLabel = Formatting.accessibilityLabel(for: item)
        // No play button over a video; play/pause is in the controls capsule.
        playGlyph.isHidden = true
        livePress.isEnabled = item.isLivePhoto && !LivePhotoSettings.isOff(item.id)
        quality = .none

        if let placeholder {
            zoomView.setImage(placeholder)
            quality = .placeholder
        }
        loadPreview()
    }

    private var screenPixels: Int {
        // Before the cell is in a window, assume a large phone (the preview is ~1440 px anyway).
        guard let screen = window?.windowScene?.screen else { return 2800 }
        return Int(max(screen.bounds.width, screen.bounds.height) * screen.scale)
    }

    private func loadPreview() {
        guard let item, let media else { return }
        if let localID = item.localID, let phone = media.phone {
            let id = item.id
            let side = CGFloat(screenPixels)
            phoneRequest = phone.requestImage(localID: localID, pixelSize: CGSize(width: side, height: side), fill: false, quality: .high) { [weak self] image, degraded in
                guard let self, self.item?.id == id else { return }
                if degraded {
                    if self.quality < .placeholder { self.zoomView.setImage(image); self.quality = .placeholder }
                } else {
                    self.phoneRequest = nil
                    self.show(image, quality: .preview)
                }
            }
            return
        }
        let id = item.id
        let revision = item.thumbhash
        let size = screenPixels
        if let cached = media.pipeline.cachedImage(assetID: id, size: .preview, maxPixelSize: size) {
            show(UIImage(cgImage: cached), quality: .preview)
            return
        }
        previewTask = Task { [weak self] in
            do {
                let image = try await media.pipeline.image(assetID: id, size: .preview, maxPixelSize: size, revision: revision)
                guard let self, self.item?.id == id else { return }
                self.show(UIImage(cgImage: image), quality: .preview)
            } catch is CancellationError {
            } catch {
                Log.media.info("Viewer preview \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The viewer calls this when the page has stopped on screen.
    func didBecomeCurrent() {
        settleWork?.cancel()
        if item?.isVideo == true {
            startVideo(autoPlay: UserDefaults.standard.bool(forKey: PhotosSettings.autoPlayMotion))
            return
        }
        // Subject lift etc. on stills (a Live Photo's long press plays it, unless it's set to Off).
        let liveOn = item?.isLivePhoto == true && !LivePhotoSettings.isOff(item?.id ?? "")
        subjectLift.setEnabled(!liveOn)
        if !liveOn { subjectLift.analyse(zoomView.imageView.image) }
        // Prepare the Live Photo; with Auto-Play Motion, give the short preview Photos shows.
        prepareLive(preload: true, hint: UserDefaults.standard.bool(forKey: PhotosSettings.autoPlayMotion))
        // The phone's own full-resolution photo (with HDR) costs nothing from the server.
        let isPhonePhoto = item?.localID != nil && media?.phone != nil
        guard let media, isPhonePhoto || media.loadsOriginalWhenSettled() else { return }
        let work = DispatchWorkItem { [weak self] in self?.loadOriginal() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// The viewer calls this when the page scrolls away. A decoded original is ~48 MB
    /// for 12 MP, so the page falls back to the preview until it's zoomed again.
    func didResignCurrent() {
        stopVideo()
        stopLive()
        settleWork?.cancel()
        originalTask?.cancel()
        originalTask = nil
        originalSpinner.stopAnimating()
        zoomView.resetZoom(animated: false)
        if quality == .original, let previewImage {
            zoomView.imageView.preferredImageDynamicRange = .standard
            zoomView.setImage(previewImage)
            quality = .preview
            zoomView.allowSharperImageRequest()
        }
    }

    private func loadOriginal() {
        guard let item, let media, !item.isVideo, quality < .original, originalTask == nil else { return }
        let id = item.id
        if let localID = item.localID, let phone = media.phone {
            originalTask = Task { [weak self] in
                defer { if self?.item?.id == id { self?.originalTask = nil } }
                do {
                    let image = try await phone.fullImage(localID: localID)
                    guard let self, self.item?.id == id else { return }
                    self.zoomView.imageView.preferredImageDynamicRange = UserDefaults.standard.bool(forKey: PhotosSettings.fullHDR) ? .high : .standard
                    self.show(image, quality: .original)
                } catch {
                    Log.media.info("Viewer phone original \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        let name = fileName
        let alreadyOnDisk = media.originals.cachedFile(assetID: id) != nil
        if !alreadyOnDisk { originalSpinner.startAnimating() }
        originalTask = Task { [weak self] in
            defer {
                if self?.item?.id == id {
                    self?.originalTask = nil
                    self?.originalSpinner.stopAnimating()
                }
            }
            do {
                let url = try await media.originals.file(assetID: id, fileName: name)
                let image = try await Self.decodeOriginal(at: url)
                guard let self, self.item?.id == id else { return }
                self.zoomView.imageView.preferredImageDynamicRange = UserDefaults.standard.bool(forKey: PhotosSettings.fullHDR) ? .high : .standard
                self.show(image, quality: .original)
            } catch is CancellationError {
            } catch {
                Log.media.info("Viewer original \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads the original with HDR (gain maps) when the file has it, prepared for
    /// display off the main thread. Very large photos are capped at 6048 px.
    @concurrent
    private static func decodeOriginal(at url: URL) async throws -> UIImage {
        var configuration = UIImageReader.Configuration()
        configuration.prefersHighDynamicRange = true
        configuration.preparesImagesForDisplay = true
        configuration.preferredThumbnailSize = CGSize(width: 6048, height: 6048)
        let reader = UIImageReader(configuration: configuration)
        guard let image = await reader.image(contentsOf: url) else {
            throw MediaError(kind: .undecodable, message: "The original couldn't be decoded.")
        }
        return image
    }

    private func show(_ image: UIImage, quality newQuality: Quality) {
        guard newQuality > quality else { return }
        quality = newQuality
        if newQuality == .preview { previewImage = image }
        UIView.transition(with: zoomView.imageView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.zoomView.setImage(image)
        }
    }

    @objc private func singleTapped() {
        onSingleTap?()
    }

    @objc private func playTapped() {
        if let video {
            video.togglePlay()
        } else {
            startVideo(autoPlay: true)
        }
        onPlayTapped?()
    }

    // MARK: Live Photos

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard let item, item.isLivePhoto else { return }
        switch gesture.state {
        case .began:
            prepareLive(preload: true, hint: false)
            live?.play(.full)
        case .ended, .cancelled, .failed:
            live?.stop()
        default:
            break
        }
    }

    /// Attaches the live view and loads the motion (phone: always; Cloud: on the home network or when pressed).
    private func prepareLive(preload: Bool, hint: Bool) {
        guard let item, item.isLivePhoto, !LivePhotoSettings.isOff(item.id), let media else { return }
        if live == nil {
            let playback = LivePhotoPlayback()
            playback.attach(to: zoomView.imageView)
            live = playback
        }
        guard let live, !live.isLoaded else {
            if hint { live?.play(.hint) }
            return
        }
        if let localID = item.localID, media.phone != nil {
            let side = CGFloat(screenPixels)
            live.loadPhone(localID: localID, targetSize: CGSize(width: side, height: side))
        } else if preload, let motion = media.motionPart(item.id) {
            guard media.loadsOriginalWhenSettled() || !hint else { return }
            live.loadCloud(stillID: item.id, stillName: fileName, motionID: motion.id, motionName: motion.fileName, originals: media.originals)
        }
        if hint { live.play(.hint) }
    }

    private func stopLive() {
        live?.tearDown()
        live = nil
    }

    /// The LIVE badge's Off option: back to a still.
    func setLiveOff(_ off: Bool) {
        guard let item else { return }
        LivePhotoSettings.setOff(off, id: item.id)
        livePress.isEnabled = item.isLivePhoto && !off
        subjectLift.setEnabled(off)
        if off { subjectLift.analyse(zoomView.imageView.image) }
        if off { stopLive() } else { prepareLive(preload: true, hint: true) }
    }

    // MARK: Video

    /// Creates the player inside the zoom container (so it zooms like a photo) and loads
    /// the phone's copy, or streams the Cloud original.
    func startVideo(autoPlay: Bool) {
        guard let item, item.isVideo, let media else { return }
        if video == nil {
            let playback = VideoPlayback()
            let view = PlayerView(player: playback.player)
            view.frame = zoomView.imageView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            zoomView.imageView.addSubview(view)
            playerView = view
            video = playback
            playback.onChange = { [weak self] in self?.videoChanged() }
            if let localID = item.localID, media.phone != nil {
                playback.loadPhoneVideo(localID: localID)
            } else if let stream = media.videoStream(item.id) {
                playback.loadStream(url: stream.url, headers: stream.headers)
                // On AirPlay the TV fetches the video itself, without the app's sign-in.
                let id = item.id
                playback.onExternalPlaybackChange = { [weak playback] active in
                    guard active, let playback else { return }
                    Task { @MainActor in
                        do {
                            let url = try await media.airPlayURL(id)
                            playback.switchSource(to: url)
                            Log.media.info("AirPlay: switched \(id, privacy: .public) to a URL the receiver can open")
                        } catch {
                            Log.media.error("AirPlay source failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
        if autoPlay { video?.play() }
        videoChanged()
    }

    func stopVideo() {
        if video?.isExternal == true { media?.releaseAirPlay() }
        video?.tearDown()
        video = nil
        playerView?.removeFromSuperview()
        playerView = nil
        playGlyph.alpha = 1
        onVideoChange?()
    }

    private func videoChanged() {
        let playing = video?.isPlaying ?? false
        // The play button only shows while stopped (hidden during playback).
        if playGlyph.alpha != (playing ? 0 : 1) {
            UIView.animate(withDuration: 0.2) { self.playGlyph.alpha = playing ? 0 : 1 }
        }
        onVideoChange?()
    }
}
