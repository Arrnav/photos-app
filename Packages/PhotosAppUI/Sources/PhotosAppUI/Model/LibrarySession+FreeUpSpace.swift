import CloudCore
import Core
import Foundation
import Library
import Persistence
import Photos

/// Free Up Space: removes photos and videos from the phone that are safely in the Cloud.
/// The phone's index proposes them; right before anything is deleted the server is asked
/// again about every file (it must be in this account and not in its trash), and the phone
/// copy must still be the exact file that was checked.
struct FreeUpReview: Sendable {
    var items: [FreeUpCandidate]
    /// Left on the phone because the server didn't confirm them, or they changed since they were checked.
    var notConfirmed: Int
    /// Left on the phone because they're in a kept album.
    var inKeptAlbums: Int
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

extension LibrarySession {
    func reviewFreeUpSpace(options: FreeUpOptions, keepAlbumIDs: [String]) async throws -> FreeUpReview {
        let connection = try connected()
        let ownerID = account.userID
        var candidates = try await database.reader.read { db in try FreeUpSpace.candidates(ownerID: ownerID, options: options, in: db) }
        let kept = await FreeUpPhone.assetIDs(inAlbums: keepAlbumIDs)
        let before = candidates.count
        candidates.removeAll { kept.contains($0.id) }
        let inKeptAlbums = before - candidates.count

        // The phone's copy must still be the file that was hashed (not edited since).
        let current = await FreeUpPhone.modificationDates(candidates.map(\.id))
        let unchanged = candidates.filter { candidate in
            guard let date = current[candidate.id] else { return false }
            guard let checked = candidate.checksumModifiedAt, let date else { return candidate.checksumModifiedAt == nil && date == nil }
            return abs(date.timeIntervalSince(checked)) < 1
        }

        // Ask the server about every file, a Live Photo's motion part too.
        var queries = unchanged.map { (itemID: $0.id, checksum: $0.checksum) }
        queries += unchanged.compactMap { candidate in candidate.motionChecksum.map { (itemID: "motion:" + candidate.id, checksum: $0) } }
        let answers = queries.isEmpty ? [] : try await connection.existingAssets(queries)
        let confirmed = Set(answers.filter { $0.exists && !$0.isTrashed }.map(\.itemID))
        let safe = unchanged.filter { confirmed.contains($0.id) && ($0.motionChecksum == nil || confirmed.contains("motion:" + $0.id)) }

        ActionLog.write("free up space review: \(before) proposed, \(inKeptAlbums) in kept albums, \(candidates.count - unchanged.count) changed, \(unchanged.count - safe.count) not confirmed, \(safe.count) safe")
        return FreeUpReview(items: safe, notConfirmed: candidates.count - safe.count, inKeptAlbums: inKeptAlbums)
    }

    /// Deletes the reviewed items from the phone (iOS asks to confirm). Returns how many went.
    func freeUpSpace(_ review: FreeUpReview) async throws -> Int {
        let ids = review.items.map(\.id)
        guard !ids.isEmpty else { return 0 }
        ActionLog.write("free up space: deleting \(ids.count) items from the phone")
        // Asks in iOS's own prompt; declining throws CancellationError and nothing is deleted.
        try await deleteFromPhone(localIDs: ids)
        return ids.count
    }

    /// The phone's albums, for Keep Albums.
    func phoneAlbumsForKeeping() async -> [PhoneAlbum] {
        await Task.detached(priority: .userInitiated) { LocalLibrary.albums().filter { !$0.isSystem } }.value
    }
}

/// PhotoKit reads for Free Up Space, kept off the main actor.
enum FreeUpPhone {
    static func assetIDs(inAlbums albumIDs: [String]) async -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var ids = Set<String>()
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil).enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            }
            return ids
        }.value
    }

    /// Current modification dates; an id missing from the result is no longer on the phone.
    static func modificationDates(_ localIDs: [String]) async -> [String: Date?] {
        guard !localIDs.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var dates: [String: Date?] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil).enumerateObjects { asset, _, _ in
                dates[asset.localIdentifier] = asset.modificationDate
            }
            return dates
        }.value
    }

    /// Messaging apps' albums are kept unless chosen otherwise.
    static let messagingAlbumNames = ["whatsapp", "telegram", "signal", "messenger", "instagram", "snapchat", "wechat", "line", "viber", "discord", "threema"]

    static func isMessagingAlbum(_ title: String) -> Bool {
        let lower = title.lowercased()
        return messagingAlbumNames.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }
}
