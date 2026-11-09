import Core
import MediaCache
import Photos
import PhotosUI
import UIKit

/// Plays a Live Photo's motion over a viewer page (press and hold).
/// Phone Live Photos come from PhotoKit; Cloud ones are rebuilt from the two original
/// files (the still and its motion video), which carry the pairing metadata.
@MainActor
final class LivePhotoPlayback: NSObject, PHLivePhotoViewDelegate {
    private let view = PHLivePhotoView()
    private var livePhoto: PHLivePhoto?
    private var loadTask: Task<Void, Never>?
    private var wantsPlay: PHLivePhotoViewPlaybackStyle?
    private weak var host: UIView?

    override init() {
        super.init()
        view.delegate = self
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        view.alpha = 0
    }

    /// Puts the (hidden) live view over `host` (the page's image view, so it zooms with it).
    func attach(to host: UIView) {
        self.host = host
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
    }

    func tearDown() {
        loadTask?.cancel()
        view.stopPlayback()
        view.removeFromSuperview()
        livePhoto = nil
    }

    var isLoaded: Bool { livePhoto != nil }

    func loadPhone(localID: String, targetSize: CGSize) {
        guard livePhoto == nil, loadTask == nil,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return }
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        loadTask = Task { [weak self] in
            let photo: PHLivePhoto? = await withCheckedContinuation { continuation in
                var resumed = false
                PHImageManager.default().requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { photo, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded, !resumed else { return }
                    resumed = true
                    continuation.resume(returning: photo)
                }
            }
            self?.loaded(photo)
        }
    }

    /// Downloads both originals (cached afterwards) and pairs them.
    func loadCloud(stillID: String, stillName: String, motionID: String, motionName: String, originals: OriginalStore) {
        guard livePhoto == nil, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            do {
                async let still = originals.file(assetID: stillID, fileName: stillName)
                async let motion = originals.file(assetID: motionID, fileName: motionName)
                let urls = try await [still, motion]
                let photo: PHLivePhoto? = await withCheckedContinuation { continuation in
                    var resumed = false
                    PHLivePhoto.request(withResourceFileURLs: urls, placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { photo, info in
                        let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                        let failed = info[PHLivePhotoInfoErrorKey] != nil || (info[PHLivePhotoInfoCancelledKey] as? Bool) == true
                        guard !resumed, failed || !degraded else { return }
                        resumed = true
                        continuation.resume(returning: failed ? nil : photo)
                    }
                }
                self?.loaded(photo)
            } catch {
                Log.media.info("Live Photo parts failed: \(error.localizedDescription, privacy: .public)")
                self?.loadTask = nil
            }
        }
    }

    private func loaded(_ photo: PHLivePhoto?) {
        loadTask = nil
        guard let photo else { return }
        livePhoto = photo
        view.livePhoto = photo
        if let style = wantsPlay {
            wantsPlay = nil
            start(style)
        }
    }

    /// Full playback while pressed; `.hint` is the short preview when swiping to it.
    func play(_ style: PHLivePhotoViewPlaybackStyle) {
        guard livePhoto != nil else {
            wantsPlay = style
            return
        }
        start(style)
    }

    func stop() {
        wantsPlay = nil
        view.stopPlayback()
    }

    private func start(_ style: PHLivePhotoViewPlaybackStyle) {
        view.alpha = 1
        view.startPlayback(with: style)
        if style == .full {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    nonisolated func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        MainActor.assumeIsolated {
            UIView.animate(withDuration: 0.2) { self.view.alpha = 0 }
        }
    }
}
