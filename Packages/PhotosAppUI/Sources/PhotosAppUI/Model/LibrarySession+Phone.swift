import CloudCore
import Core
import Foundation
import Library
import Persistence
import Photos
import UIKit

/// The phone's photo library: access, indexing, checksums, and actions on photos that
/// are on the phone (favourite, delete, save from the Cloud).
extension LibrarySession {
    /// Starts (or refreshes) indexing when access is granted. Called at launch and on foreground.
    func startPhoneLibrary() {
        photoAccess = LocalLibrary.authorization
        guard LocalLibrary.canRead else { return }
        Task { [phoneLibrary, weak self] in
            await phoneLibrary.startObserving {
                Task { @MainActor in
                    self?.phoneImages.libraryChanged()
                    self?.scheduleHashing()
                    self?.runBackup()
                }
            }
            await phoneLibrary.refresh()
            self?.scheduleHashing()
            self?.runBackup()
        }
    }

    /// Asks for Photos access (the system prompt), then indexes.
    public func requestPhotoAccess() async {
        photoAccess = await LocalLibrary.requestAuthorization()
        startPhoneLibrary()
    }

    /// Hashes phone photos that couldn't be matched by iCloud identity, a few hundred at a
    /// time, in the foreground only and at low priority (photos already on the phone only).
    func scheduleHashing() {
        guard hashTask == nil, isActive, LocalLibrary.canRead else { return }
        hashTask = Task(priority: .utility) { [phoneLibrary, weak self] in
            defer { self?.hashTask = nil }
            // Let launch, the first sync and scrolling settle first.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                let report = await phoneLibrary.hashPending(limit: 100)
                if report.hashed > 0 { Log.library.info("Hashed \(report.hashed) photos (\(report.inCloudOnly) only in iCloud, \(report.failed) failed)") }
                if report.hashed + report.inCloudOnly + report.failed == 0 { break }
            }
        }
    }

    // MARK: Actions on phone photos

    /// Splits item ids into server ids and phone-only local identifiers.
    static func split(_ ids: [String]) -> (remote: [String], phone: [String]) {
        var remote: [String] = [], phone: [String] = []
        for id in ids {
            if id.hasPrefix("local:") { phone.append(String(id.dropFirst(6))) } else { remote.append(id) }
        }
        return (remote, phone)
    }

    func setPhoneFavorite(_ isFavorite: Bool, localIDs: [String]) async throws {
        try await PhoneLibraryChanges.setFavorite(isFavorite, localIDs: localIDs)
        try await database.writer.write { db in try LocalStore.setFavorite(isFavorite, ids: localIDs, in: db) }
    }

    /// Hides (or unhides) the phone's copies, so it's hidden on every device.
    func setPhoneHidden(_ isHidden: Bool, localIDs: [String]) async throws {
        guard !localIDs.isEmpty else { return }
        try await PhoneLibraryChanges.setHidden(isHidden, localIDs: localIDs)
        try await database.writer.write { db in try LocalStore.setHidden(isHidden, ids: localIDs, in: db) }
    }

    /// The phone's copies of these items: phone-only ones and the copies of Cloud ones.
    func phoneIDs(for ids: [String]) async -> (remote: [String], phone: [String]) {
        let (remote, phoneOnly) = Self.split(ids)
        let copies = (try? await database.reader.read { db in try LocalStore.phoneCopies(ofRemote: remote, in: db) }) ?? []
        return (remote, Array(Set(phoneOnly + copies)))
    }

    /// Deletes from the phone's library. iOS asks for confirmation itself; the items go to
    /// the phone's Recently Deleted (and, with iCloud sync on, from the user's other devices).
    func deleteFromPhone(localIDs: [String]) async throws {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil).count
        ActionLog.write("delete on phone: \(localIDs.count) asked, \(found) in the phone's library")
        guard found > 0 else {
            // Already gone from the phone (deleted in another app): just drop them from the index.
            try await database.writer.write { db in try LocalStore.delete(ids: localIDs, in: db) }
            return
        }
        do {
            try await PhoneLibraryChanges.delete(localIDs: localIDs)
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            ActionLog.write("delete on phone: declined in iOS's prompt")
            throw CancellationError()
        } catch {
            ActionLog.write("delete on phone failed: \(error)")
            throw error
        }
        let left = PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil).count
        ActionLog.write("delete on phone: done, \(left) still in the phone's library")
        try await database.writer.write { db in try LocalStore.delete(ids: localIDs, in: db) }
    }

    /// The phone copy of a server photo, if the phone has one (same checksum).
    func phoneCopy(of item: TimelineItem) -> String? { item.localID }

    /// Saves a Cloud photo to the phone's library from its original file (metadata kept);
    /// a Live Photo is saved with its motion part.
    public func saveToPhone(_ item: TimelineItem) async throws {
        guard let remoteID = item.remoteID, let details = detailsNow(for: remoteID) else {
            throw CloudError(kind: .decoding, message: "This item isn't in your Cloud library.")
        }
        if LocalLibrary.authorization == .notDetermined { _ = await LocalLibrary.requestAuthorization() }
        let still = try await originals.file(assetID: remoteID, fileName: details.asset.originalFileName)
        var motion: URL?
        if let motionID = details.asset.livePhotoVideoId, let motionDetails = detailsNow(for: motionID) {
            motion = try await originals.file(assetID: motionID, fileName: motionDetails.asset.originalFileName)
        }
        try await PhoneLibraryChanges.save(still: still, motion: motion, fileName: details.asset.originalFileName,
                                           isVideo: item.isVideo, isFavorite: item.isFavorite)
        Log.library.info("Saved \(remoteID, privacy: .public) to the phone")
        // The new phone copy is hashed and paired with the server copy shortly.
        Task { [phoneLibrary] in await phoneLibrary.refresh() }
        scheduleHashing()
    }

    /// Details for a phone-only item, in the same shape as a server asset's, so the info
    /// panel and viewer work unchanged.
    func phoneDetails(localID: String) -> AssetDetails? {
        guard let record = try? database.reader.read({ db in try LocalStore.record(id: localID, in: db) }) else { return nil }
        let file = phoneImages.fileInfo(localID: localID)
        let asset = RemoteAssetRecord(
            id: TimelineItem.localItemID(localID), ownerId: account.userID, checksum: record.checksum ?? "",
            type: record.isVideo ? .video : .image, originalFileName: file?.name ?? "Photo",
            fileCreatedAt: record.createdAt, fileModifiedAt: record.modifiedAt, localDateTime: record.localDateTime,
            uploadedAt: nil, deletedAt: nil, width: record.width, height: record.height, durationMs: record.durationMs,
            isFavorite: record.isFavorite, isEdited: record.adjustmentTime != nil, visibility: .timeline,
            livePhotoVideoId: nil, stackId: nil, libraryId: nil, thumbhash: nil
        )
        var exif = RemoteExifRecord(assetId: asset.id)
        exif.latitude = record.latitude
        exif.longitude = record.longitude
        exif.fileSizeInByte = file?.bytes
        exif.exifImageWidth = record.width
        exif.exifImageHeight = record.height
        exif.timeZone = TimeZone.current.identifier
        return AssetDetails(asset: asset, exif: exif)
    }

    /// Files for sharing: the phone's copy when there is one (instant, offline), else the
    /// server's original (downloaded once, then cached).
    var shareFileSource: ShareItems.FileSource {
        let originals = originals
        return { entry, progress in
            if let localID = entry.localID {
                let url = try await PhoneImages.exportFile(localID: localID)
                progress(1)
                return url
            }
            return try await originals.file(assetID: entry.assetID, fileName: entry.fileName, progress: progress)
        }
    }

    public func phoneCounts() async -> LocalCounts {
        (try? await database.reader.read { db in try LocalStore.counts(in: db) }) ?? LocalCounts()
    }
}

/// Changes to the phone's library. PhotoKit runs change blocks on its own queue; a block
/// written inside main-actor code is main-actor isolated in Swift 6, and the runtime stops the
/// app when it runs there (this crashed Delete). So the blocks are built here, off any actor.
enum PhoneLibraryChanges {
    static func delete(localIDs: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil))
        }
    }

    static func setHidden(_ isHidden: Bool, localIDs: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: hiddenIncluded).enumerateObjects { asset, _, _ in
                PHAssetChangeRequest(for: asset).isHidden = isHidden
            }
        }
    }

    private static var hiddenIncluded: PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        return options
    }

    static func setFavorite(_ isFavorite: Bool, localIDs: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil).enumerateObjects { asset, _, _ in
                PHAssetChangeRequest(for: asset).isFavorite = isFavorite
            }
        }
    }

    /// A Cloud photo saved to the phone from its original file; a Live Photo with its motion part.
    static func save(still: URL, motion: URL?, fileName: String, isVideo: Bool, isFavorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = fileName
            request.addResource(with: isVideo ? .video : .photo, fileURL: still, options: options)
            if let motion {
                request.addResource(with: .pairedVideo, fileURL: motion, options: nil)
            }
            request.isFavorite = isFavorite
        }
    }
}
