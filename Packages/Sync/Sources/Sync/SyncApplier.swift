import Core
import Foundation
import GRDB
import ImmichAPI
import Persistence

/// Writes runs of sync events to the database. A run is a slice of lines with
/// the same `type`, applied in a single transaction.
enum SyncApplier {
    /// Key under which the official app stores iCloud ids in asset metadata.
    static let mobileAppMetadataKey = "mobile-app"

    static func apply(_ run: ArraySlice<SyncLine>, in db: Database) throws {
        guard let first = run.first else { return }
        switch first.event {
        case .authUser:
            let users: [UserRecord] = run.compactMap { line in
                guard case .authUser(let user) = line.event else { return nil }
                return UserRecord(id: user.id, name: user.name, email: user.email,
                                  avatarColor: user.avatarColor?.value1.rawValue, hasProfileImage: user.hasProfileImage)
            }
            try RemoteStore.upsert(users, in: db)
            if let me = users.last?.id { try SyncState.set(.authUserID, me, in: db) }
        case .user:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .user(let user) = line.event else { return nil }
                return UserRecord(id: user.id, name: user.name, email: user.email,
                                  avatarColor: user.avatarColor?.value1.rawValue, hasProfileImage: user.hasProfileImage)
            }, in: db)
        case .userDelete:
            try RemoteStore.deleteUsers(ids: run.compactMap { line in
                guard case .userDelete(let delete) = line.event else { return nil }
                return delete.userId
            }, in: db)
        case .asset:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .asset(let asset) = line.event else { return nil }
                return record(from: asset)
            }, in: db)
        case .assetDelete:
            try RemoteStore.deleteAssets(ids: run.compactMap { line in
                guard case .assetDelete(let delete) = line.event else { return nil }
                return delete.assetId
            }, in: db)
        case .assetExif:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .assetExif(let exif) = line.event else { return nil }
                return record(from: exif)
            }, in: db)
        case .assetMetadata:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .assetMetadata(let metadata) = line.event else { return nil }
                return cloudIdRecord(from: metadata)
            }, in: db)
        case .assetMetadataDelete:
            try RemoteStore.deleteCloudIds(assetIDs: run.compactMap { line in
                guard case .assetMetadataDelete(let delete) = line.event, delete.key == mobileAppMetadataKey else { return nil }
                return delete.assetId
            }, in: db)
        case .partner:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .partner(let partner) = line.event else { return nil }
                return PartnerRecord(sharedById: partner.sharedById, sharedWithId: partner.sharedWithId, inTimeline: partner.inTimeline)
            }, in: db)
        case .stack:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .stack(let stack) = line.event else { return nil }
                return StackRecord(id: stack.id, ownerId: stack.ownerId, primaryAssetId: stack.primaryAssetId)
            }, in: db)
        case .stackDelete:
            try RemoteStore.deleteStacks(run.compactMap { line in
                guard case .stackDelete(let stack) = line.event else { return nil }
                return stack.stackId
            }, in: db)
        case .partnerDelete:
            try RemoteStore.deletePartners(run.compactMap { line in
                guard case .partnerDelete(let partner) = line.event else { return nil }
                return (partner.sharedById, partner.sharedWithId)
            }, in: db)
        case .partnerAsset:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .partnerAsset(let asset) = line.event else { return nil }
                return record(from: asset)
            }, in: db)
        case .partnerAssetDelete:
            try RemoteStore.deleteAssets(ids: run.compactMap { line in
                guard case .partnerAssetDelete(let delete) = line.event else { return nil }
                return delete.assetId
            }, in: db)
        case .partnerAssetExif:
            try RemoteStore.upsert(run.compactMap { line in
                guard case .partnerAssetExif(let exif) = line.event else { return nil }
                return record(from: exif)
            }, in: db)
        case .reset:
            Log.sync.notice("Server requested a sync reset; clearing synced data")
            try RemoteStore.resetAll(in: db)
        case .complete:
            try RemoteStore.fixZonelessLocalTimes(in: db)
            try SyncState.set(.lastCompletedAt, Date.now.ISO8601Format(), in: db)
        case .ignored:
            Log.sync.debug("Ignoring \(run.count) \(first.type, privacy: .public) events")
        case .undecodable(let reason):
            Log.sync.error("Skipping \(run.count) \(first.type, privacy: .public) events that could not be read: \(reason, privacy: .public)")
        }
    }

    static func record(from asset: Schemas.SyncAssetV2) -> RemoteAssetRecord {
        RemoteAssetRecord(
            id: asset.id,
            ownerId: asset.ownerId,
            checksum: asset.checksum,
            type: RemoteAssetType(rawValue: asset._type.rawValue) ?? .other,
            originalFileName: asset.originalFileName,
            fileCreatedAt: asset.fileCreatedAt,
            fileModifiedAt: asset.fileModifiedAt,
            localDateTime: asset.localDateTime,
            uploadedAt: asset.createdAt,
            deletedAt: asset.deletedAt,
            width: asset.width,
            height: asset.height,
            durationMs: asset.duration,
            isFavorite: asset.isFavorite,
            isEdited: asset.isEdited,
            visibility: RemoteVisibility(rawValue: asset.visibility.rawValue) ?? .hidden,
            livePhotoVideoId: asset.livePhotoVideoId,
            stackId: asset.stackId,
            libraryId: asset.libraryId,
            thumbhash: asset.thumbhash
        )
    }

    static func record(from exif: Schemas.SyncAssetExifV1) -> RemoteExifRecord {
        var record = RemoteExifRecord(assetId: exif.assetId)
        record.make = exif.make
        record.model = exif.model
        record.lensModel = exif.lensModel
        record.exposureTime = exif.exposureTime
        record.fNumber = exif.fNumber
        record.focalLength = exif.focalLength
        record.iso = exif.iso
        record.fileSizeInByte = exif.fileSizeInByte
        record.exifImageWidth = exif.exifImageWidth
        record.exifImageHeight = exif.exifImageHeight
        record.orientation = exif.orientation
        record.dateTimeOriginal = exif.dateTimeOriginal
        record.timeZone = exif.timeZone
        record.latitude = exif.latitude
        record.longitude = exif.longitude
        record.city = exif.city
        record.state = exif.state
        record.country = exif.country
        record.description = exif.description
        record.profileDescription = exif.profileDescription
        record.projectionType = exif.projectionType
        record.fps = exif.fps
        record.rating = exif.rating
        return record
    }

    /// Only `mobile-app` metadata is kept; other keys are ignored.
    static func cloudIdRecord(from metadata: Schemas.SyncAssetMetadataV1) -> RemoteAssetCloudIdRecord? {
        guard metadata.key == mobileAppMetadataKey else { return nil }
        let values = metadata.value.additionalProperties
        func string(_ key: String) -> String? {
            switch values[key]?.value {
            case let text as String: text
            case let number as Double: String(number)
            case let number as Int: String(number)
            default: nil
            }
        }
        return RemoteAssetCloudIdRecord(
            assetId: metadata.assetId,
            // The official app writes "iCloudId"; "cloudId" is accepted too.
            cloudId: string("iCloudId") ?? string("cloudId"),
            createdAt: string("createdAt"),
            adjustmentTime: string("adjustmentTime"),
            latitude: string("latitude"),
            longitude: string("longitude")
        )
    }
}
