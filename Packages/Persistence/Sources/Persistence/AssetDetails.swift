import Foundation
import GRDB

/// Everything the viewer's info panel shows that is already on the phone.
public struct AssetDetails: Sendable, Equatable {
    public let asset: RemoteAssetRecord
    public let exif: RemoteExifRecord?

    public init(asset: RemoteAssetRecord, exif: RemoteExifRecord?) {
        self.asset = asset
        self.exif = exif
    }

    public static func fetch(id: String, in db: Database) throws -> AssetDetails? {
        guard let asset = try RemoteAssetRecord.fetchOne(db, key: id) else { return nil }
        return AssetDetails(asset: asset, exif: try RemoteExifRecord.fetchOne(db, key: id))
    }
}

/// Local changes made right away when the user acts in the viewer, before the
/// server confirms. The next sync brings the server's state either way; on a
/// server error the caller reverts with the opposite change.
extension RemoteStore {
    public static func setFavorite(_ isFavorite: Bool, ids: [String], in db: Database) throws {
        try updateEach(ids, in: db) { $0.isFavorite = isFavorite }
    }

    public static func setVisibility(_ visibility: RemoteVisibility, ids: [String], in db: Database) throws {
        try updateEach(ids, in: db) { $0.visibility = visibility }
    }

    /// Marks assets as trashed (`date`) or restored (`nil`).
    public static func setDeletedAt(_ date: Date?, ids: [String], in db: Database) throws {
        try updateEach(ids, in: db) { $0.deletedAt = date }
    }

    /// The caption lives in the EXIF row (Immich `description`).
    public static func setDescription(_ text: String?, id: String, in db: Database) throws {
        var exif = try RemoteExifRecord.fetchOne(db, key: id) ?? RemoteExifRecord(assetId: id)
        exif.description = text
        try exif.upsert(db)
    }

    private static func updateEach(_ ids: [String], in db: Database, _ change: (inout RemoteAssetRecord) -> Void) throws {
        for id in ids {
            guard var record = try RemoteAssetRecord.fetchOne(db, key: id) else { continue }
            change(&record)
            try record.update(db)
        }
    }
}
