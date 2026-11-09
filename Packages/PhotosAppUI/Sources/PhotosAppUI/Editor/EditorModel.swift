import AVFoundation
import Cinematic
import CloudCore
import CoreImage
import Core
import Observation
import Persistence
import Photos
import UIKit

/// State of the editor (the Edit screen) for one photo or video.
@MainActor
@Observable
final class EditorModel {
    enum Tool: String, CaseIterable, Identifiable {
        case video, audioMix, adjust, filters, crop
        var id: Self { self }

        var title: String {
            switch self {
            case .video: String(localized: "Video")
            case .audioMix: String(localized: "Audio Mix")
            case .adjust: String(localized: "Adjust")
            case .filters: String(localized: "Filters")
            case .crop: String(localized: "Crop")
            }
        }

        var symbol: String {
            switch self {
            case .video: "video"
            case .audioMix: "waveform.and.person.filled"
            case .adjust: "dial.medium"
            case .filters: "camera.filters"
            case .crop: "crop.rotate"
            }
        }
    }

    enum Selection: Hashable { case auto, adjustment(EditState.Adjustment) }

    let item: TimelineItem
    let session: LibrarySession
    var state = EditState() { didSet { if state != oldValue { schedulePreview() } } }
    private(set) var original = EditState()
    var tool: Tool { didSet { if tool != oldValue && (tool == .crop || oldValue == .crop) { schedulePreview() } } }
    var selection: Selection = .auto
    private(set) var tools: [Tool]
    private(set) var preview: UIImage?
    private(set) var filterThumbnails: [EditState.Filter: UIImage] = [:]
    private(set) var isSaving = false
    private(set) var isLoading = true
    var errorMessage: String?

    // Video
    let player = AVPlayer()
    private(set) var duration: Double = 0
    private(set) var frames: [UIImage] = []
    /// `CNAssetSpatialAudioInfo` (iOS 26) when the video has spatial audio (Audio Mix).
    @ObservationIgnored private var spatialAudio: AnyObject?
    private var videoAsset: AVAsset?

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    @ObservationIgnored private var source: CIImage?
    @ObservationIgnored private var autoFilters: [CIFilter] = []
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(item: TimelineItem, session: LibrarySession) {
        self.item = item
        self.session = session
        tools = item.isVideo ? [.video, .adjust, .filters, .crop] : [.adjust, .filters, .crop]
        tool = item.isVideo ? .video : .adjust
    }

    var hasChanges: Bool { state != original }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEdited: Bool { !original.isIdentity }

    // MARK: Loading

    func load() async {
        defer { isLoading = false }
        if let localID = item.localID {
            if let stored = await EditSaver.storedState(localID: localID) {
                original = stored
                state = stored
            }
        }
        if item.isVideo {
            await loadVideo()
        } else {
            await loadPhoto()
        }
    }

    private func loadPhoto() async {
        let side: CGFloat = 2048
        var image: UIImage?
        if let localID = item.localID {
            image = await EditorSource.photo(localID: localID, side: side, original: isEdited)
        } else if let cg = try? await session.pipeline.image(assetID: item.id, size: .preview, maxPixelSize: Int(side), revision: item.thumbhash) {
            image = UIImage(cgImage: cg)
        }
        guard let image, let ci = CIImage(image: image, options: [.applyOrientationProperty: true]) else {
            errorMessage = String(localized: "The photo couldn't be loaded.")
            return
        }
        source = ci.oriented(CGImagePropertyOrientation(image.imageOrientation))
        autoFilters = source?.autoAdjustmentFilters() ?? []
        renderPreview()
        renderFilterThumbnails()
    }

    private func loadVideo() async {
        var asset: AVAsset?
        if let localID = item.localID {
            asset = await EditorSource.video(localID: localID, original: isEdited).asset
        } else if let stream = session.connection?.media.videoStream(assetID: item.id) {
            asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        }
        guard let asset else {
            errorMessage = String(localized: "The video couldn't be loaded.")
            return
        }
        videoAsset = asset
        duration = (try? await asset.load(.duration).seconds) ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        let box = AssetBox(asset: asset)
        if #available(iOS 26.0, *), CNAssetSpatialAudioInfo.isSupported {
            spatialAudio = await Self.loadSpatialAudio(box)?.info
            if spatialAudio != nil { tools.insert(.audioMix, at: 1) }
        }
        // A poster frame for filter thumbnails, and frames for the trim strip.
        let (poster, images) = await Self.frames(box, duration: duration)
        if let poster {
            source = CIImage(cgImage: poster)
            renderFilterThumbnails()
        }
        frames = images.map { UIImage(cgImage: $0) }
        applyVideoPreview()
    }

    @available(iOS 26.0, *)
    @concurrent
    private static func loadSpatialAudio(_ box: AssetBox) async -> InfoBox? {
        guard let asset = box.asset else { return nil }
        let has: Bool = await withCheckedContinuation { continuation in
            CNAssetSpatialAudioInfo.checkIfContainsSpatialAudio(asset: asset) { continuation.resume(returning: $0) }
        }
        guard has, let info = try? await CNAssetSpatialAudioInfo(asset: asset) else { return nil }
        return InfoBox(info: info)
    }

    @concurrent
    private static func frames(_ box: AssetBox, duration: Double) async -> (CGImage?, [CGImage]) {
        guard let asset = box.asset else { return (nil, []) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let poster = try? await generator.image(at: .zero).image
        var images: [CGImage] = []
        for index in 0..<12 where duration > 0 {
            if let frame = try? await generator.image(at: CMTime(seconds: duration * (Double(index) + 0.5) / 12, preferredTimescale: 600)).image {
                images.append(frame)
            }
        }
        return (poster, images)
    }

    @concurrent
    private static func composition(_ box: AssetBox, state: EditState) async -> CompositionBox? {
        guard let asset = box.asset,
              let composition = try? await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                  request.finish(with: EditRenderer.apply(state, to: request.sourceImage), context: nil)
              }) else { return nil }
        return CompositionBox(composition: composition)
    }

    // MARK: Changes

    /// Records the state before a gesture or tap, for Undo.
    func beginChange() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(state)
        state = last
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    func revertToOriginal() {
        beginChange()
        state = EditState()
    }

    // MARK: Preview

    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            if self.item.isVideo { self.applyVideoPreview() } else { self.renderPreview() }
        }
    }

    private func renderPreview() {
        guard let source else { return }
        let rendered = EditRenderer.apply(previewState, to: source, autoFilters: autoFilters)
        if let cg = Self.context.createCGImage(rendered, from: rendered.extent) {
            preview = UIImage(cgImage: cg)
        }
    }

    private func renderFilterThumbnails() {
        guard let source else { return }
        let scale = 160 / max(source.extent.width, source.extent.height)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var thumbnails: [EditState.Filter: UIImage] = [:]
        for filter in EditState.Filter.allCases {
            var look = EditState()
            look.filter = filter
            let image = EditRenderer.apply(look, to: small)
            if let cg = Self.context.createCGImage(image, from: image.extent) { thumbnails[filter] = UIImage(cgImage: cg) }
        }
        filterThumbnails = thumbnails
    }

    /// The video plays with the edit applied live (a Core Image video composition) and the chosen audio mix.
    private func applyVideoPreview() {
        guard let videoAsset, let current = player.currentItem else { return }
        let state = previewState
        if state.hasVisualChanges {
            let box = AssetBox(asset: videoAsset)
            Task {
                current.videoComposition = await Self.composition(box, state: state)?.composition
            }
        } else {
            current.videoComposition = nil
        }
        if #available(iOS 26.0, *), let spatialAudio = spatialAudio as? CNAssetSpatialAudioInfo {
            current.audioMix = spatialAudio.audioMix(effectIntensity: spatialAudio.defaultEffectIntensity, renderingStyle: state.audioMix.renderingStyle)
        }
        player.isMuted = state.muted
    }

    /// While cropping, the preview shows the whole photo so the crop frame can move back out.
    private var previewState: EditState {
        var shown = state
        if tool == .crop { shown.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
        return shown
    }

    // MARK: Saving

    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            if state.isIdentity {
                // Revert to Original: a phone item goes back to its original (PhotoKit keeps
                // it); an unedited Cloud item has nothing to save.
                if let localID = item.localID, isEdited { try await EditSaver.revertPhone(localID: localID) }
                Log.ui.info("Reverted \(self.item.id, privacy: .public) to its original")
                return true
            }
            if let localID = item.localID {
                try await EditSaver.savePhone(localID: localID, state: state)
            } else {
                let details = session.detailsNow(for: item.id)
                try await EditSaver.saveCloud(
                    assetID: item.id, fileName: details?.asset.originalFileName ?? (item.isVideo ? "Video.MOV" : "Photo.HEIC"),
                    isVideo: item.isVideo, createdAt: details?.asset.fileCreatedAt, state: state, session: session
                )
            }
            Log.ui.info("Saved an edit to \(self.item.id, privacy: .public)")
            return true
        } catch {
            errorMessage = CloudError.message(for: error)
            return false
        }
    }
}

/// AVFoundation objects handed between tasks; each is used by one task at a time.
private struct AssetBox: @unchecked Sendable { let asset: AVAsset? }
private struct InfoBox: @unchecked Sendable { let info: AnyObject }
private struct CompositionBox: @unchecked Sendable { let composition: AVVideoComposition }

extension EditState.AudioMix {
    @available(iOS 26.0, *)
    var renderingStyle: CNSpatialAudioRenderingStyle {
        switch self {
        case .standard: .standard
        case .inFrame: .inFrame
        case .studio: .studio
        case .cinematic: .cinematic
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Loads the phone's original for editing. PhotoKit calls back on its own queues, so the
/// callbacks are built here, off the main actor (a main-actor callback there stops the app).
private enum EditorSource {
    /// `original`: the unedited original (our own edit, whose values reopen on it); otherwise the
    /// current version, which is also what a save edits when another app made the last change.
    static func photo(localID: String, side: CGFloat, original: Bool) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        let box: ImageBox = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = original ? .original : .current
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: ImageBox(image: image))
            }
        }
        return box.image
    }

    static func video(localID: String, original: Bool) async -> AssetBox {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return AssetBox(asset: nil) }
        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = original ? .original : .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { asset, _, _ in
                continuation.resume(returning: AssetBox(asset: asset))
            }
        }
    }

    struct ImageBox: @unchecked Sendable { let image: UIImage? }
}
