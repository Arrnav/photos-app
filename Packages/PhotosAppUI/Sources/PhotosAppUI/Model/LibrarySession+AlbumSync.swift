import Backup
import CloudCore
import Core
import Foundation
import GRDB
import Library
import Persistence
import Photos

/// Sync Albums (like the Immich app): every phone album chosen in Back Up From gets an
/// album of the same name in Cloud, and the photos that are backed up are added to it.
extension LibrarySession {
    private static let albumMapKey = "backup.albumSync.map"

    func syncAlbumsIfEnabled() {
        guard BackupSettings.load().syncsAlbums, !albumSyncRunning else { return }
        albumSyncRunning = true
        Task { [weak self] in
            defer { self?.albumSyncRunning = false }
            await self?.syncAlbums()
        }
    }

    private func syncAlbums() async {
        guard LocalLibrary.canRead, let connection = try? connected() else { return }
        let selection = (try? await database.reader.read { db in try BackupStore.albumSelection(in: db) }) ?? []
        let albums = selection.filter(\.include)
        guard !albums.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: Self.albumMapKey) as? [String: String] ?? [:]
        let existing = (try? await connection.albums(shared: false)) ?? []
        let ownerID = account.userID
        for album in albums {
            // Phone album members that are in Cloud (paired by checksum, or uploaded here).
            let localIDs = Array(LocalLibrary.assetIDs(including: [album.id], excluding: []) ?? [])
            guard !localIDs.isEmpty else { continue }
            let remoteIDs: [String] = (try? await database.reader.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT r.id FROM localAsset l JOIN remoteAsset r ON r.checksum = l.checksum AND r.ownerId = ?
                    WHERE l.isHidden = 0 AND r.visibility != 'locked' AND l.id IN (\(databaseQuestionMarks(count: localIDs.count)))
                    """, arguments: StatementArguments([ownerID]) + StatementArguments(localIDs))
            }) ?? []
            guard !remoteIDs.isEmpty else { continue }
            do {
                if let remoteAlbum = map[album.id].flatMap({ id in existing.first { $0.id == id } }) ?? existing.first(where: { $0.name == album.title }) {
                    map[album.id] = remoteAlbum.id
                    try await connection.addAssets(remoteIDs, toAlbum: remoteAlbum.id)
                } else {
                    let created = try await connection.createAlbum(name: album.title, assetIDs: remoteIDs, sharedWith: [])
                    map[album.id] = created.id
                }
                Log.backup.info("Synced album \(album.title, privacy: .public): \(remoteIDs.count) items")
            } catch {
                Log.backup.notice("Album sync for \(album.title, privacy: .public) failed: \(CloudError.message(for: error), privacy: .public)")
            }
        }
        UserDefaults.standard.set(map, forKey: Self.albumMapKey)
    }
}
