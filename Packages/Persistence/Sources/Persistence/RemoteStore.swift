import Foundation
import GRDB

/// Write operations for server-synced data. All functions take a `Database` so
/// the sync applier can group a batch and its ack bookkeeping in one transaction.
public enum RemoteStore {
    public static func upsert(_ assets: [RemoteAssetRecord], in db: Database) throws {
        let purged = try purgedIDs(among: assets.map(\.id), in: db)
        for asset in assets {
            // Deleted for good here, but the server's empty-trash job hasn't removed it yet:
            // sync still sends it as trashed (with a new date). Keep it out until it's gone.
            if purged.contains(asset.id), asset.deletedAt != nil { continue }
            try asset.upsert(db)
        }
    }

    public static func deleteAssets(ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }
        _ = try RemoteAssetRecord.deleteAll(db, keys: ids)
        _ = try RemoteExifRecord.deleteAll(db, keys: ids)
        _ = try RemoteAssetCloudIdRecord.deleteAll(db, keys: ids)
        try db.execute(sql: "DELETE FROM purgedAsset WHERE id IN (\(databaseQuestionMarks(count: ids.count)))", arguments: StatementArguments(ids))
    }

    /// Recently Deleted › Delete: the rows go at once, and stay gone while the server
    /// finishes deleting (it sends them as trashed until its job has run).
    public static func markPurged(ids: [String], at date: Date = .now, in db: Database) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try db.execute(sql: "INSERT OR REPLACE INTO purgedAsset (id, purgedAt) VALUES (?, ?)", arguments: [id, date])
        }
        _ = try RemoteAssetRecord.deleteAll(db, keys: ids)
        _ = try RemoteExifRecord.deleteAll(db, keys: ids)
        _ = try RemoteAssetCloudIdRecord.deleteAll(db, keys: ids)
        // The server is done long before a week; older marks only take space.
        try db.execute(sql: "DELETE FROM purgedAsset WHERE purgedAt < ?", arguments: [date.addingTimeInterval(-7 * 86_400)])
    }

    /// Immich's fallback for a file with no capture date in its metadata (WhatsApp images,
    /// many downloads): its "local" time is the file's creation instant in UTC, with no time
    /// zone, so the wall-clock time was off by the phone's offset (5:57 pm showed as 12:27 pm
    /// in India). The uploading phone recorded the true instant (`mobile-app` createdAt); when
    /// the local time equals it, it's that instant, shown in this phone's time zone.
    /// Idempotent: once shifted, the local time no longer equals the instant.
    @discardableResult
    public static func fixZonelessLocalTimes(zone: TimeZone = .current, in db: Database) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.localDateTime FROM remoteAsset a
            JOIN remoteAssetCloudId c ON c.assetId = a.id
            LEFT JOIN remoteExif e ON e.assetId = a.id
            WHERE (e.timeZone IS NULL OR e.timeZone = '') AND a.localDateTime IS NOT NULL AND c.createdAt IS NOT NULL
              AND abs(julianday(a.localDateTime) - julianday(c.createdAt)) * 86400 < 90
            """)
        var fixed = 0
        for row in rows {
            guard let date: Date = row[1] else { continue }
            let offset = zone.secondsFromGMT(for: date)
            guard offset != 0 else { continue }
            try db.execute(sql: "UPDATE remoteAsset SET localDateTime = ? WHERE id = ?",
                           arguments: [date.addingTimeInterval(Double(offset)), row[0] as String])
            fixed += 1
        }
        return fixed
    }

    private static func purgedIDs(among ids: [String], in db: Database) throws -> Set<String> {
        guard !ids.isEmpty, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM purgedAsset") ?? 0 > 0 else { return [] }
        return Set(try String.fetchAll(db, sql: "SELECT id FROM purgedAsset WHERE id IN (\(databaseQuestionMarks(count: ids.count)))", arguments: StatementArguments(ids)))
    }

    public static func upsert(_ exifs: [RemoteExifRecord], in db: Database) throws {
        for exif in exifs { try exif.upsert(db) }
    }

    public static func upsert(_ cloudIds: [RemoteAssetCloudIdRecord], in db: Database) throws {
        for cloudId in cloudIds { try cloudId.upsert(db) }
    }

    public static func deleteCloudIds(assetIDs: [String], in db: Database) throws {
        guard !assetIDs.isEmpty else { return }
        _ = try RemoteAssetCloudIdRecord.deleteAll(db, keys: assetIDs)
    }

    public static func upsert(_ users: [UserRecord], in db: Database) throws {
        for user in users { try user.upsert(db) }
    }

    public static func deleteUsers(ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }
        _ = try UserRecord.deleteAll(db, keys: ids)
    }

    /// Clears everything that came from the server (on `SyncResetV1` or a new session).
    public static func resetAll(in db: Database) throws {
        _ = try RemoteAssetRecord.deleteAll(db)
        _ = try RemoteExifRecord.deleteAll(db)
        _ = try RemoteAssetCloudIdRecord.deleteAll(db)
        _ = try UserRecord.deleteAll(db)
    }
}

/// Small key/value table for sync bookkeeping.
public enum SyncState {
    public enum Key: String, Sendable {
        /// Identifies the server session the local data was synced with. Sync
        /// checkpoints live per session on the server, so a new session needs a clean slate.
        case sessionFingerprint
        case lastCompletedAt
        /// Summary of events the last sync could not read, e.g. "AssetV2: 3 (reason)". Absent when none.
        case lastSkipped
        /// Bumped when the app needs the server to resend some types (e.g. after a parsing fix).
        case resendRevision
        /// PhotoKit's persistent change token (archived, base64) after the last local index pass.
        case photoLibraryChangeToken
    }

    public static func value(_ key: Key, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key.rawValue])
    }

    public static func set(_ key: Key, _ value: String?, in db: Database) throws {
        if let value {
            try db.execute(
                sql: "INSERT INTO syncState (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key.rawValue, value]
            )
        } else {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [key.rawValue])
        }
    }
}
