import Foundation
import GRDB

/// One asset in the phone's photo library (PhotoKit), as indexed.
public struct LocalAssetRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "localAsset"

    public var id: String
    public var cloudId: String?
    public var mediaType: Int
    public var subtypes: Int
    public var createdAt: Date?
    public var localDateTime: Date?
    public var modifiedAt: Date?
    public var adjustmentTime: Date?
    public var isFavorite: Bool
    public var width: Int
    public var height: Int
    public var durationMs: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var checksum: String?
    public var checksumSource: String?
    public var checksumModifiedAt: Date?
    public var hashError: String?
    /// In the phone's Hidden album: never shown in the Library or backed up.
    public var isHidden = false

    /// `PHAssetMediaType` values.
    public static let image = 1
    public static let video = 2
    /// `PHAssetMediaSubtype` bits used here.
    public static let screenshotSubtype = 1 << 2
    public static let livePhotoSubtype = 1 << 3

    public init(
        id: String, cloudId: String? = nil, mediaType: Int, subtypes: Int = 0, createdAt: Date?, localDateTime: Date?,
        modifiedAt: Date?, adjustmentTime: Date? = nil, isFavorite: Bool = false, width: Int, height: Int,
        durationMs: Int? = nil, latitude: Double? = nil, longitude: Double? = nil, isHidden: Bool = false
    ) {
        self.isHidden = isHidden
        self.id = id
        self.cloudId = cloudId
        self.mediaType = mediaType
        self.subtypes = subtypes
        self.createdAt = createdAt
        self.localDateTime = localDateTime
        self.modifiedAt = modifiedAt
        self.adjustmentTime = adjustmentTime
        self.isFavorite = isFavorite
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isVideo: Bool { mediaType == Self.video }
    public var isLivePhoto: Bool { subtypes & Self.livePhotoSubtype != 0 }
}

public enum ChecksumSource: String, Sendable {
    /// Computed on this phone from the file a backup would upload.
    case hashed
    /// Taken from the server: the official app (or this one) uploaded it with this iCloud identity.
    case cloudId
}

/// Writes and queries for the local library index.
public enum LocalStore {
    /// Inserts or updates assets from PhotoKit. A changed modification date clears the
    /// checksum (an edit changes the file a backup would upload).
    public static func upsert(_ records: [LocalAssetRecord], in db: Database) throws {
        let update = try db.makeStatement(sql: """
            UPDATE localAsset SET cloudId = COALESCE(?, cloudId), mediaType = ?, subtypes = ?, createdAt = ?, localDateTime = ?,
              modifiedAt = ?, adjustmentTime = ?, isFavorite = ?, width = ?, height = ?, durationMs = ?, latitude = ?, longitude = ?, isHidden = ?,
              checksum = CASE WHEN checksumModifiedAt IS ? THEN checksum ELSE NULL END,
              checksumSource = CASE WHEN checksumModifiedAt IS ? THEN checksumSource ELSE NULL END,
              hashError = CASE WHEN checksumModifiedAt IS ? THEN hashError ELSE NULL END
            WHERE id = ?
            """)
        for record in records {
            try update.execute(arguments: [
                record.cloudId, record.mediaType, record.subtypes, record.createdAt, record.localDateTime,
                record.modifiedAt, record.adjustmentTime, record.isFavorite, record.width, record.height, record.durationMs,
                record.latitude, record.longitude, record.isHidden, record.modifiedAt, record.modifiedAt, record.modifiedAt, record.id,
            ])
            if db.changesCount == 0 {
                try record.insert(db)
            }
        }
    }

    public static func delete(ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }
        _ = try LocalAssetRecord.deleteAll(db, keys: ids)
    }

    /// Removes everything not in `keep` (after a full scan of the library).
    public static func deleteAll(except keep: Set<String>, in db: Database) throws -> Int {
        let existing = try String.fetchAll(db, sql: "SELECT id FROM localAsset")
        let gone = existing.filter { !keep.contains($0) }
        try delete(ids: gone, in: db)
        return gone.count
    }

    public static func setCloudIds(_ mapping: [String: String], in db: Database) throws {
        let statement = try db.makeStatement(sql: "UPDATE localAsset SET cloudId = ? WHERE id = ?")
        for (id, cloudId) in mapping { try statement.execute(arguments: [cloudId, id]) }
    }

    /// Records a checksum, unless the asset changed since `modifiedAt` (then it is hashed again later).
    public static func setChecksum(_ checksum: String, source: ChecksumSource, id: String, modifiedAt: Date?, in db: Database) throws {
        try db.execute(sql: """
            UPDATE localAsset SET checksum = ?, checksumSource = ?, checksumModifiedAt = ?, hashError = NULL
            WHERE id = ? AND modifiedAt IS ?
            """, arguments: [checksum, source.rawValue, modifiedAt, id, modifiedAt])
    }

    public static func setHashError(_ message: String, id: String, in db: Database) throws {
        try db.execute(sql: "UPDATE localAsset SET hashError = ? WHERE id = ?", arguments: [message, id])
    }

    public static func setFavorite(_ isFavorite: Bool, ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }
        try db.execute(sql: "UPDATE localAsset SET isFavorite = ? WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                       arguments: StatementArguments([isFavorite] as [any DatabaseValueConvertible]) + StatementArguments(ids))
    }

    public static func setHidden(_ isHidden: Bool, ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }
        try db.execute(sql: "UPDATE localAsset SET isHidden = ? WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                       arguments: StatementArguments([isHidden] as [any DatabaseValueConvertible]) + StatementArguments(ids))
    }

    /// Local assets the server's upload records identify (same iCloud identity), with the
    /// server's checksum and the recorded creation/edit times to compare.
    public static func cloudIdCandidates(ownerID: String, in db: Database) throws -> [CloudIdCandidate] {
        try Row.fetchAll(db, sql: """
            SELECT l.id, l.modifiedAt, l.createdAt, l.adjustmentTime, r.checksum, c.createdAt AS remoteCreatedAt, c.adjustmentTime AS remoteAdjustmentTime
            FROM localAsset l
            JOIN remoteAssetCloudId c ON c.cloudId = l.cloudId
            JOIN remoteAsset r ON r.id = c.assetId
            WHERE l.checksum IS NULL AND l.cloudId IS NOT NULL AND r.ownerId = ?
            """, arguments: [ownerID]).map {
            CloudIdCandidate(
                localID: $0["id"], modifiedAt: $0["modifiedAt"], createdAt: $0["createdAt"], adjustmentTime: $0["adjustmentTime"],
                remoteChecksum: $0["checksum"], remoteCreatedAt: $0["remoteCreatedAt"], remoteAdjustmentTime: $0["remoteAdjustmentTime"]
            )
        }
    }

    /// Assets still without a checksum, newest first (recent photos matter most), skipping ones that failed.
    public static func needingChecksum(limit: Int, in db: Database) throws -> [LocalAssetRecord] {
        try LocalAssetRecord.fetchAll(db, sql: """
            SELECT * FROM localAsset WHERE checksum IS NULL AND hashError IS NULL
            ORDER BY localDateTime DESC LIMIT ?
            """, arguments: [limit])
    }

    /// The phone's copies (same checksum) of these server assets, for Delete: deleting removes a photo everywhere, not only from the server.
    public static func phoneCopies(ofRemote remoteIDs: [String], in db: Database) throws -> [String] {
        guard !remoteIDs.isEmpty else { return [] }
        return try String.fetchAll(db, sql: """
            SELECT DISTINCT l.id FROM localAsset l JOIN remoteAsset r ON r.checksum = l.checksum
            WHERE r.id IN (\(databaseQuestionMarks(count: remoteIDs.count)))
            """, arguments: StatementArguments(remoteIDs))
    }

    public static func record(id: String, in db: Database) throws -> LocalAssetRecord? {
        try LocalAssetRecord.fetchOne(db, key: id)
    }

    public static func counts(in db: Database) throws -> LocalCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS total, COUNT(checksum) AS hashed,
                   SUM(CASE WHEN checksumSource = 'cloudId' THEN 1 ELSE 0 END) AS fromCloudId,
                   SUM(CASE WHEN hashError IS NOT NULL THEN 1 ELSE 0 END) AS failed
            FROM localAsset
            """)
        return LocalCounts(total: row?["total"] ?? 0, withChecksum: row?["hashed"] ?? 0, fromCloudId: row?["fromCloudId"] ?? 0, failed: row?["failed"] ?? 0)
    }
}

public struct CloudIdCandidate: Sendable, Equatable {
    public let localID: String
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let adjustmentTime: Date?
    public let remoteChecksum: String
    public let remoteCreatedAt: String?
    public let remoteAdjustmentTime: String?

    public init(localID: String, modifiedAt: Date?, createdAt: Date?, adjustmentTime: Date?, remoteChecksum: String, remoteCreatedAt: String?, remoteAdjustmentTime: String?) {
        self.localID = localID
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.adjustmentTime = adjustmentTime
        self.remoteChecksum = remoteChecksum
        self.remoteCreatedAt = remoteCreatedAt
        self.remoteAdjustmentTime = remoteAdjustmentTime
    }
}

public struct LocalCounts: Sendable, Equatable {
    public var total = 0
    public var withChecksum = 0
    public var fromCloudId = 0
    public var failed = 0

    public init(total: Int = 0, withChecksum: Int = 0, fromCloudId: Int = 0, failed: Int = 0) {
        self.total = total
        self.withChecksum = withChecksum
        self.fromCloudId = fromCloudId
        self.failed = failed
    }
}
