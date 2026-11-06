import Core
import Foundation
import GRDB

/// The per-account SQLite database (PLAN.md §4.2). One writer, concurrent readers (WAL).
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database file at `url`.
    public static func open(at url: URL) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.label = "library"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// An in-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: Configuration()))
    }

    public var reader: any DatabaseReader { writer }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // No foreign keys between sync tables: the server may send related rows in
        // any order, so deletes cascade explicitly in RemoteStore instead.
        migrator.registerMigration("v1-remote") { db in
            try db.create(table: "remoteAsset") { t in
                t.primaryKey("id", .text)
                t.column("ownerId", .text).notNull()
                t.column("checksum", .text).notNull()
                t.column("type", .text).notNull()
                t.column("originalFileName", .text).notNull()
                t.column("fileCreatedAt", .datetime)
                t.column("fileModifiedAt", .datetime)
                t.column("localDateTime", .datetime)
                t.column("uploadedAt", .datetime)
                t.column("deletedAt", .datetime)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("durationMs", .integer)
                t.column("isFavorite", .boolean).notNull()
                t.column("isEdited", .boolean).notNull()
                t.column("visibility", .text).notNull()
                t.column("livePhotoVideoId", .text)
                t.column("stackId", .text)
                t.column("libraryId", .text)
                t.column("thumbhash", .text)
            }
            // Timeline: owner + visible + not trashed, newest first.
            try db.create(
                index: "remoteAsset_timeline",
                on: "remoteAsset",
                columns: ["ownerId", "visibility", "deletedAt", "localDateTime"]
            )
            try db.create(index: "remoteAsset_checksum", on: "remoteAsset", columns: ["ownerId", "checksum"])

            try db.create(table: "remoteExif") { t in
                t.primaryKey("assetId", .text)
                t.column("make", .text)
                t.column("model", .text)
                t.column("lensModel", .text)
                t.column("exposureTime", .text)
                t.column("fNumber", .double)
                t.column("focalLength", .double)
                t.column("iso", .integer)
                t.column("fileSizeInByte", .integer)
                t.column("exifImageWidth", .integer)
                t.column("exifImageHeight", .integer)
                t.column("orientation", .text)
                t.column("dateTimeOriginal", .datetime)
                t.column("timeZone", .text)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("city", .text)
                t.column("state", .text)
                t.column("country", .text)
                t.column("description", .text)
                t.column("profileDescription", .text)
                t.column("projectionType", .text)
                t.column("fps", .double)
                t.column("rating", .integer)
            }

            // The official app's "mobile-app" asset metadata (iCloud id etc.), used in M3
            // to recover local checksums after a reinstall without re-hashing.
            try db.create(table: "remoteAssetCloudId") { t in
                t.primaryKey("assetId", .text)
                t.column("cloudId", .text)
                t.column("createdAt", .text)
                t.column("adjustmentTime", .text)
                t.column("latitude", .text)
                t.column("longitude", .text)
            }
            try db.create(index: "remoteAssetCloudId_cloudId", on: "remoteAssetCloudId", columns: ["cloudId"])

            try db.create(table: "user") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("email", .text).notNull()
                t.column("avatarColor", .text)
                t.column("hasProfileImage", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        // M3: the phone's own library (PhotoKit), indexed so the merged timeline is one query.
        migrator.registerMigration("v2-local") { db in
            try db.create(table: "localAsset") { t in
                t.primaryKey("id", .text)                 // PHAsset.localIdentifier
                t.column("cloudId", .text)                // PHCloudIdentifier.stringValue (iCloud Photos)
                t.column("mediaType", .integer).notNull() // PHAssetMediaType
                t.column("subtypes", .integer).notNull()  // PHAssetMediaSubtype
                t.column("createdAt", .datetime)          // creationDate (an instant)
                t.column("localDateTime", .datetime)      // wall-clock capture time encoded as UTC, like the server's
                t.column("modifiedAt", .datetime)
                t.column("adjustmentTime", .datetime)     // set when edited on the phone
                t.column("isFavorite", .boolean).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("durationMs", .integer)
                t.column("latitude", .double)
                t.column("longitude", .double)
                // SHA-1 (base64) of the file a backup uploads, exactly as the official app computes it.
                t.column("checksum", .text)
                // "hashed" (computed here) or "cloudId" (taken from the server's record of the upload).
                t.column("checksumSource", .text)
                // `modifiedAt` when the checksum was set; a later edit means it must be recomputed.
                t.column("checksumModifiedAt", .datetime)
                t.column("hashError", .text)
            }
            try db.create(index: "localAsset_checksum", on: "localAsset", columns: ["checksum"])
            try db.create(index: "localAsset_cloudId", on: "localAsset", columns: ["cloudId"])
            try db.create(index: "localAsset_date", on: "localAsset", columns: ["localDateTime"])
        }

        // M5: the backup queue. One row per file to upload (a Live Photo has two parts).
        migrator.registerMigration("v3-backup") { db in
            try db.create(table: "uploadTask") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("localId", .text).notNull()
                t.column("part", .text).notNull()               // single | motion | still
                t.column("assetModifiedAt", .datetime)          // the version of the asset being uploaded
                t.column("state", .text).notNull()              // pending | uploading | waiting | done | failed
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAt", .datetime)
                t.column("lastError", .text)
                t.column("checksum", .text)                     // of the exact bytes uploaded
                t.column("fileName", .text)
                t.column("bodyFile", .text)                     // multipart body on disk while uploading
                t.column("bytes", .integer)
                t.column("sessionTaskId", .integer)
                t.column("remoteId", .text)
                t.column("replacesRemoteId", .text)             // an edited photo's earlier upload (stacked)
                t.column("createdAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.uniqueKey(["localId", "part"])
            }
            try db.create(index: "uploadTask_state", on: "uploadTask", columns: ["state", "nextAttemptAt"])
            try db.create(table: "backupAlbum") { t in
                t.primaryKey("id", .text)                       // PHAssetCollection.localIdentifier
                t.column("title", .text).notNull()
                t.column("mode", .text).notNull()               // include | exclude
            }
        }

        // Photos in the phone's Hidden album are indexed too (flagged), for Back Up Hidden
        // Photos; they never show in the Library. A full scan picks them up.
        migrator.registerMigration("v4-hidden") { db in
            try db.alter(table: "localAsset") { t in
                t.add(column: "isHidden", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [SyncState.Key.photoLibraryChangeToken.rawValue])
        }

        // Assets deleted for good from Recently Deleted that the server hasn't removed yet.
        migrator.registerMigration("v5-purged") { db in
            try db.create(table: "purgedAsset") { t in
                t.primaryKey("id", .text)
                t.column("purgedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
