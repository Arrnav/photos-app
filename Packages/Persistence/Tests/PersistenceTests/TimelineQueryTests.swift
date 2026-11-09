import Foundation
import GRDB
import Testing
@testable import Persistence

private func asset(_ index: Int, owner: String = "me", visibility: RemoteVisibility = .timeline, deleted: Bool = false) -> RemoteAssetRecord {
    let date = Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 3600)
    return RemoteAssetRecord(
        id: String(format: "asset-%06d", index), ownerId: owner, checksum: "sum\(index)", type: index % 10 == 0 ? .video : .image,
        originalFileName: "IMG_\(index).HEIC", fileCreatedAt: date, fileModifiedAt: date, localDateTime: date,
        uploadedAt: date, deletedAt: deleted ? date : nil, width: 4032, height: 3024, durationMs: index % 10 == 0 ? 12_000 : nil,
        isFavorite: index % 7 == 0, isEdited: false, visibility: visibility, livePhotoVideoId: nil, stackId: nil,
        libraryId: nil, thumbhash: "1QcSHQRnh493V4dIh4eXh1h4kJUI"
    )
}

@Suite struct TimelineQueryTests {
    @Test func filtersByOwnerVisibilityAndTrash() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try RemoteStore.upsert([
                asset(1), asset(2),
                asset(3, owner: "partner"),
                asset(4, visibility: .archive),
                asset(5, visibility: .locked),
                asset(6, deleted: true),
            ], in: db)
        }
        let items = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", in: db) }
        #expect(items.map(\.id) == ["asset-000001", "asset-000002"])
    }

    @Test func trashAndArchiveScopes() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try RemoteStore.upsert([
                asset(1), asset(4, visibility: .archive), asset(6, deleted: true),
                asset(7, visibility: .locked, deleted: true), asset(8, owner: "partner", deleted: true),
            ], in: db)
        }
        let trash = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", scope: .trash, in: db) }
        #expect(trash.map(\.id) == ["asset-000006"])
        let archive = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", scope: .visibility(.archive), in: db) }
        #expect(archive.map(\.id) == ["asset-000004"])
    }

    @Test func searchMatchesEveryWordAcrossFields() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try RemoteStore.upsert([asset(1), asset(2), asset(3), asset(4, visibility: .archive)], in: db)
            try db.execute(sql: "INSERT INTO remoteExif (assetId, city, country, description) VALUES ('asset-000001', 'Lisbon', 'Portugal', 'Balcony plant'), ('asset-000002', 'Porto', 'Portugal', NULL), ('asset-000004', 'Lisbon', 'Portugal', NULL)")
        }
        let ids = { (text: String) in try database.reader.read { db in try LibrarySearch.assetIDs(ownerID: "me", text: text, in: db) } }
        #expect(try ids("lisbon") == ["asset-000001"])
        #expect(try ids("portugal") == ["asset-000002", "asset-000001"])
        #expect(try ids("lisbon plant") == ["asset-000001"])
        #expect(try ids("img_3") == ["asset-000003"])
        #expect(try ids("100%").isEmpty)
        let places = try database.reader.read { db in try LibrarySearch.topPlaces(ownerID: "me", limit: 5, in: db) }
        #expect(Set(places) == ["Lisbon", "Porto"])
    }

    @Test func upsertUpdatesInPlace() throws {
        let database = try AppDatabase.inMemory()
        var record = asset(1)
        try database.writer.write { db in try RemoteStore.upsert([record], in: db) }
        record.isFavorite = true
        try database.writer.write { db in try RemoteStore.upsert([record], in: db) }
        let items = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", in: db) }
        #expect(items.count == 1)
        #expect(items[0].isFavorite)
    }

    @Test func syncStateRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try SyncState.set(.sessionFingerprint, "abc", in: db)
            try SyncState.set(.sessionFingerprint, "def", in: db)
        }
        #expect(try database.reader.read { db in try SyncState.value(.sessionFingerprint, in: db) } == "def")
        try database.writer.write { db in try SyncState.set(.sessionFingerprint, nil, in: db) }
        #expect(try database.reader.read { db in try SyncState.value(.sessionFingerprint, in: db) } == nil)
    }

    /// The launch path loads the whole timeline; keep an eye on its cost at library scale.
    @Test func loadsThirtyThousandItemsQuickly() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "timeline-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try AppDatabase.open(at: url)
        try database.writer.write { db in
            try RemoteStore.upsert((0..<30_000).map { asset($0) }, in: db)
        }
        let clock = ContinuousClock()
        var items: [TimelineItem] = []
        let elapsed = try clock.measure {
            items = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", in: db) }
        }
        print("Timeline query for 30,000 items: \(elapsed)")
        #expect(items.count == 30_000)
        #expect(items.first?.id == "asset-000000")
        #expect(elapsed < .milliseconds(500))
    }
}

@Suite struct LocalChangeTests {
    @Test func favouriteArchiveAndTrashChangeTheTimeline() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in try RemoteStore.upsert([asset(1), asset(2), asset(3)], in: db) }
        try database.writer.write { db in
            try RemoteStore.setFavorite(true, ids: ["asset-000001"], in: db)
            try RemoteStore.setVisibility(.archive, ids: ["asset-000002"], in: db)
            try RemoteStore.setDeletedAt(Date(), ids: ["asset-000003"], in: db)
        }
        var items = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", in: db) }
        #expect(items.map(\.id) == ["asset-000001"])
        #expect(items[0].isFavorite)

        try database.writer.write { db in
            try RemoteStore.setVisibility(.timeline, ids: ["asset-000002"], in: db)
            try RemoteStore.setDeletedAt(nil, ids: ["asset-000003"], in: db)
        }
        items = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", in: db) }
        #expect(items.map(\.id) == ["asset-000001", "asset-000002", "asset-000003"])
    }

    @Test func detailsIncludeExifWhenPresent() throws {
        let database = try AppDatabase.inMemory()
        var exif = RemoteExifRecord(assetId: "asset-000001")
        exif.make = "Canon"
        try database.writer.write { db in
            try RemoteStore.upsert([asset(1), asset(2)], in: db)
            try RemoteStore.upsert([exif], in: db)
        }
        let withExif = try database.reader.read { db in try AssetDetails.fetch(id: "asset-000001", in: db) }
        #expect(withExif?.exif?.make == "Canon")
        let without = try database.reader.read { db in try AssetDetails.fetch(id: "asset-000002", in: db) }
        #expect(without?.asset.id == "asset-000002" && without?.exif == nil)
        #expect(try database.reader.read { db in try AssetDetails.fetch(id: "missing", in: db) } == nil)
    }
}

/// Photos with no capture date in their metadata: Immich stores the UTC instant as the
/// "local" time; it's shown in the phone's time zone instead (5:57 pm, not 12:27 pm, in India).
@Suite struct ZonelessTimeTests {
    @Test func utcInstantsBecomePhoneTime() throws {
        let database = try AppDatabase.inMemory()
        let instant = ISO8601DateFormatter().date(from: "2025-11-03T12:27:00Z")!
        let wallClock = instant.addingTimeInterval(19_800)
        try database.writer.write { db in
            for (id, local) in [("whatsapp", instant), ("screenshot", wallClock)] {
                try RemoteAssetRecord(id: id, ownerId: "me", checksum: id, type: .image, originalFileName: "x.jpg", fileCreatedAt: local,
                                      fileModifiedAt: nil, localDateTime: local, uploadedAt: nil, deletedAt: nil, width: nil, height: nil,
                                      durationMs: nil, isFavorite: false, isEdited: false, visibility: .timeline, livePhotoVideoId: nil,
                                      stackId: nil, libraryId: nil, thumbhash: nil).insert(db)
                try db.execute(sql: "INSERT INTO remoteAssetCloudId (assetId, cloudId, createdAt) VALUES (?, 'c', '2025-11-03T12:27:00.000Z')", arguments: [id])
            }
        }
        let india = TimeZone(identifier: "Asia/Kolkata")!
        #expect(try database.writer.write { db in try RemoteStore.fixZonelessLocalTimes(zone: india, in: db) } == 1)
        // Run again: nothing more to do.
        #expect(try database.writer.write { db in try RemoteStore.fixZonelessLocalTimes(zone: india, in: db) } == 0)
        let dates = try database.reader.read { db in try Date.fetchAll(db, sql: "SELECT localDateTime FROM remoteAsset ORDER BY id") }
        #expect(dates == [wallClock, wallClock])
    }
}
