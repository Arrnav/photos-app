import Foundation
import Photos

/// What the checksum rule needs to know about a `PHAssetResource`, so it can be tested
/// without a photo library.
public protocol ResourceDescription {
    var type: PHAssetResourceType { get }
    /// Private PhotoKit flag: the resource that represents the asset as it looks now.
    var isCurrent: Bool { get }
}

extension PHAssetResource: ResourceDescription {
    public var isCurrent: Bool {
        // Not public API; the official app relies on it too (PLAN.md §7). Guarded so a
        // future iOS without it falls back to the full-size rule.
        guard responds(to: NSSelectorFromString("isCurrent")) else { return false }
        return value(forKey: "isCurrent") as? Bool ?? false
    }
}

/// Which resource of an asset is hashed and uploaded (PLAN.md D5). This must pick the
/// same file as the official Immich app, or both apps would upload the same photo:
/// - keep media resources of the asset's kind (photo: photo/alternate/full-size;
///   video: video/full-size video/full-size paired video), never adjustment data or proxies;
/// - one left: use it; several: the "current" one, else the full-size one, else none.
/// For an edited photo that's the rendered edit; for a Live Photo, only the still.
public enum ResourceSelection {
    public static func uploadResource<R: ResourceDescription>(among resources: [R], mediaType: PHAssetMediaType) -> R? {
        let candidates = resources.filter { isMedia($0.type) && isValid($0.type, for: mediaType) }
        if candidates.count <= 1 { return candidates.first }
        if let current = candidates.first(where: \.isCurrent) { return current }
        return candidates.first { isFullSize($0.type, for: mediaType) }
    }

    /// A Live Photo's motion part (uploaded first, hidden, then linked to the still).
    public static func motionResource<R: ResourceDescription>(among resources: [R]) -> R? {
        let candidates = resources.filter { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
        if candidates.count <= 1 { return candidates.first }
        return candidates.first(where: \.isCurrent) ?? candidates.first { $0.type == .fullSizePairedVideo }
    }

    private static func isMedia(_ type: PHAssetResourceType) -> Bool {
        type != .adjustmentData && type != .photoProxy
    }

    private static func isValid(_ type: PHAssetResourceType, for mediaType: PHAssetMediaType) -> Bool {
        switch mediaType {
        case .image: [.photo, .alternatePhoto, .fullSizePhoto].contains(type)
        case .video: [.video, .fullSizeVideo, .fullSizePairedVideo].contains(type)
        default: false
        }
    }

    private static func isFullSize(_ type: PHAssetResourceType, for mediaType: PHAssetMediaType) -> Bool {
        switch mediaType {
        case .image: type == .fullSizePhoto
        case .video: type == .fullSizeVideo
        default: false
        }
    }
}
