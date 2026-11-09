import Foundation
import GRDB

/// One file in the backup queue.
public struct UploadTaskRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "uploadTask"

    public enum Part: String, Codable, Sendable { case single, motion, still }
    public enum State: String, Codable, Sendable { case pending, uploading, waiting, done, failed }

    public var id: Int64?
    public var localId: String
    public var part: Part
    public var assetModifiedAt: Date?
    public var state: State
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    public var checksum: String?
    public var fileName: String?
    public var bodyFile: String?
    public var bytes: Int?
    public var sessionTaskId: Int?
    public var remoteId: String?
    public var replacesRemoteId: String?
    public var createdAt: Date
    public var finishedAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// What the backup status screen shows.
public struct BackupCounts: Sendable, Equatable {
    /// Photos and videos in the backup's albums.
    public var total = 0
    /// Of those, already in Cloud (by checksum) or uploaded here.
    public var backedUp = 0
    /// Live Photos whose video part is uploaded but whose photo isn't yet (half done).
    public var halfDone = 0
    public var uploading = 0
    public var waiting = 0
    public var failed = 0
    public var lastSuccess: Date?

    public init() {}
    public var remaining: Int { max(total - backedUp, 0) }
    /// 0…1, counting a half-uploaded Live Photo as half, so the bar moves with every file.
    public var fraction: Double {
        total == 0 ? 0 : min(1, (Double(backedUp) + Double(halfDone) / 2) / Double(total))
    }
}

public enum BackupStore {
    /// Queues photos for backup (a Live Photo as motion + still). Rows already finished for
    /// the same version stay done; an edited photo (new modification date) is queued again
    /// and remembers its earlier upload so the two can be stacked.
    public static func enqueue(_ assets: [(localID: String, modifiedAt: Date?, isLivePhoto: Bool)], now: Date = .now, in db: Database) throws -> Int {
        var added = 0
        for asset in assets {
            let parts: [UploadTaskRecord.Part] = asset.isLivePhoto ? [.motion, .still] : [.single]
            for part in parts {
                if var existing = try UploadTaskRecord.filter(Column("localId") == asset.localID && Column("part") == part.rawValue).fetchOne(db) {
                    guard existing.assetModifiedAt != asset.modifiedAt, existing.state == .done || existing.state == .failed else { continue }
                    if existing.state == .done, part != .motion { existing.replacesRemoteId = existing.remoteId }
                    existing.assetModifiedAt = asset.modifiedAt
                    existing.state = .pending
                    existing.attempts = 0
                    existing.nextAttemptAt = nil
                    existing.lastError = nil
                    existing.checksum = nil
                    existing.remoteId = nil
                    existing.finishedAt = nil
                    try existing.update(db)
                    added += 1
                } else {
                    var record = UploadTaskRecord(
                        localId: asset.localID, part: part, assetModifiedAt: asset.modifiedAt, state: .pending, attempts: 0,
                        createdAt: now
                    )
                    try record.insert(db)
                    added += 1
                }
            }
        }
        return added
    }

    /// Phone photos in `scope` that Cloud doesn't have (no asset with the same checksum,
    /// trashed ones included, so a photo deleted in Cloud isn't uploaded again) and that
    /// aren't already queued or finished for this version. Unhashed photos are included:
    /// their checksum is computed from the exported file just before uploading.
    /// Photos in the phone's Hidden album are never backed up.
    public static func candidates(ownerID: String, scope: Set<String>?, in db: Database) throws -> [(localID: String, modifiedAt: Date?, isLivePhoto: Bool)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.id, l.modifiedAt, (l.subtypes & 8) != 0 AS isLive
            FROM localAsset l
            WHERE l.mediaType IN (1, 2) AND l.isHidden = 0
              AND (l.checksum IS NULL OR NOT EXISTS (SELECT 1 FROM remoteAsset r WHERE r.ownerId = ? AND r.checksum = l.checksum))
              AND NOT EXISTS (
                SELECT 1 FROM uploadTask u WHERE u.localId = l.id AND u.assetModifiedAt IS l.modifiedAt
                  AND u.state IN ('pending', 'uploading', 'waiting', 'done', 'failed')
              )
            ORDER BY l.localDateTime DESC
            """, arguments: [ownerID])
        return rows.compactMap { row in
            let id: String = row["id"]
            if let scope, !scope.contains(id) { return nil }
            return (id, row["modifiedAt"], row["isLive"])
        }
    }

    /// The next tasks to start: due, newest photos first; within a Live Photo the motion before
    /// its still (the still needs the motion's id), and the still only once the motion finished.
    /// Each Live Photo completes before older ones start, so progress shows photo by photo.
    public static func nextDue(limit: Int, now: Date = .now, in db: Database) throws -> [UploadTaskRecord] {
        try UploadTaskRecord.fetchAll(db, sql: """
            SELECT u.* FROM uploadTask u
            LEFT JOIN localAsset l ON l.id = u.localId
            WHERE (u.state = 'pending' OR (u.state = 'waiting' AND u.nextAttemptAt <= ?))
              AND COALESCE(l.isHidden, 0) = 0
              AND (u.part != 'still' OR EXISTS (
                SELECT 1 FROM uploadTask m WHERE m.localId = u.localId AND m.part = 'motion' AND m.state IN ('done', 'failed')
              ))
            ORDER BY l.localDateTime DESC, CASE u.part WHEN 'motion' THEN 0 ELSE 1 END, u.id
            LIMIT ?
            """, arguments: [now, limit])
    }

    public static func task(id: Int64, in db: Database) throws -> UploadTaskRecord? {
        try UploadTaskRecord.fetchOne(db, key: id)
    }

    public static func motionRemoteId(localID: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT remoteId FROM uploadTask WHERE localId = ? AND part = 'motion' AND state = 'done'", arguments: [localID])
    }

    public static func inFlight(in db: Database) throws -> [UploadTaskRecord] {
        try UploadTaskRecord.filter(Column("state") == UploadTaskRecord.State.uploading.rawValue).fetchAll(db)
    }

    /// Bytes of multipart bodies on disk (the temp budget).
    public static func bytesOnDisk(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM uploadTask WHERE bodyFile IS NOT NULL") ?? 0
    }

    public static func referencedBodyFiles(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT bodyFile FROM uploadTask WHERE bodyFile IS NOT NULL"))
    }

    public static func save(_ task: UploadTaskRecord, in db: Database) throws {
        var task = task
        try task.update(db)
    }

    /// Recent failures with readable messages, newest first.
    public static func problems(limit: Int, in db: Database) throws -> [UploadTaskRecord] {
        try UploadTaskRecord.fetchAll(db, sql: """
            SELECT * FROM uploadTask WHERE state IN ('failed', 'waiting') AND lastError IS NOT NULL
            ORDER BY COALESCE(finishedAt, nextAttemptAt, createdAt) DESC LIMIT ?
            """, arguments: [limit])
    }

    public static func retryFailed(in db: Database) throws {
        try db.execute(sql: "UPDATE uploadTask SET state = 'pending', attempts = 0, nextAttemptAt = NULL, lastError = NULL WHERE state IN ('failed', 'waiting')")
    }

    public static func counts(ownerID: String, scope: Set<String>?, in db: Database) throws -> BackupCounts {
        var counts = BackupCounts()
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.id,
                   (l.checksum IS NOT NULL AND EXISTS (SELECT 1 FROM remoteAsset r WHERE r.ownerId = ? AND r.checksum = l.checksum))
                   OR EXISTS (SELECT 1 FROM uploadTask u WHERE u.localId = l.id AND u.part != 'motion' AND u.state = 'done' AND u.assetModifiedAt IS l.modifiedAt)
                   AS backedUp,
                   EXISTS (SELECT 1 FROM uploadTask u WHERE u.localId = l.id AND u.part = 'motion' AND u.state = 'done') AS motionDone
            FROM localAsset l WHERE l.mediaType IN (1, 2) AND l.isHidden = 0
            """, arguments: [ownerID])
        for row in rows {
            let id: String = row["id"]
            if let scope, !scope.contains(id) { continue }
            counts.total += 1
            if row["backedUp"] as Bool {
                counts.backedUp += 1
            } else if row["motionDone"] as Bool {
                counts.halfDone += 1
            }
        }
        let states = try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM uploadTask GROUP BY state")
        for row in states {
            let n: Int = row["n"]
            switch UploadTaskRecord.State(rawValue: row["state"]) {
            case .uploading: counts.uploading = n
            case .waiting: counts.waiting = n
            case .failed: counts.failed = n
            default: break
            }
        }
        counts.lastSuccess = try Date.fetchOne(db, sql: "SELECT MAX(finishedAt) FROM uploadTask WHERE state = 'done'")
        return counts
    }

    // MARK: Album selection

    public static func albumSelection(in db: Database) throws -> [(id: String, title: String, include: Bool)] {
        try Row.fetchAll(db, sql: "SELECT id, title, mode FROM backupAlbum ORDER BY title").map { ($0["id"], $0["title"], ($0["mode"] as String) == "include") }
    }

    public static func setAlbum(id: String, title: String, mode: String?, in db: Database) throws {
        if let mode {
            try db.execute(sql: "INSERT INTO backupAlbum (id, title, mode) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title, mode = excluded.mode",
                           arguments: [id, title, mode])
        } else {
            try db.execute(sql: "DELETE FROM backupAlbum WHERE id = ?", arguments: [id])
        }
    }
}
