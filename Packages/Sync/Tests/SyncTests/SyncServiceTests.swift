import Foundation
import GRDB
import ImmichAPI
import OpenAPIRuntime
import Persistence
import Testing
@testable import Sync

/// A fake server: each `openStream` call returns the next scripted response.
final class FakeSyncAPI: SyncAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[String]]
    private(set) var acks: [[String]] = []
    private(set) var requestedTypes: [[Schemas.SyncRequestType]] = []
    private(set) var resetFlags: [Bool] = []

    init(_ responses: [[String]]) {
        self.responses = responses
    }

    func openStream(types: [Schemas.SyncRequestType], reset: Bool) async throws -> HTTPBody {
        let lines = lock.withLock {
            requestedTypes.append(types)
            resetFlags.append(reset)
            return responses.isEmpty ? [] : responses.removeFirst()
        }
        return HTTPBody(lines.map { $0 + "\n" }.joined())
    }

    func ack(_ acks: [String]) async throws {
        lock.withLock { self.acks.append(acks) }
    }

    private(set) var resent: [[Schemas.SyncEntityType]] = []

    func resend(_ types: [Schemas.SyncEntityType]) async throws {
        lock.withLock { resent.append(types) }
    }

    var allAcks: [String] { lock.withLock { acks.flatMap { $0 } } }
}

enum Lines {
    static let owner = "11111111-1111-4111-8111-111111111111"

    static func asset(_ id: String, ack: String, date: String = "2025-06-01T10:00:00.000Z", visibility: String = "timeline", deleted: Bool = false) -> String {
        """
        {"type":"AssetV2","ack":"\(ack)","data":{"id":"\(id)","ownerId":"\(owner)","checksum":"c-\(id)","type":"IMAGE",\
        "originalFileName":"IMG_\(id).HEIC","fileCreatedAt":"\(date)","fileModifiedAt":"\(date)","localDateTime":"\(date)",\
        "createdAt":"2025-06-02T00:00:00Z","deletedAt":\(deleted ? "\"2025-07-01T00:00:00.000Z\"" : "null"),"duration":null,\
        "width":4032,"height":3024,"isFavorite":false,"isEdited":false,"visibility":"\(visibility)","livePhotoVideoId":null,\
        "stackId":null,"libraryId":null,"thumbhash":"1QcSHQRnh493V4dIh4eXh1h4kJUI"}}
        """
    }

    static func assetDelete(_ id: String, ack: String) -> String {
        #"{"type":"AssetDeleteV1","ack":"\#(ack)","data":{"assetId":"\#(id)"}}"#
    }

    static func exif(_ id: String, ack: String) -> String {
        """
        {"type":"AssetExifV1","ack":"\(ack)","data":{"assetId":"\(id)","city":"Zürich","country":"Switzerland","state":null,\
        "dateTimeOriginal":"2025-06-01T10:00:00+00:00","description":"","exifImageHeight":3024,"exifImageWidth":4032,\
        "exposureTime":"1/120","fNumber":1.8,"fileSizeInByte":2345678,"focalLength":5.1,"fps":null,"iso":50,"latitude":47.37,\
        "lensModel":"iPhone 12 Pro Max back camera","longitude":8.54,"make":"Canon","model":"iPhone 12 Pro Max","modifyDate":null,\
        "orientation":"1","profileDescription":"Display P3","projectionType":null,"rating":null,"timeZone":"Europe/Zurich"}}
        """
    }

    static func cloudId(_ id: String, ack: String) -> String {
        """
        {"type":"AssetMetadataV1","ack":"\(ack)","data":{"assetId":"\(id)","key":"mobile-app","value":{"iCloudId":"CLOUD-\(id)",\
        "createdAt":"2025-06-01T10:00:00.000Z","adjustmentTime":null,"latitude":"47.37","longitude":"8.54"}}}
        """
    }

    static let reset = #"{"type":"SyncResetV1","ack":"SyncResetV1|reset","data":{}}"#
    static let complete = #"{"type":"SyncCompleteV1","ack":"SyncCompleteV1|0190","data":{}}"#
}

private func remoteIDs(_ database: AppDatabase) throws -> [String] {
    try database.reader.read { db in try String.fetchAll(db, sql: "SELECT id FROM remoteAsset ORDER BY id") }
}

@Suite struct SyncServiceTests {
    @Test func appliesAssetsExifAndMetadataAndAcksEachRun() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([[
            Lines.asset("a1", ack: "AssetV2|1"),
            Lines.asset("a2", ack: "AssetV2|2"),
            Lines.exif("a1", ack: "AssetExifV1|1"),
            Lines.cloudId("a1", ack: "AssetMetadataV1|1"),
            Lines.complete,
        ]])
        let report = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")

        #expect(report.eventsApplied == 4) // the completion marker isn't a data event
        #expect(api.allAcks == ["AssetV2|2", "AssetExifV1|1", "AssetMetadataV1|1", "SyncCompleteV1|0190"])
        #expect(try remoteIDs(database) == ["a1", "a2"])

        let exif = try await database.reader.read { db in try RemoteExifRecord.fetchOne(db, key: "a1") }
        #expect(exif?.city == "Zürich")
        #expect(exif?.fileSizeInByte == 2_345_678)
        let cloud = try await database.reader.read { db in try RemoteAssetCloudIdRecord.fetchOne(db, key: "a1") }
        #expect(cloud?.cloudId == "CLOUD-a1")
        #expect(cloud?.adjustmentTime == nil)
    }

    @Test func splitsLargeRunsIntoBatches() async throws {
        let database = try AppDatabase.inMemory()
        let lines = (0..<25).map { Lines.asset("a\($0)", ack: "AssetV2|\($0)") }
        let api = FakeSyncAPI([lines])
        _ = try await SyncService(database: database, api: api, batchSize: 10).run(sessionFingerprint: "s1")
        #expect(api.allAcks == ["AssetV2|9", "AssetV2|19", "AssetV2|24"])
        #expect(try remoteIDs(database).count == 25)
    }

    @Test func deletesAssetsAndTheirExif() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([
            [Lines.asset("a1", ack: "AssetV2|1"), Lines.exif("a1", ack: "AssetExifV1|1")],
            [Lines.assetDelete("a1", ack: "AssetDeleteV1|1")],
        ])
        let service = SyncService(database: database, api: api)
        _ = try await service.run(sessionFingerprint: "s1")
        _ = try await service.run(sessionFingerprint: "s1")
        #expect(try remoteIDs(database).isEmpty)
        let exifCount = try await database.reader.read { db in try RemoteExifRecord.fetchCount(db) }
        #expect(exifCount == 0)
    }

    @Test func resetClearsDataAndStreamsAgain() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([
            [Lines.asset("old", ack: "AssetV2|1")],
            [Lines.reset],
            [Lines.asset("new", ack: "AssetV2|9"), Lines.complete],
        ])
        let service = SyncService(database: database, api: api)
        _ = try await service.run(sessionFingerprint: "s1")
        let report = try await service.run(sessionFingerprint: "s1")

        #expect(report.resets == 1)
        #expect(try remoteIDs(database) == ["new"])
        #expect(api.allAcks.contains("SyncResetV1|reset"))
    }

    @Test func newSessionStartsFromAnEmptyDatabase() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([
            [Lines.asset("a1", ack: "AssetV2|1")],
            [Lines.asset("a2", ack: "AssetV2|1")],
        ])
        let service = SyncService(database: database, api: api)
        _ = try await service.run(sessionFingerprint: "s1")
        _ = try await service.run(sessionFingerprint: "s2")
        #expect(try remoteIDs(database) == ["a2"])
    }

    @Test func undecodablePayloadIsSkippedButAcked() async throws {
        let database = try AppDatabase.inMemory()
        let broken = Lines.asset("bad", ack: "AssetV2|1").replacingOccurrences(of: "\"visibility\":\"timeline\"", with: "\"visibility\":\"someFutureValue\"")
        let api = FakeSyncAPI([[broken, Lines.exif("x", ack: "AssetExifV1|1")]])
        let report = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        #expect(report.skipped == 1)
        #expect(api.allAcks == ["AssetV2|1", "AssetExifV1|1"])
        #expect(try remoteIDs(database).isEmpty)
    }

    @Test func readableLinesAfterAnUnreadableOneAreStillApplied() async throws {
        let database = try AppDatabase.inMemory()
        let broken = Lines.asset("bad", ack: "AssetV2|1").replacingOccurrences(of: "\"visibility\":\"timeline\"", with: "\"visibility\":\"someFutureValue\"")
        let api = FakeSyncAPI([[broken, Lines.asset("good1", ack: "AssetV2|2"), Lines.asset("good2", ack: "AssetV2|3")]])
        let report = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        #expect(try remoteIDs(database) == ["good1", "good2"])
        #expect(report.eventsApplied == 2)
        #expect(report.undecodable["AssetV2"]?.count == 1)
        #expect(api.allAcks == ["AssetV2|3"])
    }

    @Test func unreadableLinesInTheMiddleAreCountedNotApplied() async throws {
        let database = try AppDatabase.inMemory()
        let broken = Lines.asset("bad", ack: "AssetV2|2").replacingOccurrences(of: "\"type\":\"IMAGE\"", with: "\"type\":\"HOLOGRAM\"")
        let api = FakeSyncAPI([[Lines.asset("a", ack: "AssetV2|1"), broken, Lines.asset("b", ack: "AssetV2|3")]])
        let report = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        #expect(try remoteIDs(database) == ["a", "b"])
        #expect(report.eventsApplied == 2)
        #expect(report.undecodableSummary?.hasPrefix("AssetV2: 1 (") == true)
        let stored = try await database.reader.read { db in try SyncState.value(.lastSkipped, in: db) }
        #expect(stored == report.undecodableSummary)
    }

    @Test func unknownTypesAreAckedAndIgnored() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([[#"{"type":"SomethingNewV9","ack":"SomethingNewV9|1","data":{"x":1}}"#]])
        let report = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        #expect(report.skipped == 1)
        #expect(api.allAcks == ["SomethingNewV9|1"])
    }

    @Test func malformedLineFailsWithReadableError() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([["not json"]])
        await #expect(throws: APIError.self) {
            _ = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        }
    }

    @Test func fromScratchClearsLocalDataAndAsksServerToReset() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([
            [Lines.asset("kept-by-mistake", ack: "AssetV2|1")],
            [Lines.asset("a1", ack: "AssetV2|1"), Lines.complete],
        ])
        let service = SyncService(database: database, api: api)
        _ = try await service.run(sessionFingerprint: "s1")
        _ = try await service.run(sessionFingerprint: "s1", fromScratch: true)
        #expect(try remoteIDs(database) == ["a1"])
        #expect(api.resetFlags == [false, true])
    }

    @Test func requestsTheConfiguredTypes() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([[]])
        _ = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        #expect(api.requestedTypes.first == SyncRequestTypes.current)
    }

    @Test func timelineQueryShowsOnlyVisibleUntrashedOwnedAssets() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([[
            Lines.asset("newer", ack: "AssetV2|1", date: "2025-06-02T10:00:00.000Z"),
            Lines.asset("older", ack: "AssetV2|2", date: "2025-06-01T10:00:00.000Z"),
            Lines.asset("archived", ack: "AssetV2|3", visibility: "archive"),
            Lines.asset("trashed", ack: "AssetV2|4", deleted: true),
        ]])
        _ = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        let items = try await database.reader.read { db in try TimelineQuery.remote(ownerID: Lines.owner, in: db) }
        #expect(items.map(\.id) == ["older", "newer"])
        #expect(abs(items[1].aspectRatio - 4032.0 / 3024.0) < 0.0001)
    }

    @Test func asksOnceForMetadataToBeResent() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([[], []])
        let service = SyncService(database: database, api: api)
        _ = try await service.run(sessionFingerprint: "s")
        _ = try await service.run(sessionFingerprint: "s")
        #expect(api.resent == [[.assetMetadataV1]])
    }
}
