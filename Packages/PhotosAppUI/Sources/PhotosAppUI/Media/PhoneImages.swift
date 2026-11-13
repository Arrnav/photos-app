import Backup
import Core
import Library
import Photos
import UIKit

/// Images from the phone's own photo library (PhotoKit). Tiles and viewer pages that
/// have a copy on the phone load from here: instant, offline, and no work for the server.
@MainActor
final class PhoneImages {
    private let manager = PHCachingImageManager()
    private var assets: [String: PHAsset] = [:]

    init() {
        manager.allowsCachingHighQualityImages = false
    }

    func asset(_ localID: String) -> PHAsset? {
        if let cached = assets[localID] { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        if assets.count > 60_000 { assets.removeAll(keepingCapacity: true) }
        assets[localID] = asset
        return asset
    }

    /// Looks up many assets in one fetch: one at a time cost about 3 ms per tile, which
    /// made the first screen of the grid take 200 ms at launch.
    func preload(_ localIDs: [String]) {
        let missing = localIDs.filter { assets[$0] == nil }
        guard !missing.isEmpty else { return }
        PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
            MainActor.assumeIsolated { self.assets[asset.localIdentifier] = asset }
        }
    }

    /// The same for the whole library, fetched off the main thread and added when done.
    func preloadInBackground(_ localIDs: [String]) {
        let missing = localIDs.filter { assets[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [(String, PHAsset)] = []
            found.reserveCapacity(missing.count)
            PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
                found.append((asset.localIdentifier, asset))
            }
            let results = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, asset) in results where self.assets[id] == nil { self.assets[id] = asset }
            }
        }
    }

    /// Forgets cached `PHAsset`s (they go stale after library changes).
    func libraryChanged() {
        assets.removeAll(keepingCapacity: true)
    }

    /// A square-ish tile or a screen-sized page. The handler may run more than once
    /// (a quick degraded image first) and may run synchronously.
    @discardableResult
    func requestImage(
        localID: String, pixelSize: CGSize, fill: Bool, quality: Quality,
        handler: @escaping @MainActor (UIImage, _ isDegraded: Bool) -> Void
    ) -> PHImageRequestID? {
        guard let asset = asset(localID) else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = quality == .fast ? .opportunistic : .highQualityFormat
        options.resizeMode = quality == .fast ? .fast : .exact
        options.version = .current
        return manager.requestImage(for: asset, targetSize: pixelSize, contentMode: fill ? .aspectFill : .aspectFit, options: options) { image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            MainActor.assumeIsolated { handler(image, degraded) }
        }
    }

    enum Quality { case fast, high }

    func cancel(_ requestID: PHImageRequestID?) {
        if let requestID { manager.cancelImageRequest(requestID) }
    }

    /// The full-resolution photo with HDR (gain map) when present, for zooming in.
    func fullImage(localID: String) async throws -> UIImage {
        guard let asset = asset(localID) else { throw ChecksumError.assetGone }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? ChecksumError.photoKit("The photo couldn't be loaded."))
                }
            }
        }
        return try await Self.decodeHDR(data)
    }

    @concurrent
    private static func decodeHDR(_ data: Data) async throws -> UIImage {
        var configuration = UIImageReader.Configuration()
        configuration.prefersHighDynamicRange = true
        configuration.preparesImagesForDisplay = true
        configuration.preferredThumbnailSize = CGSize(width: 6048, height: 6048)
        guard let image = await UIImageReader(configuration: configuration).image(data: data) else {
            throw ChecksumError.photoKit("The photo couldn't be decoded.")
        }
        return image
    }

    /// Writes the asset's file (the one a backup uploads, i.e. the current version) to a
    /// temporary folder, for sharing and copying. The caller deletes the folder.
    func exportFile(localID: String) async throws -> URL {
        try await Self.exportFile(localID: localID, in: nil)
    }

    /// Off the main thread, so a share waiting for the file can't block on it.
    /// `folder`: where to write it (the caller removes it); a new temporary folder if nil.
    nonisolated static func exportFile(localID: String, in folder: URL?) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { throw ChecksumError.assetGone }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = ResourceSelection.uploadResource(among: resources, mediaType: asset.mediaType)
            ?? resources.first(where: { $0.type == .photo || $0.type == .video }) else {
            throw ChecksumError.noUploadResource
        }
        let folder = (folder ?? FileManager.default.temporaryDirectory).appending(path: "phone-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // IMG_1234.HEIC rather than an edited photo's "FullSizeRender.heic", as in backups.
        let url = folder.appending(path: PhotoKitExporter.uploadName(asset: asset, resources: resources, uploaded: resource))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }

    /// File name and size of the asset's main file (for the info panel).
    func fileInfo(localID: String) -> (name: String, bytes: Int?)? {
        guard let asset = asset(localID) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = ResourceSelection.uploadResource(among: resources, mediaType: asset.mediaType) ?? resources.first else { return nil }
        let size = (resource.value(forKey: "fileSize") as? NSNumber)?.intValue
        return (PhotoKitExporter.uploadName(asset: asset, resources: resources, uploaded: resource), size)
    }
}
