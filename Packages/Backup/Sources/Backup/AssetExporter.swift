import CloudCore
import Foundation
import Library
import Photos

/// What the server needs to know about a phone file before it's uploaded.
public struct ExportInfo: Sendable, Equatable {
    public var fileName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isFavorite: Bool
    public var durationSeconds: Double?
    /// iCloud identity etc. (only for the still / single file, like the official app).
    public var origin: CloudBackupOrigin?

    public init(fileName: String, createdAt: Date, modifiedAt: Date, isFavorite: Bool, durationSeconds: Double?, origin: CloudBackupOrigin?) {
        self.fileName = fileName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isFavorite = isFavorite
        self.durationSeconds = durationSeconds
        self.origin = origin
    }
}

/// Reads the file a backup uploads (so tests can replace the photo library).
public protocol AssetExporter: Sendable {
    func describe(localID: String, part: UploadPart) async throws -> ExportInfo
    /// Streams the file's bytes, in order, to `sink` (never holding the whole file).
    func stream(localID: String, part: UploadPart, allowNetwork: Bool, to sink: @escaping @Sendable (Data) throws -> Void) async throws
}

public enum UploadPart: String, Sendable { case single, motion, still }

/// Exports from PhotoKit with the same resource rule as checksums (docs/DESIGN.md D5), so the
/// uploaded bytes are exactly the hashed bytes.
public struct PhotoKitExporter: AssetExporter {
    public init() {}

    private func resource(localID: String, part: UploadPart) throws -> (PHAsset, [PHAssetResource], PHAssetResource) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            throw ChecksumError.assetGone
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let chosen: PHAssetResource?
        switch part {
        case .single, .still: chosen = ResourceSelection.uploadResource(among: resources, mediaType: asset.mediaType)
        case .motion: chosen = ResourceSelection.motionResource(among: resources)
        }
        guard let chosen else { throw ChecksumError.noUploadResource }
        return (asset, resources, chosen)
    }

    public func describe(localID: String, part: UploadPart) async throws -> ExportInfo {
        let (asset, resources, resource) = try resource(localID: localID, part: part)
        var origin: CloudBackupOrigin?
        if part != .motion, let cloud = try? PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localID])[localID]?.get() {
            origin = CloudBackupOrigin(
                cloudID: cloud.stringValue, createdAt: asset.creationDate, adjustmentTime: asset.photosEditTimestamp,
                latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude
            )
        }
        let created = asset.creationDate ?? .now
        return ExportInfo(
            // The asset's own name (IMG_1234) with the uploaded file's extension, like the official
            // app: an edited photo's current file is called "FullSizeRender", which says nothing.
            fileName: Self.uploadName(asset: asset, resources: resources, uploaded: resource),
            createdAt: created, modifiedAt: asset.modificationDate ?? created, isFavorite: asset.isFavorite,
            durationSeconds: asset.mediaType == .video ? asset.duration : 0, origin: origin
        )
    }

    /// Streams the resource from PhotoKit (downloading from iCloud if allowed) chunk by chunk.
    public func stream(localID: String, part: UploadPart, allowNetwork: Bool, to sink: @escaping @Sendable (Data) throws -> Void) async throws {
        let (_, _, resource) = try resource(localID: localID, part: part)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let state = StreamState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                    guard !state.failed else { return }
                    do {
                        // Each chunk is released straight away; a multi-GB video must not pile up in memory.
                        try autoreleasepool { try sink(chunk) }
                    } catch {
                        state.fail(error)
                    }
                } completionHandler: { error in
                    if let failure = state.failure {
                        continuation.resume(throwing: failure)
                    } else if let error {
                        let nsError = error as NSError
                        if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.networkAccessRequired.rawValue {
                            continuation.resume(throwing: ChecksumError.notOnPhone)
                        } else if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: ChecksumError.photoKit(error.localizedDescription))
                        }
                    } else {
                        continuation.resume()
                    }
                }
                state.requestID = id
            }
        } onCancel: {
            if let id = state.requestID { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }

    /// "IMG_1234" + the uploaded file's extension (".HEIC", ".JPG", ".MOV"…).
    static func uploadName(asset: PHAsset, resources: [PHAssetResource], uploaded: PHAssetResource) -> String {
        let original = (asset.value(forKey: "filename") as? String)
            ?? resources.first { $0.type == .photo || $0.type == .video }?.originalFilename
            ?? uploaded.originalFilename
        return uploadName(base: original, uploaded: uploaded.originalFilename)
    }

    static func uploadName(base original: String, uploaded: String) -> String {
        let base = (original as NSString).deletingPathExtension
        let ext = (uploaded as NSString).pathExtension
        guard !base.isEmpty else { return uploaded }
        return ext.isEmpty ? original : "\(base).\(ext)"
    }
}

/// PhotoKit calls the data handler serially on its own queue.
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failure: (any Error)?
    private var _requestID: PHAssetResourceDataRequestID?

    var failure: (any Error)? { lock.withLock { _failure } }
    var failed: Bool { failure != nil }
    var requestID: PHAssetResourceDataRequestID? {
        get { lock.withLock { _requestID } }
        set { lock.withLock { _requestID = newValue } }
    }

    func fail(_ error: any Error) {
        lock.withLock { if _failure == nil { _failure = error } }
        if let id = requestID { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}
