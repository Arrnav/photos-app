import Foundation
import GRDB

/// What a grid tile needs. Kept small: the whole timeline is held in memory
/// (about 100 bytes × 25k assets).
public struct TimelineItem: Sendable, Hashable, Identifiable {
    public let id: String
    /// Wall-clock capture time (Immich `localDateTime`, encoded as UTC).
    public let date: Date
    public let isVideo: Bool
    public let durationMs: Int?
    /// Changed in place when the user favourites in the viewer.
    public var isFavorite: Bool
    public let isLivePhoto: Bool
    public let thumbhash: String?
    /// width / height, 1 when unknown.
    public let aspectRatio: Double
    /// When it was uploaded to Immich ("Added" sort order).
    public let uploadedAt: Date?
    public let isEdited: Bool
    /// Has camera EXIF (make): taken with a camera rather than saved or captured from the screen.
    public let hasCamera: Bool
    /// Heuristic (docs/DESIGN.md D8): a PNG without camera EXIF, or a file named like a screenshot.
    public let isScreenshot: Bool
    public let ownerID: String
    /// The phone's copy (PhotoKit local identifier), when this photo is on the phone.
    public let localID: String?
    /// False for photos only on the phone (`id` is then "local:" + `localID`).
    public let isRemote: Bool

    /// The server's id, when the photo is on the server.
    public var remoteID: String? { isRemote ? id : nil }
    public var isLocal: Bool { localID != nil }

    public static func localItemID(_ localID: String) -> String { "local:" + localID }

    public init(
        id: String, date: Date, isVideo: Bool, durationMs: Int?, isFavorite: Bool,
        isLivePhoto: Bool, thumbhash: String?, aspectRatio: Double,
        uploadedAt: Date? = nil, isEdited: Bool = false, hasCamera: Bool = false,
        isScreenshot: Bool = false, ownerID: String = "", localID: String? = nil, isRemote: Bool = true
    ) {
        self.id = id
        self.date = date
        self.isVideo = isVideo
        self.durationMs = durationMs
        self.isFavorite = isFavorite
        self.isLivePhoto = isLivePhoto
        self.thumbhash = thumbhash
        self.aspectRatio = aspectRatio
        self.uploadedAt = uploadedAt
        self.isEdited = isEdited
        self.hasCamera = hasCamera
        self.isScreenshot = isScreenshot
        self.ownerID = ownerID
        self.localID = localID
        self.isRemote = isRemote
    }
}

/// Which of the owner's assets a timeline lists.
public enum TimelineScope: Sendable, Hashable {
    /// Not trashed, with this visibility (`.timeline` Library, `.archive`, `.locked` Hidden).
    case visibility(RemoteVisibility)
    /// Recently Deleted.
    case trash
    /// Recently Deleted including hidden items (needs the Hidden album unlocked to show them).
    case trashIncludingHidden
}

public enum TimelineQuery {
    /// The owner's main timeline: visible (not archived/hidden/locked), not trashed, oldest first
    /// (the grid shows the newest photos at the bottom).
    /// `visibility` `.locked` lists the Hidden album (Immich Locked Folder).
    public static func remote(ownerID: String, visibility: RemoteVisibility = .timeline, in db: Database) throws -> [TimelineItem] {
        try remote(ownerID: ownerID, scope: .visibility(visibility), in: db)
    }

    /// Recently Deleted: trashed (not yet purged) photos, except hidden ones.
    public static func remote(ownerID: String, scope: TimelineScope, in db: Database) throws -> [TimelineItem] {
        let condition: String
        var arguments: StatementArguments = [ownerID]
        switch scope {
        case .visibility(let visibility):
            condition = "a.visibility = ? AND a.deletedAt IS NULL"
            arguments += [visibility.rawValue]
        case .trash:
            condition = "a.deletedAt IS NOT NULL AND a.visibility != ?"
            arguments += [RemoteVisibility.locked.rawValue]
        case .trashIncludingHidden:
            condition = "a.deletedAt IS NOT NULL"
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT a.id, COALESCE(a.localDateTime, a.fileCreatedAt, a.uploadedAt) AS date, a.type, a.durationMs,
                   a.isFavorite, a.livePhotoVideoId IS NOT NULL AS isLive, a.thumbhash, a.width, a.height,
                   a.uploadedAt, a.isEdited, e.make IS NOT NULL AND e.make != '' AS hasCamera,
                   (a.type = 'IMAGE' AND (e.make IS NULL OR e.make = '') AND
                    (lower(a.originalFileName) LIKE '%.png' OR lower(a.originalFileName) LIKE '%screenshot%')) AS isScreenshot,
                   a.ownerId
            FROM remoteAsset a
            LEFT JOIN remoteExif e ON e.assetId = a.id
            WHERE a.ownerId = ? AND \(condition)
            ORDER BY a.localDateTime, a.fileCreatedAt, a.id
            """, arguments: arguments)

        var items: [TimelineItem] = []
        items.reserveCapacity(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remoteAsset WHERE ownerId = ?", arguments: [ownerID]) ?? 0)
        while let row = try rows.next() {
            let width: Int? = row[7]
            let height: Int? = row[8]
            let ratio: Double = if let width, let height, width > 0, height > 0 {
                Double(width) / Double(height)
            } else {
                1
            }
            items.append(TimelineItem(
                id: row[0],
                date: row[1] ?? .distantPast,
                isVideo: row[2] == RemoteAssetType.video.rawValue,
                durationMs: row[3],
                isFavorite: row[4],
                isLivePhoto: row[5],
                thumbhash: row[6],
                aspectRatio: ratio,
                uploadedAt: row[9],
                isEdited: row[10],
                hasCamera: row[11],
                isScreenshot: row[12],
                ownerID: row[13]
            ))
        }
        return items
    }

    /// When each item in Recently Deleted was deleted (for "N days" left).
    public static func trashDates(ownerID: String, in db: Database) throws -> [String: Date] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, deletedAt FROM remoteAsset WHERE ownerId = ? AND deletedAt IS NOT NULL", arguments: [ownerID])
        var dates: [String: Date] = [:]
        for row in rows { if let date: Date = row[1] { dates[row[0]] = date } }
        return dates
    }

    /// The one asset of a stack (`a.stackId`) the Library shows: the version that's on this
    /// iPhone, else the stack's primary, else its newest version.
    private static let stackShown = """
        SELECT COALESCE(
            (SELECT b.id FROM remoteAsset b JOIN localAsset l ON l.checksum = b.checksum AND l.isHidden = 0
             WHERE b.stackId = a.stackId AND b.ownerId = ?1 AND b.visibility = 'timeline' AND b.deletedAt IS NULL
             ORDER BY b.fileModifiedAt DESC LIMIT 1),
            (SELECT s.primaryAssetId FROM stack s JOIN remoteAsset p ON p.id = s.primaryAssetId
             WHERE s.id = a.stackId AND p.visibility = 'timeline' AND p.deletedAt IS NULL),
            (SELECT b.id FROM remoteAsset b
             WHERE b.stackId = a.stackId AND b.ownerId = ?1 AND b.visibility = 'timeline' AND b.deletedAt IS NULL
             ORDER BY b.fileModifiedAt DESC LIMIT 1))
        """

    /// The Library: the owner's server timeline, each item paired with its copy on the phone
    /// (same checksum), plus photos only on the phone, plus the libraries partners share
    /// with the owner when shown in the Library (`inTimeline`; a photo the owner already has
    /// is listed once, as the owner's). A phone photo is left out when the
    /// server has it but it's archived or hidden there, so hiding on the server hides it here.
    public static func merged(ownerID: String, in db: Database) throws -> [TimelineItem] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT a.id, COALESCE(a.localDateTime, a.fileCreatedAt, a.uploadedAt) AS date, a.type = 'VIDEO' AS isVideo, a.durationMs,
                   a.isFavorite, a.livePhotoVideoId IS NOT NULL AS isLive, a.thumbhash, a.width, a.height,
                   a.uploadedAt, a.isEdited, e.make IS NOT NULL AND e.make != '' AS hasCamera,
                   (a.type = 'IMAGE' AND (e.make IS NULL OR e.make = '') AND
                    (lower(a.originalFileName) LIKE '%.png' OR lower(a.originalFileName) LIKE '%screenshot%')) AS isScreenshot,
                   a.ownerId,
                   (SELECT l.id FROM localAsset l WHERE l.checksum = a.checksum AND l.isHidden = 0 LIMIT 1) AS localId,
                   1 AS isRemote
            FROM remoteAsset a
            LEFT JOIN remoteExif e ON e.assetId = a.id
            WHERE a.ownerId = ?1 AND a.visibility = 'timeline' AND a.deletedAt IS NULL
              AND (a.stackId IS NULL OR a.id = (\(stackShown)))
            UNION ALL
            SELECT 'local:' || l.id, COALESCE(l.localDateTime, l.createdAt), l.mediaType = 2, l.durationMs,
                   l.isFavorite, (l.subtypes & 8) != 0, NULL, l.width, l.height,
                   NULL, l.adjustmentTime IS NOT NULL, (l.subtypes & 4) = 0, (l.subtypes & 4) != 0,
                   ?1, l.id, 0
            FROM localAsset l
            WHERE l.mediaType IN (1, 2) AND l.isHidden = 0 AND NOT EXISTS (
                SELECT 1 FROM remoteAsset r WHERE r.ownerId = ?1 AND r.checksum = l.checksum AND r.deletedAt IS NULL
            )
            UNION ALL
            SELECT a.id, COALESCE(a.localDateTime, a.fileCreatedAt, a.uploadedAt), a.type = 'VIDEO', a.durationMs,
                   a.isFavorite, a.livePhotoVideoId IS NOT NULL, a.thumbhash, a.width, a.height,
                   a.uploadedAt, a.isEdited, e.make IS NOT NULL AND e.make != '',
                   (a.type = 'IMAGE' AND (e.make IS NULL OR e.make = '') AND
                    (lower(a.originalFileName) LIKE '%.png' OR lower(a.originalFileName) LIKE '%screenshot%')),
                   a.ownerId, NULL, 1
            FROM partner p
            JOIN remoteAsset a ON a.ownerId = p.sharedById
            LEFT JOIN remoteExif e ON e.assetId = a.id
            WHERE p.sharedWithId = ?1 AND p.sharedById != ?1 AND p.inTimeline = 1
              AND a.visibility = 'timeline' AND a.deletedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM remoteAsset m WHERE m.ownerId = ?1 AND m.checksum = a.checksum AND m.deletedAt IS NULL)
              AND NOT EXISTS (SELECT 1 FROM localAsset l WHERE l.checksum = a.checksum)
            ORDER BY date, id
            """, arguments: [ownerID])
        var items: [TimelineItem] = []
        while let row = try rows.next() {
            let width: Int? = row[7]
            let height: Int? = row[8]
            let ratio: Double = if let width, let height, width > 0, height > 0 { Double(width) / Double(height) } else { 1 }
            items.append(TimelineItem(
                id: row[0], date: row[1] ?? .distantPast, isVideo: row[2], durationMs: row[3], isFavorite: row[4],
                isLivePhoto: row[5], thumbhash: row[6], aspectRatio: ratio, uploadedAt: row[9], isEdited: row[10],
                hasCamera: row[11], isScreenshot: row[12], ownerID: row[13], localID: row[14], isRemote: row[15]
            ))
        }
        return items
    }

    /// The merged Library, now and after every change to the server or phone index.
    public static func observeMerged(ownerID: String, in database: AppDatabase) -> AsyncValueObservation<[TimelineItem]> {
        ValueObservation
            .tracking(region: RemoteAssetRecord.all(), RemoteExifRecord.all(), LocalAssetRecord.all(), PartnerRecord.all(), StackRecord.all()) { db in try merged(ownerID: ownerID, in: db) }
            .removeDuplicates()
            .values(in: database.reader, scheduling: .async(onQueue: .global(qos: .userInitiated)))
    }

    /// Emits the timeline now and after every committed change to `remoteAsset`.
    public static func observeRemote(ownerID: String, visibility: RemoteVisibility = .timeline, in database: AppDatabase) -> AsyncValueObservation<[TimelineItem]> {
        observeRemote(ownerID: ownerID, scope: .visibility(visibility), in: database)
    }

    public static func observeRemote(ownerID: String, scope: TimelineScope, in database: AppDatabase) -> AsyncValueObservation<[TimelineItem]> {
        ValueObservation
            .tracking(region: RemoteAssetRecord.all(), RemoteExifRecord.all()) { db in try remote(ownerID: ownerID, scope: scope, in: db) }
            .removeDuplicates()
            .values(in: database.reader, scheduling: .async(onQueue: .global(qos: .userInitiated)))
    }
}

/// A library someone shares with the signed-in user (partner sharing).
public struct SharedLibrary: Sendable, Hashable, Identifiable {
    /// The partner's user id.
    public let id: String
    public let name: String
    public let email: String
    public let inTimeline: Bool
    public let itemCount: Int

    public init(id: String, name: String, email: String, inTimeline: Bool, itemCount: Int) {
        self.id = id
        self.name = name
        self.email = email
        self.inTimeline = inTimeline
        self.itemCount = itemCount
    }
}

/// Someone the signed-in user shares their own library with.
public struct LibraryRecipient: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let email: String

    public init(id: String, name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }
}

public enum PartnerQuery {
    /// People sharing their library with `userID`, by name.
    public static func sharedWith(_ userID: String, in db: Database) throws -> [SharedLibrary] {
        try Row.fetchAll(db, sql: """
            SELECT p.sharedById AS id, COALESCE(u.name, '') AS name, COALESCE(u.email, '') AS email, p.inTimeline,
                   (SELECT COUNT(*) FROM remoteAsset a WHERE a.ownerId = p.sharedById AND a.visibility = 'timeline' AND a.deletedAt IS NULL) AS n
            FROM partner p LEFT JOIN user u ON u.id = p.sharedById
            WHERE p.sharedWithId = ? AND p.sharedById != p.sharedWithId
            ORDER BY name
            """, arguments: [userID]).map {
            SharedLibrary(id: $0["id"], name: $0["name"], email: $0["email"], inTimeline: $0["inTimeline"], itemCount: $0["n"])
        }
    }

    /// People `userID` shares their library with, by name.
    public static func recipients(of userID: String, in db: Database) throws -> [LibraryRecipient] {
        try Row.fetchAll(db, sql: """
            SELECT p.sharedWithId AS id, COALESCE(u.name, '') AS name, COALESCE(u.email, '') AS email
            FROM partner p LEFT JOIN user u ON u.id = p.sharedWithId
            WHERE p.sharedById = ? AND p.sharedById != p.sharedWithId
            ORDER BY name
            """, arguments: [userID]).map { LibraryRecipient(id: $0["id"], name: $0["name"], email: $0["email"]) }
    }

    public static func observe(_ userID: String, in database: AppDatabase) -> AsyncValueObservation<(sharedWithMe: [SharedLibrary], recipients: [LibraryRecipient])> {
        ValueObservation
            .tracking(region: PartnerRecord.all(), UserRecord.all(), RemoteAssetRecord.all()) { db in
                (try sharedWith(userID, in: db), try recipients(of: userID, in: db))
            }
            .removeDuplicates { $0.sharedWithMe == $1.sharedWithMe && $0.recipients == $1.recipients }
            .values(in: database.reader, scheduling: .async(onQueue: .global(qos: .userInitiated)))
    }

    /// Records a change to "show in Library" at once (sync confirms it later).
    public static func setInTimeline(_ inTimeline: Bool, sharedBy partnerID: String, with userID: String, in db: Database) throws {
        try db.execute(sql: "UPDATE partner SET inTimeline = ? WHERE sharedById = ? AND sharedWithId = ?", arguments: [inTimeline, partnerID, userID])
    }
}
