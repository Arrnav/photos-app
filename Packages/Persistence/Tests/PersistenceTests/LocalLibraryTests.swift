import Foundation
import GRDB
import Testing
@testable import Persistence

private func remote(_ index: Int, checksum: String? = nil, visibility: RemoteVisibility = .timeline, deleted: Bool = false) -> RemoteAssetRecord {
    let date = Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 3600)
    return RemoteAssetRecord(
        id: String(format: "r-%06d", index), ownerId: "me", checksum: checksum ?? "sum\(index)", type: .image,
        originalFileName: "IMG_\(index).HEIC", fileCreatedAt: date, fileModifiedAt: date, localDateTime: date,
        uploadedAt: date, deletedAt: deleted ? date : nil, width: 4032, height: 3024, durationMs: nil,
        isFavorite: false, isEdited: false, visibility: visibility, livePhotoVideoId: nil, stackId: nil,
        libraryId: nil, thumbhash: "x"
    )
}

private func local(_ id: String, hour: Int, checksum: String? = nil, modified: Double = 0, video: Bool = false) -> LocalAssetRecord {
    let date = Date(timeIntervalSince1970: 1_600_000_000 + Double(hour) * 3600 + 60)
    var record = LocalAssetRecord(
        id: id, mediaType: video ? LocalAssetRecord.video : LocalAssetRecord.image, createdAt: date, localDateTime: date,
        modifiedAt: Date(timeIntervalSince1970: modified), width: 3024, height: 4032
    )
    record.checksum = checksum
    return record
}

@Suite struct MergedTimelineTests {
    @Test func pairsPhoneAndServerCopiesByChecksum() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try RemoteStore.upsert([remote(1), remote(2), remote(3, visibility: .archive), remote(4, deleted: true)], in: db)
            try LocalStore.upsert([
                local("L-both", hour: 1), local("L-only", hour: 5), local("L-archived", hour: 3), local("L-trashed", hour: 4),
            ], in: db)
            for (id, sum) in [("L-both", "sum1"), ("L-archived", "sum3"), ("L-trashed", "sum4")] {
                try LocalStore.setChecksum(sum, source: .hashed, id: id, modifiedAt: Date(timeIntervalSince1970: 0), in: db)
            }
        }
        let items = try database.reader.read { db in try TimelineQuery.merged(ownerID: "me", in: db) }
        #expect(items.map(\.id) == ["r-000001", "r-000002", "local:L-trashed", "local:L-only"])
        #expect(items[0].localID == "L-both" && items[0].isRemote)
        #expect(items[1].localID == nil && items[1].isRemote)
        // On the server only in the trash: shown as a phone photo (it isn't safely backed up).
        #expect(items[2].localID == "L-trashed" && !items[2].isRemote && items[2].remoteID == nil)
        #expect(abs(items[3].aspectRatio - 0.75) < 0.001)
    }

    @Test func editsClearTheChecksum() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try LocalStore.upsert([local("A", hour: 1, modified: 10)], in: db)
            try LocalStore.setChecksum("abc", source: .hashed, id: "A", modifiedAt: Date(timeIntervalSince1970: 10), in: db)
            // Re-indexing without changes keeps it.
            try LocalStore.upsert([local("A", hour: 1, modified: 10)], in: db)
        }
        #expect(try database.reader.read { db in try LocalStore.record(id: "A", in: db)?.checksum } == "abc")
        try database.writer.write { db in try LocalStore.upsert([local("A", hour: 1, modified: 20)], in: db) }
        #expect(try database.reader.read { db in try LocalStore.record(id: "A", in: db)?.checksum } == nil)
        // A checksum computed for the old version is not stored.
        try database.writer.write { db in
            try LocalStore.setChecksum("old", source: .hashed, id: "A", modifiedAt: Date(timeIntervalSince1970: 10), in: db)
        }
        #expect(try database.reader.read { db in try LocalStore.record(id: "A", in: db)?.checksum } == nil)
    }

    @Test func findsCloudIdMatches() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try RemoteStore.upsert([remote(1)], in: db)
            try RemoteAssetCloudIdRecord(assetId: "r-000001", cloudId: "C1", createdAt: "2020-09-13T12:27:40.000Z", adjustmentTime: nil, latitude: nil, longitude: nil).insert(db)
            var record = local("L1", hour: 1)
            record.cloudId = "C1"
            try LocalStore.upsert([record, local("L2", hour: 2)], in: db)
        }
        let candidates = try database.reader.read { db in try LocalStore.cloudIdCandidates(ownerID: "me", in: db) }
        #expect(candidates.map(\.localID) == ["L1"])
        #expect(candidates.first?.remoteChecksum == "sum1")
        #expect(candidates.first?.remoteCreatedAt == "2020-09-13T12:27:40.000Z")
    }

    @Test func mergesALargeLibraryQuickly() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "merged-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try AppDatabase.open(at: url)
        try database.writer.write { db in
            try RemoteStore.upsert((0..<25_000).map { remote($0) }, in: db)
            try LocalStore.upsert((0..<13_000).map { local("L\($0)", hour: $0 * 2, checksum: $0 % 2 == 0 ? "sum\($0 * 2)" : nil) }, in: db)
        }
        let clock = ContinuousClock()
        var items: [TimelineItem] = []
        let elapsed = try clock.measure { items = try database.reader.read { db in try TimelineQuery.merged(ownerID: "me", in: db) } }
        print("Merged timeline (25,000 server + 13,000 phone): \(elapsed)")
        // Odd ones have no checksum yet; even ones match the server below 12,500 (sum0…sum24998).
        #expect(items.count == 25_000 + 6_500 + 250)
        #expect(elapsed < .milliseconds(800))
    }
}
