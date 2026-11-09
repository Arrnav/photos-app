import Foundation
import GRDB
import Testing
@testable import Persistence

private func local(_ id: String, hour: Int, checksum: String? = nil, live: Bool = false, modified: Double = 1) -> LocalAssetRecord {
    let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(hour) * 3600)
    var record = LocalAssetRecord(id: id, mediaType: 1, subtypes: live ? LocalAssetRecord.livePhotoSubtype : 0, createdAt: date,
                                  localDateTime: date, modifiedAt: Date(timeIntervalSince1970: modified), width: 10, height: 10)
    record.checksum = checksum
    return record
}

private func remote(_ id: String, checksum: String, deleted: Bool = false) -> RemoteAssetRecord {
    RemoteAssetRecord(id: id, ownerId: "me", checksum: checksum, type: .image, originalFileName: "x.heic", fileCreatedAt: nil,
                      fileModifiedAt: nil, localDateTime: nil, uploadedAt: nil, deletedAt: deleted ? .now : nil, width: nil, height: nil,
                      durationMs: nil, isFavorite: false, isEdited: false, visibility: .timeline, livePhotoVideoId: nil, stackId: nil,
                      libraryId: nil, thumbhash: nil)
}

@Suite struct BackupStoreTests {
    private func database() throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try LocalStore.upsert([
                local("on-server", hour: 1), local("trashed-in-cloud", hour: 2), local("new", hour: 3),
                local("unhashed", hour: 4), local("live", hour: 5, live: true),
            ], in: db)
            for (id, sum) in [("on-server", "s1"), ("trashed-in-cloud", "s2"), ("new", "s3"), ("live", "s5")] {
                try LocalStore.setChecksum(sum, source: .hashed, id: id, modifiedAt: Date(timeIntervalSince1970: 1), in: db)
            }
            try RemoteStore.upsert([remote("r1", checksum: "s1"), remote("r2", checksum: "s2", deleted: true)], in: db)
        }
        return database
    }

    @Test func candidatesSkipWhatCloudHasIncludingTrash() throws {
        let database = try database()
        let ids = try database.reader.read { db in try BackupStore.candidates(ownerID: "me", scope: nil, in: db) }.map(\.localID)
        #expect(ids == ["live", "unhashed", "new"])
        let scoped = try database.reader.read { db in try BackupStore.candidates(ownerID: "me", scope: ["new"], in: db) }.map(\.localID)
        #expect(scoped == ["new"])
    }

    @Test func queuedOnceAndLivePhotoMotionFirst() throws {
        let database = try database()
        try database.writer.write { db in
            let candidates = try BackupStore.candidates(ownerID: "me", scope: nil, in: db)
            #expect(try BackupStore.enqueue(candidates, in: db) == 4) // live = motion + still
            // Queued items are not candidates again (never queued twice).
            #expect(try BackupStore.candidates(ownerID: "me", scope: nil, in: db).isEmpty)
            #expect(try BackupStore.enqueue(candidates, in: db) == 0)
        }
        let due = try database.reader.read { db in try BackupStore.nextDue(limit: 10, in: db) }
        // The still waits for its motion part.
        #expect(due.map { "\($0.localId)/\($0.part.rawValue)" } == ["live/motion", "unhashed/single", "new/single"])
        try database.writer.write { db in
            var motion = due[0]
            motion.state = .done
            motion.remoteId = "m1"
            try BackupStore.save(motion, in: db)
        }
        let next = try database.reader.read { db in try BackupStore.nextDue(limit: 10, in: db) }
        #expect(next.first.map { "\($0.localId)/\($0.part.rawValue)" } == "live/still")
        #expect(try database.reader.read { db in try BackupStore.motionRemoteId(localID: "live", in: db) } == "m1")
    }

    @Test func editedPhotoIsQueuedAgainAndRemembersItsEarlierUpload() throws {
        let database = try database()
        try database.writer.write { db in
            _ = try BackupStore.enqueue([("new", Date(timeIntervalSince1970: 1), false)], in: db)
            var task = try BackupStore.nextDue(limit: 1, in: db)[0]
            task.state = .done
            task.remoteId = "r-old"
            try BackupStore.save(task, in: db)
            // Edited on the phone: new modification date.
            #expect(try BackupStore.enqueue([("new", Date(timeIntervalSince1970: 99), false)], in: db) == 1)
            let again = try BackupStore.nextDue(limit: 1, in: db)[0]
            #expect(again.state == .pending && again.replacesRemoteId == "r-old")
        }
    }

    @Test func waitingTasksBecomeDueAfterTheirBackoff() throws {
        let database = try database()
        try database.writer.write { db in
            _ = try BackupStore.enqueue([("new", Date(timeIntervalSince1970: 1), false)], in: db)
            var task = try BackupStore.nextDue(limit: 1, in: db)[0]
            task.state = .waiting
            task.nextAttemptAt = Date(timeIntervalSince1970: 2_000_000_000)
            try BackupStore.save(task, in: db)
            #expect(try BackupStore.nextDue(limit: 1, now: Date(timeIntervalSince1970: 1_999_999_999), in: db).isEmpty)
            #expect(try BackupStore.nextDue(limit: 1, now: Date(timeIntervalSince1970: 2_000_000_001), in: db).count == 1)
        }
    }

    @Test func countsBackedUpPhotos() throws {
        let database = try database()
        let counts = try database.reader.read { db in try BackupStore.counts(ownerID: "me", scope: nil, in: db) }
        #expect(counts.total == 5)
        #expect(counts.backedUp == 2) // on server, and trashed in Cloud (still counted as held there)
        #expect(counts.remaining == 3)
    }

    @Test func eachLivePhotoFinishesBeforeOlderOnes() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try LocalStore.upsert([local("old-live", hour: 1, live: true), local("single", hour: 2), local("new-live", hour: 3, live: true)], in: db)
            _ = try BackupStore.enqueue(try BackupStore.candidates(ownerID: "me", scope: nil, in: db), in: db)
        }
        let first = try database.reader.read { db in try BackupStore.nextDue(limit: 10, in: db) }
        #expect(first.map { "\($0.localId)/\($0.part.rawValue)" } == ["new-live/motion", "single/single", "old-live/motion"])
        try database.writer.write { db in
            var motion = first[0]
            motion.state = .done
            try BackupStore.save(motion, in: db)
        }
        let next = try database.reader.read { db in try BackupStore.nextDue(limit: 10, in: db) }
        #expect(next.first.map { "\($0.localId)/\($0.part.rawValue)" } == "new-live/still")
    }
}

/// Photos in the phone's Hidden album never reach the Library and are never backed up.
@Suite struct HiddenPhotoTests {
    private func database() throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var secret = local("secret", hour: 1)
            secret.isHidden = true
            var hiddenInCloud = local("hidden-in-cloud", hour: 2)
            hiddenInCloud.isHidden = true
            try LocalStore.upsert([secret, hiddenInCloud, local("visible", hour: 3)], in: db)
            for (id, sum) in [("secret", "h1"), ("hidden-in-cloud", "h2"), ("visible", "v1")] {
                try LocalStore.setChecksum(sum, source: .hashed, id: id, modifiedAt: Date(timeIntervalSince1970: 1), in: db)
            }
            try RemoteStore.upsert([remote("r-hidden", checksum: "h2")], in: db)
        }
        return database
    }

    @Test func hiddenPhotosNeverShowInTheLibrary() throws {
        let items = try database().reader.read { db in try TimelineQuery.merged(ownerID: "me", in: db) }
        #expect(!items.contains { $0.id == "local:secret" })
        // The Cloud copy shows, but isn't paired with the hidden phone photo.
        #expect(items.first { $0.id == "r-hidden" }?.localID == nil)
        #expect(items.contains { $0.id == "local:visible" })
    }

    @Test func neverQueuedOrCounted() throws {
        let database = try database()
        #expect(try database.reader.read { db in try BackupStore.candidates(ownerID: "me", scope: nil, in: db) }.map(\.localID) == ["visible"])
        #expect(try database.reader.read { db in try BackupStore.counts(ownerID: "me", scope: nil, in: db) }.total == 1)
    }
}

/// Delete from the Library and Recently Deleted: phone copies are found so they're
/// deleted too, and assets deleted for good stay gone while the server still sends them.
@Suite struct DeleteTests {
    @Test func phoneCopiesOfCloudItemsAreFound() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try LocalStore.upsert([local("on-phone", hour: 1, checksum: "c1"), local("other", hour: 2, checksum: "c2")], in: db)
            try LocalStore.setChecksum("c1", source: .hashed, id: "on-phone", modifiedAt: Date(timeIntervalSince1970: 1), in: db)
            try LocalStore.setChecksum("c2", source: .hashed, id: "other", modifiedAt: Date(timeIntervalSince1970: 1), in: db)
            try RemoteStore.upsert([remote("r1", checksum: "c1"), remote("r-cloud-only", checksum: "c9")], in: db)
        }
        let copies = try database.reader.read { db in try LocalStore.phoneCopies(ofRemote: ["r1", "r-cloud-only"], in: db) }
        #expect(copies == ["on-phone"])
    }

    @Test func purgedAssetsStayGoneUntilTheServerDeletesThem() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try RemoteStore.upsert([remote("r1", checksum: "c1", deleted: true), remote("r2", checksum: "c2", deleted: true)], in: db)
            try RemoteStore.markPurged(ids: ["r1"], in: db)
            // The server still sends it as trashed (its job hasn't run yet).
            try RemoteStore.upsert([remote("r1", checksum: "c1", deleted: true)], in: db)
        }
        let trash = try database.reader.read { db in try TimelineQuery.remote(ownerID: "me", scope: .trash, in: db) }.map(\.id)
        #expect(trash == ["r2"])
        // Once the server reports it deleted, the mark goes too.
        try database.writer.write { db in try RemoteStore.deleteAssets(ids: ["r1"], in: db) }
        let marks = try database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM purgedAsset") }
        #expect(marks == 0)
    }

    @Test func hidingMarksThePhoneCopy() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try LocalStore.upsert([local("p", hour: 1)], in: db)
            try LocalStore.setHidden(true, ids: ["p"], in: db)
        }
        let items = try database.reader.read { db in try TimelineQuery.merged(ownerID: "me", in: db) }
        #expect(!items.contains { $0.id == "local:p" })
    }
}
