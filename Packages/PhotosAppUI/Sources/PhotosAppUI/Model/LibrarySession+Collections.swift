import Core
import Foundation
import GRDB
import CloudCore
import Persistence
import UIKit

/// What Collections and Search read: other scopes of the synced library, server
/// collections (albums, memories, trash search) and the profile picture.
extension LibrarySession {
    func observe(_ scope: TimelineScope) -> AsyncValueObservation<[TimelineItem]> {
        TimelineQuery.observeRemote(ownerID: account.userID, scope: scope, in: database)
    }

    // MARK: Recently Deleted

    func trashDates() async -> [String: Date] {
        let ownerID = account.userID
        return (try? await database.reader.read { db in try TimelineQuery.trashDates(ownerID: ownerID, in: db) }) ?? [:]
    }

    /// Days the server keeps deleted items (remembered, 30 until known).
    var trashRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "server.trashDays")
        return days > 0 ? days : 30
    }

    func refreshTrashRetentionDays() async {
        guard let days = try? await connection?.trashRetentionDays(), days > 0 else { return }
        UserDefaults.standard.set(days, forKey: "server.trashDays")
    }

    // MARK: People and smart search (the server's machine learning)

    func people() async throws -> [CloudPerson] {
        try await connected().people()
    }

    func people(inAsset assetID: String) async throws -> [CloudPerson] {
        try await connected().people(inAsset: assetID)
    }

    func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson {
        try await connected().updatePerson(id: id, name: name, birthDate: birthDate)
    }

    /// A person's photos, oldest first like the Library grid.
    func personItems(_ personID: String) async throws -> [TimelineItem] {
        var query = CloudSearchQuery()
        query.personIDs = [personID]
        return try await connected().search(query, limit: 5000).map(TimelineItem.init).reversed()
    }

    /// Photos matching a description, best matches first.
    func smartSearch(_ text: String) async throws -> [TimelineItem] {
        try await connected().smartSearch(text, limit: 300).map(TimelineItem.init)
    }

    /// A person's face picture, cached on disk for a day (it changes when the face is changed on the server).
    func personFace(_ personID: String) async -> UIImage? {
        let folder = paths.mediaCache.appending(path: "people", directoryHint: .isDirectory)
        let file = folder.appending(path: personID + ".jpg")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        if age < 86_400, let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        guard let request = connection?.personThumbnailRequest(personID: personID) else {
            return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        }
    }

    func memories() async throws -> [CloudMemory] {
        try await connected().memories()
    }

    /// An album's photos, oldest first like the Library grid.
    func albumItems(_ albumID: String) async throws -> [TimelineItem] {
        var query = CloudSearchQuery()
        query.albumID = albumID
        return try await connected().search(query, limit: 5000).map(TimelineItem.init).reversed()
    }

    /// Recently Deleted › Delete. The server only marks them and removes them in a job a
    /// little later (sync meanwhile sends them as trashed again), so they're removed here
    /// at once and kept out until the server has finished.
    func deletePermanently(assetIDs: [String]) async throws {
        try requireServerItems(assetIDs)
        ActionLog.write("delete for good: \(assetIDs.count) items")
        try await connected().deletePermanently(assetIDs: assetIDs)
        try await database.writer.write { db in try RemoteStore.markPurged(ids: assetIDs, in: db) }
        syncNow()
    }

    /// Local search over places, captions, file names and cameras; newest first.
    func search(_ text: String) async -> [TimelineItem] {
        let ownerID = account.userID
        let ids = (try? await database.reader.read { db in try LibrarySearch.assetIDs(ownerID: ownerID, text: text, in: db) }) ?? []
        let byID = Dictionary(timeline.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func topPlaces(limit: Int) async -> [String] {
        let ownerID = account.userID
        return (try? await database.reader.read { db in try LibrarySearch.topPlaces(ownerID: ownerID, limit: limit, in: db) }) ?? []
    }

    /// Uses `image` as the account picture: shown at once (cached on the phone) and set as the
    /// Cloud profile picture so every device shows it.
    func setProfileImage(_ image: UIImage) async throws {
        let square = Self.squareCrop(image, side: 640)
        guard let jpeg = square.jpegData(compressionQuality: 0.88) else { return }
        try jpeg.write(to: paths.mediaCache.appending(path: "profile-image"), options: .atomic)
        profileImageVersion += 1
        try await connected().setProfileImage(jpeg: jpeg)
    }

    private static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = image.size
        let edge = min(size.width, size.height)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        return renderer.image { _ in
            let scale = side / edge
            image.draw(in: CGRect(x: -(size.width - edge) / 2 * scale, y: -(size.height - edge) / 2 * scale, width: size.width * scale, height: size.height * scale))
        }
    }

    /// The signed-in user's Immich profile picture, cached on disk so it shows offline.
    func profileImage(refresh: Bool = false) async -> UIImage? {
        let file = paths.mediaCache.appending(path: "profile-image")
        if !refresh, let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            return image
        }
        guard let connection else { return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) }
        let request = connection.profileImageRequest(userID: account.userID)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            Log.networking.info("Profile image failed: \(error.localizedDescription, privacy: .public)")
            return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        }
    }
}

extension TimelineItem {
    init(_ asset: CloudAsset) {
        let ratio: Double = if let width = asset.width, let height = asset.height, width > 0, height > 0 {
            Double(width) / Double(height)
        } else {
            1
        }
        self.init(
            id: asset.id, date: asset.localDateTime, isVideo: asset.isVideo, durationMs: asset.durationMs,
            isFavorite: asset.isFavorite, isLivePhoto: asset.isLivePhoto, thumbhash: asset.thumbhash,
            aspectRatio: ratio, uploadedAt: asset.uploadedAt, isEdited: asset.isEdited, ownerID: asset.ownerID
        )
    }
}

extension LibrarySession {
    func locations(limit: Int = 5000) async -> [AssetLocation] {
        let ownerID = account.userID
        return (try? await database.reader.read { db in try LibrarySearch.locations(ownerID: ownerID, limit: limit, in: db) }) ?? []
    }
}
