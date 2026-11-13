import AVFoundation
import Core
import Foundation
import ImageIO
import LinkPresentation
import MediaCache
import UIKit
import UniformTypeIdentifiers

/// Share › Options.
struct ShareOptions: Equatable, Sendable {
    enum Format: String, CaseIterable, Sendable {
        /// Here it shares the original format, like Current.
        case automatic
        /// The original file, unconverted.
        case current
        /// JPEG for photos, H.264 for videos.
        case mostCompatible
    }

    var includeLocation = true
    var format = Format.automatic
    /// "All Photos Data": the untouched original with every bit of metadata.
    var allPhotosData = false
}

/// Prepares one file for sharing from an original, applying the options. Photos stay
/// lossless unless converted; location removal rewrites metadata only.
enum ShareExport {
    /// Converted files go into a new subfolder of `folder` (the caller removes `folder`).
    static func prepare(original: URL, isVideo: Bool, options: ShareOptions, in folder: URL) async throws -> URL {
        if options.allPhotosData { return original }
        let convert = options.format == .mostCompatible
        if isVideo {
            let isHEVC = await isHEVCVideo(original)
            guard !options.includeLocation || (convert && isHEVC) else { return original }
            return try await exportVideo(original, toH264: convert && isHEVC, stripLocation: !options.includeLocation, in: folder)
        }
        let isHEIF = ["heic", "heif"].contains(original.pathExtension.lowercased())
        if convert && isHEIF {
            return try convertToJPEG(original, stripLocation: !options.includeLocation, in: folder)
        }
        if !options.includeLocation {
            return try copyWithoutLocation(original, in: folder)
        }
        return original
    }

    private static func outputURL(for original: URL, extension ext: String? = nil, in parent: URL) throws -> URL {
        let folder = parent.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = original.deletingPathExtension().lastPathComponent
        return folder.appending(path: "\(base).\(ext ?? original.pathExtension)")
    }

    private static func copyWithoutLocation(_ original: URL, in folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw MediaError(kind: .undecodable, message: "The photo couldn’t be prepared for sharing.")
        }
        let output = try outputURL(for: original, in: folder)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw MediaError(kind: .undecodable, message: "The photo couldn’t be prepared for sharing.")
        }
        let options = [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            throw MediaError(kind: .undecodable, message: "Removing the location from the photo failed.")
        }
        return output
    }

    static func convertToJPEG(_ original: URL, stripLocation: Bool, in folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw MediaError(kind: .undecodable, message: "The photo couldn’t be converted for sharing.") }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if stripLocation { properties[kCGImagePropertyGPSDictionary] = nil }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        let output = try outputURL(for: original, extension: "jpg", in: folder)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaError(kind: .undecodable, message: "The photo couldn’t be converted for sharing.")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError(kind: .undecodable, message: "Converting the photo to JPEG failed.")
        }
        return output
    }

    private static func isHEVCVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions)
        else { return false }
        return formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
    }

    private static func exportVideo(_ original: URL, toH264: Bool, stripLocation: Bool, in folder: URL) async throws -> URL {
        let asset = AVURLAsset(url: original)
        let preset = toH264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError(kind: .undecodable, message: "The video couldn’t be prepared for sharing.")
        }
        var metadata = try await asset.load(.metadata)
        if stripLocation {
            let locationIdentifiers: Set<AVMetadataIdentifier> = [.quickTimeMetadataLocationISO6709, .commonIdentifierLocation, .quickTimeUserDataLocationISO6709]
            metadata.removeAll { item in item.identifier.map(locationIdentifiers.contains) ?? false }
        }
        export.metadata = metadata
        let output = try outputURL(for: original, extension: toH264 ? "mp4" : original.pathExtension, in: folder)
        try await export.export(to: output, as: toH264 ? .mp4 : (original.pathExtension.lowercased() == "mp4" ? .mp4 : .mov))
        return output
    }
}

/// What the share options share. The selected files are prepared (downloaded, or exported
/// from the phone, with the options applied) before the share options can be used
/// ("Preparing…"), and handed to the destination as plain, correctly named file URLs:
/// the form every share extension (WhatsApp, Mail, AirDrop, Files) reads reliably.
final class ShareItems: @unchecked Sendable {
    struct Entry: Sendable {
        let assetID: String
        let fileName: String
        let isVideo: Bool
        /// The phone's copy, shared directly instead of downloading.
        var localID: String? = nil
        /// Shown in the share options' header.
        var thumbnail: UIImage? = nil
    }

    /// Gets the file for an entry (the phone's copy, written into the given folder, or the
    /// downloaded original), reporting progress 0…1.
    typealias FileSource = @Sendable (Entry, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    private let fileSource: FileSource
    /// Every file this share writes lives here, and goes when the share screen closes.
    let folder = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let lock = NSLock()
    private var _entries: [Entry] = []
    private var _options = ShareOptions()
    /// Prepared (or preparing) files, per asset, options and variant.
    private var prepared: [String: Task<URL, Error>] = [:]
    private var readyKeys: Set<String> = []

    var entries: [Entry] {
        get { lock.withLock { _entries } }
        set { lock.withLock { _entries = newValue } }
    }

    var options: ShareOptions {
        get { lock.withLock { _options } }
        set { lock.withLock { _options = newValue } }
    }

    init(fileSource: @escaping FileSource) {
        self.fileSource = fileSource
    }

    /// Told when a destination asked for a file that couldn't be prepared (it gets nothing).
    var onItemFailure: (@Sendable (String) -> Void)?

    /// One item per selected file, for `UIActivityViewController(activityItems:)`.
    @MainActor
    func activityItems() -> [UIActivityItemProvider] {
        let title = self.title
        return entries.map { ShareFileItem(entry: $0, items: self, title: title) }
    }

    /// "1 Photo", "2 Videos", "3 Items".
    var title: String {
        let entries = entries
        let videos = entries.filter(\.isVideo).count
        let photos = entries.count - videos
        switch (photos, videos) {
        case (_, 0): return photos == 1 ? String(localized: "1 Photo") : String(localized: "\(photos) Photos")
        case (0, _): return videos == 1 ? String(localized: "1 Video") : String(localized: "\(videos) Videos")
        default: return String(localized: "\(entries.count) Items")
        }
    }

    /// Prepares every selected file, one at a time (gentle on the server), reporting overall
    /// progress 0…1. Returns the first error, if any.
    func prepareAll(progress: @escaping @Sendable (Double) -> Void) async -> Error? {
        let entries = entries
        guard !entries.isEmpty else { return nil }
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { return CancellationError() }
            let done = Double(index)
            do {
                _ = try await file(for: entry, compatible: false) { value in
                    progress((done + value) / Double(entries.count))
                }
            } catch {
                return error
            }
        }
        progress(1)
        return nil
    }

    /// Whether every selected file is ready to hand over (nothing left to wait for).
    func isReady() -> Bool {
        let keys = entries.map { key(for: $0, compatible: false) }
        return lock.withLock { keys.allSatisfy(readyKeys.contains) }
    }

    private func key(for entry: Entry, compatible: Bool) -> String {
        let options = options
        return "\(entry.assetID)|\(options.includeLocation)|\(options.format.rawValue)|\(options.allPhotosData)|\(compatible)"
    }

    /// The file to share for an entry with the current options (prepared once, then reused).
    /// `compatible`: a JPEG instead of HEIC, for third-party apps (Automatic).
    func file(for entry: Entry, compatible: Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let options = options
        let compatible = compatible && !entry.isVideo && !options.allPhotosData && options.format == .automatic
        let key = key(for: entry, compatible: compatible)
        let fileSource = fileSource
        let task = lock.withLock {
            if let task = prepared[key] { return task }
            let task = Task {
                if compatible {
                    let file = try await self.file(for: entry, compatible: false, progress: progress)
                    guard ["heic", "heif"].contains(file.pathExtension.lowercased()) else { return file }
                    // The location was already handled in the first file.
                    return try ShareExport.convertToJPEG(file, stripLocation: false, in: self.folder)
                }
                return try await Self.prepare(entry, options: options, fileSource: fileSource, folder: self.folder, progress: progress)
            }
            prepared[key] = task
            return task
        }
        do {
            let url = try await task.value
            _ = lock.withLock { readyKeys.insert(key) }
            return url
        } catch {
            _ = lock.withLock { prepared.removeValue(forKey: key) }
            throw error
        }
    }

    /// Stops any preparation still running (the share screen closed).
    func cancel() {
        lock.withLock { prepared.values.forEach { $0.cancel() } }
    }

    /// Deletes this share's files. The system copies a file before a destination uses it, so
    /// this is safe once the share screen has closed; a short delay covers a destination still
    /// finishing its copy.
    func removeFiles(after delay: Duration = .seconds(30)) {
        let folder = folder
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Where the file will be; the share options use its extension to pick destinations.
    func placeholderURL(for entry: Entry) -> URL {
        let options = options
        let originalType = UTType(filenameExtension: (entry.fileName as NSString).pathExtension) ?? (entry.isVideo ? .quickTimeMovie : .heic)
        let type: UTType = options.format == .mostCompatible && !options.allPhotosData
            ? (entry.isVideo ? (originalType == .mpeg4Movie ? originalType : .mpeg4Movie) : (originalType.conforms(to: .heif) ? .jpeg : originalType))
            : originalType
        let ext = type.preferredFilenameExtension ?? (entry.isVideo ? "mov" : "heic")
        return FileManager.default.temporaryDirectory
            .appending(path: "share-placeholder", directoryHint: .isDirectory)
            .appending(path: Self.baseName(entry.fileName) + "." + ext)
    }

    private static func baseName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
        return base.isEmpty ? "Photo" : base
    }

    private static func prepare(_ entry: Entry, options: ShareOptions, fileSource: FileSource, folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let started = Date()
        do {
            let url = try await prepareFile(entry, options: options, fileSource: fileSource, folder: folder, progress: progress)
            ShareLog.write("prepared \(entry.fileName) (\(entry.localID == nil ? "Cloud" : "phone")) -> \(url.lastPathComponent) \(ShareLog.size(of: url)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return url
        } catch {
            ShareLog.write("FAILED preparing \(entry.fileName) (\(entry.localID == nil ? "Cloud" : "phone")) after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(error)")
            throw error
        }
    }

    private static func prepareFile(_ entry: Entry, options: ShareOptions, fileSource: FileSource, folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try await fileSource(entry, folder) { value in progress(value * 0.95) }
        try Task.checkCancellation()
        let prepared = try await ShareExport.prepare(original: original, isVideo: entry.isVideo, options: options, in: folder)
        // A stable file named like the photo (IMG_1234.HEIC), which receivers show and keep.
        // A hard link, not a copy: a 4K video mustn't take its space twice.
        let named = folder.appending(path: "named-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let ext = prepared.pathExtension.isEmpty ? (entry.isVideo ? "MOV" : "HEIC") : prepared.pathExtension
        let target = named.appending(path: baseName(entry.fileName) + "." + ext)
        do {
            try FileManager.default.linkItem(at: prepared, to: target)
        } catch {
            try FileManager.default.copyItem(at: prepared, to: target)
        }
        progress(1)
        return target
    }
}

/// One shared file. The share options ask for it once a destination is chosen; by then it
/// is normally prepared, so it's handed over at once.
private final class ShareFileItem: UIActivityItemProvider, @unchecked Sendable {
    private let entry: ShareItems.Entry
    private let items: ShareItems
    private let title: String

    init(entry: ShareItems.Entry, items: ShareItems, title: String) {
        self.entry = entry
        self.items = items
        self.title = title
        super.init(placeholderItem: items.placeholderURL(for: entry))
    }

    override var item: Any {
        // Automatic: the system's own destinations get the original (HEIC), others a JPEG.
        let compatible = !(activityType?.rawValue.hasPrefix("com.apple.") ?? false)
        let started = Date()
        let onMain = Thread.isMainThread
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let entry = entry
        let items = items
        Task.detached {
            do {
                result.url = try await items.file(for: entry, compatible: compatible)
            } catch {
                Log.ui.error("Share: preparing \(entry.fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                items.onItemFailure?(String(localized: "“\(entry.fileName)” couldn’t be prepared for sharing: \(error.localizedDescription)"))
            }
            done.signal()
        }
        // Nothing the file needs runs on the main thread, so waiting can't deadlock.
        done.wait()
        let waited = Int(Date().timeIntervalSince(started) * 1000)
        ShareLog.write("\(activityType?.rawValue ?? "?") asked for \(entry.fileName)\(onMain ? " on the main thread" : ""): \(result.url.map { "\($0.lastPathComponent) \(ShareLog.size(of: $0))" } ?? "NOTHING (placeholder)") after \(waited) ms")
        return result.url ?? placeholderItem as Any
    }

    override func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let thumbnail = entry.thumbnail {
            metadata.imageProvider = NSItemProvider(object: thumbnail)
            metadata.iconProvider = NSItemProvider(object: thumbnail)
        }
        return metadata
    }
}

private final class ResultBox: @unchecked Sendable {
    var url: URL?
}

extension ShareExport {
    /// A JPEG of a photo file, with its metadata (and location only if included).
    static func jpegData(from url: URL, includeLocation: Bool) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if !includeLocation { properties[kCGImagePropertyGPSDictionary] = nil }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
