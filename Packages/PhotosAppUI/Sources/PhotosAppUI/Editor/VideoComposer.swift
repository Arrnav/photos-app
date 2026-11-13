import AVFoundation
import CoreImage

/// Builds the Core Image video composition that renders an edit, for both the live preview and
/// the saved file, so the two always agree.
///
/// Rotating and cropping change the frame size. The composition's render size follows the edit,
/// and every frame is scaled to fill it exactly over black: video buffers are reused, and any
/// area a frame doesn't cover would show stale pixels (green, or a ghost of an earlier frame).
enum VideoComposer {
    /// The size of the first video track as it's shown (its preferred transform applied).
    nonisolated(nonsending) static func uprightSize(of asset: AVAsset) async throws -> CGSize? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    static func composition(for asset: AVAsset, state: EditState, auto: AutoAdjust?) async throws -> AVMutableVideoComposition {
        let filters = state.auto ? auto : nil
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            let renderSize = request.renderSize
            let frame = EditRenderer.videoFrame(state, source: source, renderSize: renderSize, autoFilters: filters?.makeFilters() ?? [])
            request.finish(with: frame, context: nil)
        }
        if let upright = try await uprightSize(of: asset) {
            composition.renderSize = EditRenderer.videoRenderSize(upright: upright, state: state)
        }
        return composition
    }

    /// One upright frame at exactly `time` (`.zero` size: full resolution).
    @concurrent
    static func frame(_ box: AssetBox, at time: CMTime, maximumSize: CGSize = .zero) async -> CGImage? {
        guard let asset = box.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = maximumSize
        return try? await generator.image(at: time).image
    }
}

/// Auto's filters, worked out once from a frame of the video and recreated for every frame
/// (frames render concurrently, and a `CIFilter` holds its input image).
struct AutoAdjust: @unchecked Sendable {
    private let filters: [(name: String, values: [String: Any])]

    init(image: CIImage) {
        // No red-eye: it's tied to positions in one frame.
        filters = image.autoAdjustmentFilters(options: [.redEye: false]).map { filter in
            var values: [String: Any] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                values[key] = filter.value(forKey: key)
            }
            return (filter.name, values)
        }
    }

    /// From a frame a little way in (the first frame is often dark or blurred).
    nonisolated(nonsending) static func from(_ asset: AVAsset) async -> AutoAdjust? {
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let frame = await VideoComposer.frame(AssetBox(asset: asset), at: time, maximumSize: CGSize(width: 400, height: 400)) else { return nil }
        return AutoAdjust(image: CIImage(cgImage: frame))
    }

    var isEmpty: Bool { filters.isEmpty }

    func makeFilters() -> [CIFilter] {
        filters.compactMap { entry in
            guard let filter = CIFilter(name: entry.name) else { return nil }
            for (key, value) in entry.values { filter.setValue(value, forKey: key) }
            return filter
        }
    }
}
