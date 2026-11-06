import Foundation
import GRDB

public enum RemoteAssetType: String, Codable, Sendable, DatabaseValueConvertible {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"
}

/// Mirrors Immich `AssetVisibility`.
public enum RemoteVisibility: String, Codable, Sendable, DatabaseValueConvertible {
    case archive
    case timeline
    case hidden
    case locked
}

public struct RemoteAssetRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "remoteAsset"

    public var id: String
    public var ownerId: String
    public var checksum: String
    public var type: RemoteAssetType
    public var originalFileName: String
    public var fileCreatedAt: Date?
    public var fileModifiedAt: Date?
    /// Wall-clock time where the photo was taken, encoded as if it were UTC (Immich convention).
    public var localDateTime: Date?
    public var uploadedAt: Date?
    public var deletedAt: Date?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var isFavorite: Bool
    public var isEdited: Bool
    public var visibility: RemoteVisibility
    public var livePhotoVideoId: String?
    public var stackId: String?
    public var libraryId: String?
    public var thumbhash: String?

    public init(
        id: String, ownerId: String, checksum: String, type: RemoteAssetType, originalFileName: String,
        fileCreatedAt: Date?, fileModifiedAt: Date?, localDateTime: Date?, uploadedAt: Date?, deletedAt: Date?,
        width: Int?, height: Int?, durationMs: Int?, isFavorite: Bool, isEdited: Bool,
        visibility: RemoteVisibility, livePhotoVideoId: String?, stackId: String?, libraryId: String?,
        thumbhash: String?
    ) {
        self.id = id
        self.ownerId = ownerId
        self.checksum = checksum
        self.type = type
        self.originalFileName = originalFileName
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.localDateTime = localDateTime
        self.uploadedAt = uploadedAt
        self.deletedAt = deletedAt
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.visibility = visibility
        self.livePhotoVideoId = livePhotoVideoId
        self.stackId = stackId
        self.libraryId = libraryId
        self.thumbhash = thumbhash
    }
}

public struct RemoteExifRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "remoteExif"

    public var assetId: String
    public var make: String?
    public var model: String?
    public var lensModel: String?
    public var exposureTime: String?
    public var fNumber: Double?
    public var focalLength: Double?
    public var iso: Int?
    public var fileSizeInByte: Int?
    public var exifImageWidth: Int?
    public var exifImageHeight: Int?
    public var orientation: String?
    public var dateTimeOriginal: Date?
    public var timeZone: String?
    public var latitude: Double?
    public var longitude: Double?
    public var city: String?
    public var state: String?
    public var country: String?
    public var description: String?
    public var profileDescription: String?
    public var projectionType: String?
    public var fps: Double?
    public var rating: Int?

    public init(assetId: String) {
        self.assetId = assetId
    }
}

public struct RemoteAssetCloudIdRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "remoteAssetCloudId"

    public var assetId: String
    public var cloudId: String?
    public var createdAt: String?
    public var adjustmentTime: String?
    public var latitude: String?
    public var longitude: String?

    public init(assetId: String, cloudId: String?, createdAt: String?, adjustmentTime: String?, latitude: String?, longitude: String?) {
        self.assetId = assetId
        self.cloudId = cloudId
        self.createdAt = createdAt
        self.adjustmentTime = adjustmentTime
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct UserRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "user"

    public var id: String
    public var name: String
    public var email: String
    public var avatarColor: String?
    public var hasProfileImage: Bool

    public init(id: String, name: String, email: String, avatarColor: String?, hasProfileImage: Bool) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarColor = avatarColor
        self.hasProfileImage = hasProfileImage
    }
}
