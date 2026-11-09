import Foundation
import GRDB
import Persistence
import Testing
@testable import Sync

/// Partner sharing: a partner's photos arrive under their own owner, show in the Library
/// only while "show in Library" is on, and go when the partner stops sharing.
@Suite struct PartnerSyncTests {
    static let me = Lines.owner
    static let partner = "22222222-2222-4222-8222-222222222222"

    static let authUser = """
        {"type":"AuthUserV2","ack":"AuthUserV2|1","data":{"id":"\(me)","name":"Me","email":"me@example.com","avatarColor":null,\
        "deletedAt":null,"hasProfileImage":false,"isAdmin":false,"oauthId":"","pinCode":null,"profileChangedAt":"2025-01-01T00:00:00Z",\
        "quotaSizeInBytes":null,"quotaUsageInBytes":0,"storageLabel":null}}
        """

    static func partnerLine(inTimeline: Bool, ack: String = "PartnerV1|1") -> String {
        #"{"type":"PartnerV1","ack":"\#(ack)","data":{"sharedById":"\#(partner)","sharedWithId":"\#(me)","inTimeline":\#(inTimeline)}}"#
    }

    static func partnerAsset(_ id: String, type: String = "PartnerAssetV2", checksum: String? = nil, visibility: String = "timeline") -> String {
        Lines.asset(id, ack: "\(type)|\(id)", visibility: visibility)
            .replacingOccurrences(of: #""type":"AssetV2""#, with: #""type":"\#(type)""#)
            .replacingOccurrences(of: Lines.owner, with: partner)
            .replacingOccurrences(of: "\"c-\(id)\"", with: "\"\(checksum ?? "c-\(id)")\"")
    }

    private func library(_ database: AppDatabase) async throws -> [String] {
        try await database.reader.read { db in try TimelineQuery.merged(ownerID: Self.me, in: db).map(\.id) }
    }

    @Test func partnerPhotosShowInTheLibraryOnlyWhenChosen() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([[
            Self.authUser,
            Self.partnerLine(inTimeline: false),
            Lines.asset("mine", ack: "AssetV2|1"),
            Self.partnerAsset("p1", type: "PartnerAssetBackfillV2"),
            Self.partnerAsset("p2"),
            Self.partnerAsset("p-hidden", visibility: "locked"),
            Self.partnerAsset("p-same", checksum: "c-mine"),
            Lines.complete,
        ]])
        _ = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")

        #expect(try await library(database) == ["mine"])
        let shared = try await database.reader.read { db in try PartnerQuery.sharedWith(Self.me, in: db) }
        #expect(shared.map(\.id) == [Self.partner])
        #expect(shared.first?.itemCount == 3) // p1, p2, p-same; never their hidden items

        try await database.writer.write { db in try PartnerQuery.setInTimeline(true, sharedBy: Self.partner, with: Self.me, in: db) }
        // Their hidden item stays out, and a photo both have is listed once, as mine.
        #expect(Set(try await library(database)) == ["mine", "p1", "p2"])
        let owners = try await database.reader.read { db in try TimelineQuery.merged(ownerID: Self.me, in: db).map(\.ownerID) }
        #expect(owners.filter { $0 == Self.partner }.count == 2)
    }

    @Test func stoppingSharingRemovesTheirPhotosButNeverMine() async throws {
        let database = try AppDatabase.inMemory()
        let api = FakeSyncAPI([
            [Self.authUser, Self.partnerLine(inTimeline: true), Lines.asset("mine", ack: "AssetV2|1"), Self.partnerAsset("p1"), Lines.complete],
            [
                // I stop sharing with them: my photos stay.
                #"{"type":"PartnerDeleteV1","ack":"PartnerDeleteV1|1","data":{"sharedById":"\#(Self.me)","sharedWithId":"\#(Self.partner)"}}"#,
                Lines.complete,
            ],
            [
                // They stop sharing with me: their photos go.
                #"{"type":"PartnerDeleteV1","ack":"PartnerDeleteV1|2","data":{"sharedById":"\#(Self.partner)","sharedWithId":"\#(Self.me)"}}"#,
                Lines.complete,
            ],
        ])
        let service = SyncService(database: database, api: api)
        _ = try await service.run(sessionFingerprint: "s1")
        #expect(Set(try await library(database)) == ["mine", "p1"])
        _ = try await service.run(sessionFingerprint: "s1")
        #expect(Set(try await library(database)) == ["mine", "p1"])
        _ = try await service.run(sessionFingerprint: "s1")
        #expect(try await library(database) == ["mine"])
        let rows = try await database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remoteAsset WHERE ownerId = ?", arguments: [Self.partner]) }
        #expect(rows == 0)
    }

    @Test func partnerDeletesAndExifApply() async throws {
        let database = try AppDatabase.inMemory()
        let exif = Lines.exif("p1", ack: "PartnerAssetExifV1|1").replacingOccurrences(of: #""type":"AssetExifV1""#, with: #""type":"PartnerAssetExifV1""#)
        let api = FakeSyncAPI([[
            Self.authUser, Self.partnerLine(inTimeline: true), Self.partnerAsset("p1"), Self.partnerAsset("p2"),
            #"{"type":"PartnerAssetDeleteV1","ack":"PartnerAssetDeleteV1|1","data":{"assetId":"p2"}}"#,
            exif, Lines.complete,
        ]])
        let report = try await SyncService(database: database, api: api).run(sessionFingerprint: "s1")
        #expect(report.undecodableSummary == nil)
        #expect(try await library(database) == ["p1"])
        let city = try await database.reader.read { db in try RemoteExifRecord.fetchOne(db, key: "p1")?.city }
        #expect(city == "Zürich")
        #expect(api.requestedTypes.first?.contains(.partnerAssetsV2) == true)
    }
}
