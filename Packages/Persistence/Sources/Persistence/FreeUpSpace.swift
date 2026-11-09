import Foundation
import GRDB

/// A phone photo that's safely in the Cloud and could be removed from the phone.
public struct FreeUpCandidate: Sendable, Hashable, Identifiable {
    /// The phone's local identifier.
    public let id: String
    public let checksum: String
    /// When the phone's file was hashed; a later edit means it's no longer the file in the Cloud.
    public let checksumModifiedAt: Date?
    public let remoteID: String
    /// The Live Photo's motion part in the Cloud, and its checksum.
    public let motionRemoteID: String?
    public let motionChecksum: String?
    public let isVideo: Bool
    /// Size of the Cloud copy (both parts of a Live Photo).
    public let bytes: Int64
    public let date: Date
    public let thumbhash: String?

    public init(id: String, checksum: String, checksumModifiedAt: Date?, remoteID: String, motionRemoteID: String?, motionChecksum: String?,
                isVideo: Bool, bytes: Int64, date: Date, thumbhash: String?) {
        self.id = id
        self.checksum = checksum
        self.checksumModifiedAt = checksumModifiedAt
        self.remoteID = remoteID
        self.motionRemoteID = motionRemoteID
        self.motionChecksum = motionChecksum
        self.isVideo = isVideo
        self.bytes = bytes
        self.date = date
        self.thumbhash = thumbhash
    }
}

public struct FreeUpOptions: Sendable, Equatable {
    public enum Media: String, Sendable, CaseIterable { case all, photos, videos }

    /// Only items taken on or before this moment.
    public var cutoff: Date
    public var keepFavourites: Bool
    public var media: Media

    public init(cutoff: Date, keepFavourites: Bool = true, media: Media = .all) {
        self.cutoff = cutoff
        self.keepFavourites = keepFavourites
        self.media = media
    }
}

public enum FreeUpSpace {
    /// The owner's phone photos whose exact file (and a Live Photo's motion part) is in their
    /// own Cloud library and not in its trash. Left out: Hidden photos, favourites (either
    /// side) when kept, Live Photos whose motion part isn't in the Cloud, and anything still
    /// waiting in the backup queue. The server is asked again before anything is deleted.
    public static func candidates(ownerID: String, options: FreeUpOptions, in db: Database) throws -> [FreeUpCandidate] {
        let media: String = switch options.media {
        case .all: "1, 2"
        case .photos: "1"
        case .videos: "2"
        }
        return try Row.fetchAll(db, sql: """
            SELECT l.id, l.checksum, l.checksumModifiedAt, l.mediaType = 2 AS isVideo,
                   COALESCE(l.localDateTime, l.createdAt) AS date,
                   r.id AS remoteId, r.thumbhash, mv.id AS motionId, mv.checksum AS motionChecksum,
                   COALESCE(e.fileSizeInByte, 0) + COALESCE(me.fileSizeInByte, 0) AS bytes
            FROM localAsset l
            JOIN remoteAsset r ON r.ownerId = ?1 AND r.checksum = l.checksum AND r.deletedAt IS NULL
            LEFT JOIN remoteExif e ON e.assetId = r.id
            LEFT JOIN remoteAsset mv ON mv.id = r.livePhotoVideoId AND mv.ownerId = ?1 AND mv.deletedAt IS NULL
            LEFT JOIN remoteExif me ON me.assetId = mv.id
            WHERE l.checksum IS NOT NULL AND l.isHidden = 0 AND l.mediaType IN (\(media))
              AND COALESCE(l.createdAt, l.localDateTime) <= ?2
              AND (?3 = 0 OR (l.isFavorite = 0 AND r.isFavorite = 0))
              AND ((l.subtypes & 8) = 0 OR mv.id IS NOT NULL)
              AND NOT EXISTS (SELECT 1 FROM uploadTask t WHERE t.localId = l.id AND t.state != 'done')
            GROUP BY l.id
            ORDER BY date
            """, arguments: [ownerID, options.cutoff, options.keepFavourites]).map { row in
            FreeUpCandidate(
                id: row["id"], checksum: row["checksum"], checksumModifiedAt: row["checksumModifiedAt"], remoteID: row["remoteId"],
                motionRemoteID: row["motionId"], motionChecksum: row["motionChecksum"], isVideo: row["isVideo"],
                bytes: row["bytes"], date: row["date"] ?? .distantPast, thumbhash: row["thumbhash"]
            )
        }
    }

    /// Whether iCloud Photos seems to be on (phone photos carry iCloud identities).
    public static func phoneUsesICloud(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM localAsset WHERE cloudId IS NOT NULL)") ?? false
    }
}
