import AVFoundation
import CloudCore
import CoreImage
import Core
import Foundation
import Photos
import UniformTypeIdentifiers

/// Saves edits without losing quality or metadata:
/// - phone photos and videos become a normal PhotoKit edit (original kept, revertible, synced
///   by iCloud); backup then uploads the new version and stacks it with the old one;
/// - Cloud-only items are rendered from the original into a new full-quality file, uploaded,
///   and stacked with the original (which stays untouched).
enum EditSaver {
    static let formatIdentifier = "com.ethwood.photos.edit"
    static let formatVersion = "1"
    private static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    // MARK: Phone (PhotoKit)

    /// The edit stored with a phone asset by this app, if any.
    static func storedState(localID: String) async -> EditState? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
              let input = try? await contentEditingInput(for: asset),
              let data = input.adjustmentData, data.formatIdentifier == formatIdentifier else { return nil }
        return try? JSONDecoder().decode(EditState.self, from: data.data)
    }

    static func savePhone(localID: String, state: EditState) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            throw CloudError(kind: .decoding, message: String(localized: "This item is no longer on the iPhone."))
        }
        let input = try await contentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: formatIdentifier, formatVersion: formatVersion, data: try JSONEncoder().encode(state))

        switch asset.mediaType {
        case .video:
            guard let source = input.audiovisualAsset else { throw saveError() }
            let target = try output.renderedContentURL(for: .quickTimeMovie)
            try await renderVideo(source, state: state, to: target)
        default:
            if asset.mediaSubtypes.contains(.photoLive), let live = PHLivePhotoEditingContext(livePhotoEditingInput: input) {
                // The still and the motion get the same edit, so they stay a pair.
                live.frameProcessor = { frame, _ in EditRenderer.apply(state, to: frame.image, autoFilters: state.auto ? frame.image.autoAdjustmentFilters() : []) }
                try await live.saveLivePhoto(to: output)
            } else {
                guard let url = input.fullSizeImageURL else { throw saveError() }
                let target = try output.renderedContentURL(for: .heic)
                try renderPhoto(from: url, state: state, to: target)
            }
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    static func revertPhone(localID: String) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
        }
    }

    static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Our own edits reopen from the original with their parameters.
        options.canHandleAdjustmentData = { $0.formatIdentifier == formatIdentifier }
        let box: InputBox = try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: InputBox(input: input))
                } else {
                    continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? saveError())
                }
            }
        }
        return box.input
    }

    /// PhotoKit hands the input over once; it isn't used concurrently.
    struct InputBox: @unchecked Sendable { let input: PHContentEditingInput }

    // MARK: Rendering

    /// Renders a photo with HDR kept (a new gain map from the edited HDR rendition) and every
    /// metadata field of the original (EXIF, GPS, dates, camera), written as HEIC.
    static func renderPhoto(from source: URL, state: EditState, to target: URL) throws {
        guard let original = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw saveError()
        }
        // The stored image is the SDR rendition; with a gain map, the HDR one is that plus the map.
        let gainMap = CIImage(contentsOf: source, options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: true])
        let autoFilters = state.auto ? original.autoAdjustmentFilters() : []
        let edited = EditRenderer.apply(state, to: original, autoFilters: autoFilters)
        let extent = edited.extent
        var properties = original.properties
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = Int(extent.width)
        properties[kCGImagePropertyPixelHeight as String] = Int(extent.height)
        // The SDR base keeps the original's colour space (Display P3 on iPhone).
        let colorSpace = original.colorSpace.flatMap { CGColorSpaceUsesITUR_2100TF($0) || CGColorSpaceUsesExtendedRange($0) ? nil : $0 } ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let base = edited.settingAlphaOne(in: extent).settingProperties(properties)
        var options: [CIImageRepresentationOption: Any] = [:]
        if let gainMap {
            let hdr = original.applyingGainMap(gainMap)
            options[.hdrImage] = EditRenderer.apply(state, to: hdr, autoFilters: autoFilters).settingAlphaOne(in: extent)
        }
        try context.writeHEIFRepresentation(of: base, to: target, format: .RGBA8, colorSpace: colorSpace, options: options)
    }

    /// Trim/mute only: no re-encoding at all (Dolby Vision, spatial audio and metadata stay
    /// bit-for-bit). Visual edits: re-encoded as HEVC at the highest quality, HDR kept, metadata copied.
    static func renderVideo(_ source: AVAsset, state: EditState, to target: URL) async throws {
        let duration = try await source.load(.duration)
        let start = CMTime(seconds: state.trimStart, preferredTimescale: 600)
        let end = state.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? duration
        let range = CMTimeRange(start: start, end: min(end, duration))

        let composition = AVMutableComposition()
        for track in try await source.load(.tracks) {
            if state.muted && track.mediaType == .audio { continue }
            guard let added = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try added.insertTimeRange(range, of: track, at: .zero)
            added.preferredTransform = try await track.load(.preferredTransform)
            added.languageCode = try await track.load(.languageCode)
            added.extendedLanguageTag = try await track.load(.extendedLanguageTag)
        }
        let metadata = try await source.load(.metadata)
        try? FileManager.default.removeItem(at: target)

        if !state.hasVisualChanges {
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw saveError() }
            export.metadata = metadata
            try await export.export(to: target, as: .mov)
            return
        }
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            let image = EditRenderer.apply(state, to: request.sourceImage.clampedToExtent().cropped(to: request.sourceImage.extent))
            request.finish(with: image, context: nil)
        }
        // Cropping and quarter turns change the frame size.
        if let track = try await composition.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let upright = CGRect(origin: .zero, size: natural).applying(transform).size
            let rendered = EditRenderer.geometry(CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: CGSize(width: abs(upright.width), height: abs(upright.height)))), state).extent.size
            videoComposition.renderSize = CGSize(width: (rendered.width / 2).rounded() * 2, height: (rendered.height / 2).rounded() * 2)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else { throw saveError() }
        export.videoComposition = videoComposition
        export.metadata = metadata
        try await export.export(to: target, as: .mov)
    }

    // MARK: Cloud-only

    /// Renders a new version from the Cloud original and uploads it, stacked over the original.
    @MainActor
    static func saveCloud(assetID: String, fileName: String, isVideo: Bool, createdAt: Date?, state: EditState, session: LibrarySession) async throws {
        let connection = try session.connected()
        let original = try await session.originals.file(assetID: assetID, fileName: fileName)
        let folder = FileManager.default.temporaryDirectory.appending(path: "edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = (fileName as NSString).deletingPathExtension
        let target = folder.appending(path: isVideo ? "\(base).MOV" : "\(base).HEIC")
        if isVideo {
            try await renderVideo(AVURLAsset(url: original), state: state, to: target)
        } else {
            try renderPhoto(from: original, state: state, to: target)
        }
        let result = try await connection.upload(CloudUploadFile(fileURL: target, fileName: target.lastPathComponent, createdAt: createdAt ?? .now, modifiedAt: .now))
        try await connection.stack(assetIDs: [result.assetID, assetID])
        session.syncNow()
    }

    private static func saveError() -> CloudError {
        CloudError(kind: .decoding, message: String(localized: "The edit couldn't be saved."))
    }
}
