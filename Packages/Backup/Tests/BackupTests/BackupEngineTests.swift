import CloudCore
import Foundation
import Library
import Persistence
import Testing
@testable import Backup

// MARK: Fakes

private final class FakeExporter: AssetExporter, @unchecked Sendable {
    let lock = NSLock()
    var exports: [String] = []

    func describe(localID: String, part: UploadPart) async throws -> ExportInfo {
        ExportInfo(fileName: "\(localID).\(part == .motion ? "MOV" : "HEIC")", createdAt: .now, modifiedAt: .now,
                   isFavorite: false, durationSeconds: 0, origin: nil)
    }

    func stream(localID: String, part: UploadPart, allowNetwork: Bool, to sink: @escaping @Sendable (Data) throws -> Void) async throws {
        lock.withLock { exports.append("\(localID)/\(part.rawValue)") }
        // Several chunks, like PhotoKit delivers them.
        for piece in ["bytes of ", localID, " ", part.rawValue] { try sink(Data(piece.utf8)) }
    }
}

private final class FakeSession: UploadSession, @unchecked Sendable {
    let lock = NSLock()
    var started: [(description: String, request: URLRequest, body: Data)] = []
    var active: Set<String> = []

    func start(_ request: URLRequest, bodyFile: URL, description: String) async -> Int {
        let body = (try? Data(contentsOf: bodyFile)) ?? Data()
        return lock.withLock {
            started.append((description, request, body))
            active.insert(description)
            return started.count
        }
    }

    func activeDescriptions() async -> Set<String> { lock.withLock { active } }
    func cancelAll() async {}
    func complete(_ description: String) { lock.withLock { _ = active.remove(description) } }
}

/// Puts the item's fields (as JSON) before the file bytes so tests can inspect what would be sent.
private struct FakeTransport: CloudBackupTransport {
    func uploadBody(for item: CloudBackupItem) throws -> CloudUploadBody {
        let fields: [String: String] = [
            "fileName": item.fileName, "live": item.livePhotoVideoID ?? "", "visibility": item.visibility?.rawValue ?? "",
        ]
        return CloudUploadBody(prefix: try JSONSerialization.data(withJSONObject: fields) + Data("\n".utf8), suffix: Data(), contentType: "test")
    }

    func uploadRequest(for item: CloudBackupItem, body: CloudUploadBody) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cloud.test/upload")!)
        request.setValue(item.checksum, forHTTPHeaderField: "x-checksum")
        return request
    }

    func uploadResult(statusCode: Int, body: Data) -> Result<CloudUploadResult, CloudError> {
        Self.parse(statusCode, body)
    }

    static func parse(_ status: Int, _ body: Data) -> Result<CloudUploadResult, CloudError> {
        switch status {
        case 200, 201: .success(CloudUploadResult(assetID: String(decoding: body, as: UTF8.self), created: status == 201))
        case 401: .failure(CloudError(kind: .unauthorized, message: "sign in"))
        default: .failure(CloudError(kind: .http(status: status), message: "status \(status)"))
        }
    }
}

private final class FakeConnection: CloudConnection, @unchecked Sendable {
    let server = ActiveServer(route: .local, url: URL(string: "https://cloud.test")!)
    var media: MediaSource { MediaSource(identity: "x", image: { _, _ in URLRequest(url: URL(string: "x:")!) }, original: { _ in URLRequest(url: URL(string: "x:")!) }, video: { _ in (URL(string: "x:")!, [:]) }) }
    let lock = NSLock()
    /// Checksums the server already has → asset id.
    var existing: [String: String] = [:]
    var stacks: [[String]] = []
    var backup: any CloudBackupTransport { FakeTransport() }

    func existingAssets(_ items: [(itemID: String, checksum: String)]) async throws -> [CloudExistingAsset] {
        lock.withLock { items.map { CloudExistingAsset(itemID: $0.itemID, assetID: existing[$0.checksum], isTrashed: false) } }
    }
    func stack(assetIDs: [String]) async throws { lock.withLock { stacks.append(assetIDs) } }

    private func unused() -> CloudError { CloudError(kind: .transport, message: "not used in tests") }
    func syncLibrary(into database: AppDatabase, sessionFingerprint: String, fromScratch: Bool, progress: @escaping @Sendable (Int) -> Void) async throws { throw unused() }
    func libraryCounts() async throws -> CloudLibraryCounts { throw unused() }
    func setFavorite(_ isFavorite: Bool, assetIDs: [String]) async throws { throw unused() }
    func setArchived(_ archived: Bool, assetIDs: [String]) async throws { throw unused() }
    func setLocked(_ locked: Bool, assetIDs: [String]) async throws { throw unused() }
    func moveToTrash(assetIDs: [String]) async throws { throw unused() }
    func restoreFromTrash(assetIDs: [String]) async throws { throw unused() }
    func deletePermanently(assetIDs: [String]) async throws { throw unused() }
    func setDateTimeOriginal(_ iso8601: String, assetIDs: [String]) async throws { throw unused() }
    func setLocation(latitude: Double, longitude: Double, assetIDs: [String]) async throws { throw unused() }
    func setDescription(_ text: String, assetID: String) async throws { throw unused() }
    func albums(shared: Bool) async throws -> [CloudAlbum] { throw unused() }
    func albums(containing assetID: String) async throws -> [CloudAlbum] { throw unused() }
    func createAlbum(name: String, assetIDs: [String], sharedWith userIDs: [String]) async throws -> CloudAlbum { throw unused() }
    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws { throw unused() }
    func memories() async throws -> [CloudMemory] { throw unused() }
    func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws -> (removed: [String], refused: Int) { throw unused() }
    func otherUsers() async throws -> [CloudUser] { throw unused() }
    func startSharingLibrary(with userID: String) async throws { throw unused() }
    func stopSharingLibrary(with userID: String) async throws { throw unused() }
    func showSharedLibraryInLibrary(_ shown: Bool, partnerID: String) async throws { throw unused() }
    func search(_ query: CloudSearchQuery, limit: Int) async throws -> [CloudAsset] { throw unused() }
    func createSharedLink(assetIDs: [String], expiresAt: Date?) async throws -> CloudSharedLink { throw unused() }
    func deleteSharedLink(id: String) async throws { throw unused() }
    func temporaryPublicVideoURL(assetID: String, expiresAt: Date) async throws -> CloudSharedLink { throw unused() }
    func lockedFolderStatus() async throws -> CloudLockedFolderStatus { throw unused() }
    func setUpLockedFolder(pin: String) async throws { throw unused() }
    func unlockLockedFolder(pin: String) async throws { throw unused() }
    func lockLockedFolder() async throws { throw unused() }
    func upload(_ file: CloudUploadFile) async throws -> CloudUploadResult { throw unused() }
    func profileImageRequest(userID: String) -> URLRequest { URLRequest(url: URL(string: "x:")!) }
    func setProfileImage(jpeg: Data) async throws { throw unused() }
    func people() async throws -> [CloudPerson] { throw unused() }
    func people(inAsset assetID: String) async throws -> [CloudPerson] { throw unused() }
    func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson { throw unused() }
    func personThumbnailRequest(personID: String) -> URLRequest { URLRequest(url: URL(string: "x:")!) }
    func smartSearch(_ text: String, limit: Int) async throws -> [CloudAsset] { throw unused() }
    func trashRetentionDays() async throws -> Int { throw unused() }
}

private struct Harness {
    let database: AppDatabase
    let exporter = FakeExporter()
    let session = FakeSession()
    let connection = FakeConnection()
    let folder = FileManager.default.temporaryDirectory.appending(path: "backup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let engine: BackupEngine
    let suite = "backup-tests-\(UUID().uuidString)"
    let crashMarkers: UserDefaults

    init(settings: BackupSettings = { var s = BackupSettings(); s.isEnabled = true; return s }(),
         conditions: BackupConditions = BackupConditions(isOnline: true, isExpensiveNetwork: false, isCharging: true)) throws {
        database = try AppDatabase.inMemory()
        let connection = connection
        engine = BackupEngine(
            database: database, ownerID: "me", exporter: exporter, session: session, folder: folder, deviceID: "device",
            connection: { connection }, parse: FakeTransport.parse, conditions: { conditions }, scope: { nil },
            settings: { settings }, onStatus: { _ in }, crashMarkerSuite: suite
        )
        crashMarkers = UserDefaults(suiteName: suite)!
    }

    func addPhotos(_ ids: [String], live: Set<String> = []) throws {
        try database.writer.write { db in
            try LocalStore.upsert(ids.enumerated().map { index, id in
                LocalAssetRecord(id: id, mediaType: 1, subtypes: live.contains(id) ? LocalAssetRecord.livePhotoSubtype : 0,
                                 createdAt: Date(timeIntervalSince1970: Double(index)), localDateTime: Date(timeIntervalSince1970: Double(index)),
                                 modifiedAt: Date(timeIntervalSince1970: 1), width: 1, height: 1)
            }, in: db)
        }
    }

    func task(_ localID: String, _ part: String = "single") throws -> UploadTaskRecord? {
        try database.reader.read { db in
            try UploadTaskRecord.fetchOne(db, sql: "SELECT * FROM uploadTask WHERE localId = ? AND part = ?", arguments: [localID, part])
        }
    }

    func checksum(_ localID: String, _ part: String) -> String {
        var hasher = ChecksumHasher()
        hasher.update(Data("bytes of \(localID) \(part)".utf8))
        return hasher.finalize()
    }
}

/// The JSON fields line at the start of a fake upload body.
private func fields(_ body: Data) -> [String: String]? {
    guard let line = body.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String]
}

// MARK: Tests

@Suite struct BackupEngineTests {
    @Test func uploadsANewPhotoAndCleansUp() async throws {
        let h = try Harness()
        try h.addPhotos(["A"])
        await h.engine.run()
        #expect(h.session.started.count == 1)
        // The checksum is that of the file bytes (streamed in chunks), not of the whole body.
        #expect(h.session.started[0].request.value(forHTTPHeaderField: "x-checksum") == h.checksum("A", "single"))
        #expect(try h.task("A")?.state == .uploading)

        h.session.complete("upload:1")
        await h.engine.handle(.finished(description: "upload:1", statusCode: 201, body: Data("remote-A".utf8), error: nil))
        let task = try #require(try h.task("A"))
        #expect(task.state == .done && task.remoteId == "remote-A")
        // The checksum is recorded for the phone photo, and no temp files are left.
        #expect(try await h.database.reader.read { db in try LocalStore.record(id: "A", in: db)?.checksum } == h.checksum("A", "single"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.folder.path)) ?? []).isEmpty)
    }

    @Test func skipsWhatTheServerAlreadyHas() async throws {
        let h = try Harness()
        try h.addPhotos(["A"])
        h.connection.existing[h.checksum("A", "single")] = "remote-existing"
        await h.engine.run()
        #expect(h.session.started.isEmpty)
        #expect(try h.task("A")?.state == .done)
        #expect(try h.task("A")?.remoteId == "remote-existing")
    }

    @Test func neverStartsTheSameFileTwice() async throws {
        let h = try Harness()
        try h.addPhotos(["A", "B", "C"])
        await h.engine.run()
        await h.engine.run()
        await h.engine.run()
        // Two at a time (gentle on the server); each file started exactly once.
        let descriptions = h.session.started.map(\.description)
        #expect(descriptions.count == 2)
        #expect(Set(descriptions).count == descriptions.count)
        h.session.complete(descriptions[0])
        await h.engine.handle(.finished(description: descriptions[0], statusCode: 201, body: Data("r1".utf8), error: nil))
        #expect(h.session.started.count == 3)
        #expect(Set(h.session.started.map(\.description)).count == 3)
    }

    @Test func livePhotoSendsMotionFirstThenLinksTheStill() async throws {
        let h = try Harness()
        try h.addPhotos(["L"], live: ["L"])
        await h.engine.run()
        #expect(h.session.started.count == 1)
        let motion = fields(h.session.started[0].body)
        #expect(motion?["visibility"] == "hidden")
        #expect(motion?["fileName"] == "L.MOV")
        let motionTask = try #require(try h.task("L", "motion"))
        let description = "upload:\(motionTask.id!)"
        h.session.complete(description)
        await h.engine.handle(.finished(description: description, statusCode: 201, body: Data("remote-motion".utf8), error: nil))
        #expect(h.session.started.count == 2)
        let still = fields(h.session.started[1].body)
        #expect(still?["live"] == "remote-motion")
        #expect(still?["visibility"] == "")
    }

    @Test func serverErrorsRetryAndBadRequestsStop() async throws {
        let h = try Harness()
        try h.addPhotos(["A", "B"])
        await h.engine.run()
        let a = "upload:\(try #require(try h.task("A")?.id))", b = "upload:\(try #require(try h.task("B")?.id))"
        await h.engine.handle(.finished(description: a, statusCode: 503, body: Data(), error: nil))
        let retried = try #require(try h.task("A"))
        #expect(retried.state == .waiting && retried.nextAttemptAt! > .now && retried.lastError == "status 503")
        await h.engine.handle(.finished(description: b, statusCode: 400, body: Data(), error: nil))
        #expect(try h.task("B")?.state == .failed)
    }

    @Test func networkErrorsRetryWithBackoff() async throws {
        let h = try Harness()
        try h.addPhotos(["A"])
        await h.engine.run()
        await h.engine.handle(.finished(description: "upload:1", statusCode: nil, body: Data(), error: URLError(.networkConnectionLost)))
        let task = try #require(try h.task("A"))
        #expect(task.state == .waiting)
        #expect(task.lastError?.contains("connection dropped") == true)
    }

    @Test func relaunchRequeuesLostUploadsAndDeletesOrphans() async throws {
        let h = try Harness()
        try h.addPhotos(["A"])
        await h.engine.run()
        // The system lost the upload (e.g. the phone restarted) and a stray file is left.
        h.session.complete("upload:1")
        try Data("stray".utf8).write(to: h.folder.appending(path: "export-orphan"))
        await h.engine.reconcile()
        #expect(try h.task("A")?.state == .pending)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.folder.path)) ?? []).isEmpty)
    }

    @Test func respectsSettingsAndConditions() async throws {
        let off = try Harness(settings: BackupSettings())
        try off.addPhotos(["A"])
        await off.engine.run()
        #expect(off.session.started.isEmpty)

        var settings = BackupSettings()
        settings.isEnabled = true
        let cellular = try Harness(settings: settings, conditions: BackupConditions(isOnline: true, isExpensiveNetwork: true, isCharging: true))
        try cellular.addPhotos(["A"])
        await cellular.engine.run()
        #expect(cellular.session.started.isEmpty)
        #expect(await cellular.engine.currentStatus().activity == .waitingForWiFi)

        settings.onlyWhileCharging = true
        let battery = try Harness(settings: settings, conditions: BackupConditions(isOnline: true, isExpensiveNetwork: false, isCharging: false))
        try battery.addPhotos(["A"])
        await battery.engine.run()
        #expect(battery.session.started.isEmpty)
    }

    @Test func editedPhotoIsStackedWithItsEarlierUpload() async throws {
        let h = try Harness()
        try h.addPhotos(["A"])
        await h.engine.run()
        await h.engine.handle(.finished(description: "upload:1", statusCode: 201, body: Data("remote-v1".utf8), error: nil))
        // Edited on the phone: new modification date, new file.
        try await h.database.writer.write { db in
            try LocalStore.upsert([LocalAssetRecord(id: "A", mediaType: 1, createdAt: .now, localDateTime: .now, modifiedAt: Date(timeIntervalSince1970: 50), width: 1, height: 1)], in: db)
        }
        h.session.complete("upload:1")
        await h.engine.run()
        await h.engine.handle(.finished(description: "upload:1", statusCode: 201, body: Data("remote-v2".utf8), error: nil))
        #expect(h.connection.stacks == [["remote-v2", "remote-v1"]])
    }

    @Test func backoffGrowsAndIsCapped() {
        #expect(Backoff.delay(afterAttempt: 1, jitter: 0) == 30)
        #expect(Backoff.delay(afterAttempt: 3, jitter: 0) == 120)
        #expect(Backoff.delay(afterAttempt: 30, jitter: 0) == 6 * 3600)
    }

    @Test func uploadNamesUseTheAssetsOwnName() {
        #expect(PhotoKitExporter.uploadName(base: "IMG_1234.HEIC", uploaded: "FullSizeRender.mov") == "IMG_1234.mov")
        #expect(PhotoKitExporter.uploadName(base: "IMG_1234.HEIC", uploaded: "FullSizeRender.heic") == "IMG_1234.heic")
        #expect(PhotoKitExporter.uploadName(base: "IMG_5678.MOV", uploaded: "IMG_5678.MOV") == "IMG_5678.MOV")
    }

    @Test func aCrashWhilePreparingCannotLoopForever() async throws {
        let h = try Harness()
        try h.addPhotos(["Huge"])
        try await h.database.writer.write { db in
            _ = try BackupStore.enqueue([("Huge", Date(timeIntervalSince1970: 1), false)], in: db)
        }
        let id = try #require(try h.task("Huge")?.id)
        // Three launches that each died while this file was being prepared.
        for attempt in 1...3 {
            h.crashMarkers.set(Int(id), forKey: "backup.preparing.me")
            await h.engine.reconcile()
            let task = try #require(try h.task("Huge"))
            #expect(task.state == (attempt < 3 ? .waiting : .failed))
            #expect(h.crashMarkers.object(forKey: "backup.preparing.me") == nil)
            if attempt < 3 {
                try await h.database.writer.write { db in try db.execute(sql: "UPDATE uploadTask SET state = 'pending' WHERE id = ?", arguments: [id]) }
            }
        }
    }
}
