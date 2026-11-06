import AVFoundation
import Foundation
import ImageIO
import MediaCache
import UniformTypeIdentifiers

/// Makes a copy of an original that looks identical but is a different file.
///
/// Immich identifies assets by checksum, so an exact byte copy would be rejected as
/// a duplicate. The copy keeps every pixel and all metadata (no re-encoding) and
/// adds one marker, which changes the checksum so the server stores it as a new asset.
enum Duplicator {
    static let markerNamespace = "http://ns.ethwood.photos/1.0/"
    static let markerPrefix = "photosapp"

    /// Writes the copy into a fresh temporary folder, keeping the original file name.
    static func makeCopy(of original: URL) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "duplicate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: original.lastPathComponent)
        let type = UTType(filenameExtension: original.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            try await copyVideo(original, to: destination)
        } else {
            try copyImage(original, to: destination)
        }
        return destination
    }

    /// Lossless: `CGImageDestinationCopyImageSource` rewrites the container (all images,
    /// auxiliary data like depth and HDR gain maps) with merged metadata, without decoding.
    static func copyImage(_ source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, type, CGImageSourceGetCount(imageSource), nil)
        else { throw MediaError(kind: .undecodable, message: "The photo couldn’t be read to duplicate it.") }

        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, markerNamespace as CFString, markerPrefix as CFString, nil)
        CGImageMetadataSetValueWithPath(metadata, nil, "\(markerPrefix):DuplicateID" as CFString, UUID().uuidString as CFString)
        let options = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(output, imageSource, options, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw MediaError(kind: .undecodable, message: "Duplicating the photo failed: \(reason)")
        }
    }

    /// Passthrough export (no re-encoding) with the original metadata plus a marker.
    static func copyVideo(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError(kind: .undecodable, message: "The video couldn’t be read to duplicate it.")
        }
        let marker = AVMutableMetadataItem()
        marker.keySpace = .quickTimeMetadata
        marker.key = "com.ethwood.photos.duplicate-id" as NSString
        marker.value = UUID().uuidString as NSString
        export.metadata = (try await asset.load(.metadata)) + [marker]
        let fileType: AVFileType = source.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        try await export.export(to: destination, as: fileType)
    }
}
