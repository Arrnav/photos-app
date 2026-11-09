import Foundation
import GRDB
import Testing
@testable import Persistence

private let day: Double = 86_400
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func phone(_ id: String, daysAgo: Double, checksum: String?, live: Bool = false, favourite: Bool = false, hidden: Bool = false, video: Bool = false) -> LocalAssetRecord {
    let date = base.addingTimeInterval(-daysAgo * day)
    var record = LocalAssetRecord(id: id, mediaType: video ? LocalAssetRecord.video : LocalAssetRecord.image,
                                  subtypes: live ? LocalAssetRecord.livePhotoSubtype : 0, createdAt: date, localDateTime: date,
                                  modifiedAt: date, width: 10, height: 10)
    record.checksum = checksum
    record.checksumModifiedAt = date
    record.isFavorite = favourite
    record.isHidden = hidden
    return record
}

private func cloud(_ id: String, checksum: String, owner: String = "me", deleted: Bool = false, favourite: Bool = false, motion: String? = nil) -> RemoteAssetRecord {
    RemoteAssetRecord(id: id, ownerId: owner, checksum: checksum, type: .image, originalFileName: "x.heic", fileCreatedAt: nil,
                      fileModifiedAt: nil, localDateTime: nil, uploadedAt: nil, deletedAt: deleted ? .now : nil, width: nil, height: nil,
                      durationMs: nil, isFavorite: favourite, isEdited: false, visibility: .timeline, livePhotoVideoId: motion, stackId: nil,
                      libraryId: nil, thumbhash: nil)
}

@Suite struct FreeUpSpaceTests {
    @Test func onlyPhotosSafelyInTheOwnersCloudQualify() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try LocalStore.upsert([
                phone("ok", daysAgo: 40, checksum: "a"),
                phone("recent", daysAgo: 1, checksum: "b"),
                phone("trashed", daysAgo: 40, checksum: "c"),
                phone("partner", daysAgo: 40, checksum: "d"),
                phone("unhashed", daysAgo: 40, checksum: nil),
                phone("fav", daysAgo: 40, checksum: "e", favourite: true),
                phone("cloudFav", daysAgo: 40, checksum: "f"),
                phone("hidden", daysAgo: 40, checksum: "g", hidden: true),
                phone("liveNoMotion", daysAgo: 40, checksum: "h", live: true),
                phone("live", daysAgo: 40, checksum: "i", live: true),
                phone("queued", daysAgo: 40, checksum: "j"),
                phone("notInCloud", daysAgo: 40, checksum: "k"),
            ], in: db)
            for record in [
                cloud("r-a", checksum: "a"), cloud("r-b", checksum: "b"), cloud("r-c", checksum: "c", deleted: true),
                cloud("r-d", checksum: "d", owner: "partner"), cloud("r-e", checksum: "e"), cloud("r-f", checksum: "f", favourite: true),
                cloud("r-g", checksum: "g"), cloud("r-h", checksum: "h"), cloud("r-i", checksum: "i", motion: "r-i-motion"),
                cloud("r-i-motion", checksum: "i-motion"), cloud("r-j", checksum: "j"),
            ] { try record.insert(db) }
            try RemoteExifRecord(assetId: "r-i").inserted(db, fileSize: 3_000)
            try RemoteExifRecord(assetId: "r-i-motion").inserted(db, fileSize: 2_000)
            try db.execute(sql: "INSERT INTO uploadTask (localId, part, state, createdAt) VALUES ('queued', 'single', 'pending', ?)", arguments: [Date.now])
        }
        let options = FreeUpOptions(cutoff: base.addingTimeInterval(-30 * day))
        let ids = try database.reader.read { db in try FreeUpSpace.candidates(ownerID: "me", options: options, in: db) }
        #expect(Set(ids.map(\.id)) == ["ok", "live"])
        let live = ids.first { $0.id == "live" }
        #expect(live?.motionRemoteID == "r-i-motion")
        #expect(live?.motionChecksum == "i-motion")
        #expect(live?.bytes == 5_000)

        var keepNothing = options
        keepNothing.keepFavourites = false
        let all = try database.reader.read { db in try FreeUpSpace.candidates(ownerID: "me", options: keepNothing, in: db) }
        #expect(Set(all.map(\.id)) == ["ok", "live", "fav", "cloudFav"])

        var videos = keepNothing
        videos.media = .videos
        #expect(try database.reader.read { db in try FreeUpSpace.candidates(ownerID: "me", options: videos, in: db) }.isEmpty)
    }
}

private extension RemoteExifRecord {
    func inserted(_ db: Database, fileSize: Int) throws {
        var record = self
        record.fileSizeInByte = fileSize
        try record.insert(db)
    }
}
