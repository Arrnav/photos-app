import CloudCore
import Core
import Foundation
import GRDB
import Library
import Persistence

/// What the device allows right now.
public struct BackupConditions: Sendable, Equatable {
    public var isOnline: Bool
    /// Mobile data or a hotspot.
    public var isExpensiveNetwork: Bool
    public var isCharging: Bool

    public init(isOnline: Bool, isExpensiveNetwork: Bool, isCharging: Bool) {
        self.isOnline = isOnline
        self.isExpensiveNetwork = isExpensiveNetwork
        self.isCharging = isCharging
    }
}

/// What Settings › Backup shows.
public struct BackupStatus: Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case off, paused, idle, working
        case waitingForWiFi, waitingForPower, offline, needsSignIn
    }

    public var activity: Activity = .off
    public var counts = BackupCounts()
    public var currentFileName: String?
    public var currentProgress: Double?
    /// Readable problems, newest first ("IMG_0001.HEIC: The server refused the upload (413).").
    public var problems: [String] = []

    public init() {}
}

/// The backup queue. Photos in the backup's albums that Cloud doesn't have are
/// exported to a file, hashed (that file *is* what gets uploaded, so checksum and bytes always
/// agree), checked against Cloud, and uploaded on a background session.
///
/// Never twice: one queue row per file; Cloud's records and a server check run right before
/// each upload; and the upload carries its checksum, so if Cloud got it some other way the
/// server answers "duplicate" before reading the body.
public actor BackupEngine {
    public typealias ConnectionProvider = @Sendable () async -> (any CloudConnection)?
    public typealias ResultParser = @Sendable (Int, Data) -> Result<CloudUploadResult, CloudError>

    private let database: AppDatabase
    private let ownerID: String
    private let exporter: any AssetExporter
    private let session: any UploadSession
    private let folder: URL
    private let deviceID: String
    private let connection: ConnectionProvider
    private let parse: ResultParser
    private let conditions: @Sendable () async -> BackupConditions
    private let scope: @Sendable () async -> Set<String>?
    private let settings: @Sendable () -> BackupSettings
    private let onStatus: @Sendable (BackupStatus) -> Void
    /// Where the "preparing this file" marker survives a crash (UserDefaults in the app).
    private nonisolated(unsafe) let crashMarkers: UserDefaults
    private let maxInFlight = 2
    private let lookahead = 4

    private var running = false
    private var runAgain = false
    private var preparing: Set<Int64> = []
    private var status = BackupStatus()
    private var lastPublish = ContinuousClock.now
    private var needsSignIn = false

    public init(
        database: AppDatabase, ownerID: String, exporter: any AssetExporter, session: any UploadSession, folder: URL, deviceID: String,
        connection: @escaping ConnectionProvider, parse: @escaping ResultParser,
        conditions: @escaping @Sendable () async -> BackupConditions, scope: @escaping @Sendable () async -> Set<String>?,
        settings: @escaping @Sendable () -> BackupSettings, onStatus: @escaping @Sendable (BackupStatus) -> Void,
        crashMarkerSuite: String? = nil
    ) {
        crashMarkers = crashMarkerSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.database = database
        self.ownerID = ownerID
        self.exporter = exporter
        self.session = session
        self.folder = folder
        self.deviceID = deviceID
        self.connection = connection
        self.parse = parse
        self.conditions = conditions
        self.scope = scope
        self.settings = settings
        self.onStatus = onStatus
    }

    // MARK: Running

    /// Brings the queue up to date and starts uploads while conditions allow. Calls coalesce.
    public func run() async {
        if running {
            runAgain = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            runAgain = false
            await pump()
        } while runAgain
        await publish(force: true)
    }

    private func pump() async {
        let settings = settings()
        guard settings.isEnabled else { return setActivity(.off) }
        guard !settings.isPaused else { return setActivity(.paused) }
        guard !needsSignIn else { return setActivity(.needsSignIn) }
        let conditions = await conditions()
        guard conditions.isOnline else { return setActivity(.offline) }
        if conditions.isExpensiveNetwork && !settings.allowsMobileData { return setActivity(.waitingForWiFi) }
        if settings.onlyWhileCharging && !conditions.isCharging { return setActivity(.waitingForPower) }
        guard let connection = await connection() else { return setActivity(.offline) }
        setActivity(.working)

        do {
            try await enqueueCandidates()
            try await markKnownOnServer(connection)
            while !Task.isCancelled {
                let (inFlight, onDisk) = try await database.reader.read { db in
                    (try BackupStore.inFlight(in: db).count, try BackupStore.bytesOnDisk(in: db))
                }
                guard inFlight + preparing.count < maxInFlight else { break }
                // One item bigger than the whole budget is still prepared on its own.
                guard onDisk < settings.tempBudgetBytes || inFlight == 0 else { break }
                let busy = preparing
                let due = try await database.reader.read { db in
                    try BackupStore.nextDue(limit: self.lookahead + busy.count, in: db)
                }
                guard let task = due.first(where: { !busy.contains($0.id ?? -1) }), let id = task.id else { break }
                preparing.insert(id)
                await prepareAndStart(task, connection: connection, settings: settings, conditions: conditions)
                preparing.remove(id)
            }
        } catch {
            Log.backup.error("Backup run failed: \(String(describing: error), privacy: .public)")
        }
        if status.activity == .working, (try? await database.reader.read({ db in try BackupStore.inFlight(in: db).isEmpty })) == true {
            setActivity(.idle)
        }
    }

    private func setActivity(_ activity: BackupStatus.Activity) {
        status.activity = activity
    }

    /// Queues photos in scope that Cloud doesn't have yet.
    private func enqueueCandidates() async throws {
        let scope = await scope()
        let ownerID = ownerID
        let added = try await database.writer.write { db in
            try BackupStore.enqueue(try BackupStore.candidates(ownerID: ownerID, scope: scope, in: db), in: db)
        }
        if added > 0 { Log.backup.info("Queued \(added) files for backup") }
    }

    /// One server check for every queued photo whose checksum is already known (catches
    /// uploads by other apps since the last sync) (docs/DESIGN.md D6).
    private func markKnownOnServer(_ connection: any CloudConnection) async throws {
        let rows = try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.id, l.checksum FROM uploadTask u JOIN localAsset l ON l.id = u.localId
                WHERE u.state IN ('pending', 'waiting') AND u.part != 'motion' AND l.checksum IS NOT NULL
                """).map { (String($0["id"] as Int64), $0["checksum"] as String) }
        }
        guard !rows.isEmpty else { return }
        let existing = try await connection.existingAssets(rows.map { (itemID: $0.0, checksum: $0.1) })
        for found in existing where found.exists {
            guard let id = Int64(found.itemID), let task = try await database.reader.read({ db in try BackupStore.task(id: id, in: db) }) else { continue }
            try await finish(task, remoteID: found.assetID, note: "already in Cloud")
            if task.part == .still {
                // The motion part isn't needed either.
                try await database.writer.write { db in
                    try db.execute(sql: "UPDATE uploadTask SET state = 'done', finishedAt = ? WHERE localId = ? AND part = 'motion' AND state != 'done'", arguments: [Date.now, task.localId])
                }
            }
        }
    }

    // MARK: One file

    private func prepareAndStart(_ task: UploadTaskRecord, connection: any CloudConnection, settings: BackupSettings, conditions: BackupConditions) async {
        var task = task
        guard let id = task.id else { return }
        let part = UploadPart(rawValue: task.part.rawValue) ?? .single
        let allowNetwork = settings.downloadsFromICloud && (!settings.iCloudDownloadsOnWiFiOnly || !conditions.isExpensiveNetwork)
        let bodyURL = folder.appending(path: "body-\(id)")
        var started = false
        // If the app dies while this file is prepared, the next launch knows which file it was.
        markPreparing(id)
        defer {
            clearPreparing()
            if !started { try? FileManager.default.removeItem(at: bodyURL) }
        }
        do {
            status.currentFileName = nil
            let info = try await exporter.describe(localID: task.localId, part: part)
            status.currentFileName = part == .motion ? String(localized: "\(info.fileName) (Live Photo video)") : info.fileName
            await publish(force: true)
            let localID = task.localId, version = task.assetModifiedAt
            let motionID = part == .still ? try await database.reader.read { db in try BackupStore.motionRemoteId(localID: localID, in: db) } : nil
            var item = CloudBackupItem(
                fileName: info.fileName, createdAt: info.createdAt, modifiedAt: info.modifiedAt, isFavorite: info.isFavorite,
                durationSeconds: part == .motion ? nil : info.durationSeconds, livePhotoVideoID: motionID,
                visibility: part == .motion ? .hidden : nil, checksum: "", deviceAssetID: task.localId, deviceID: deviceID,
                origin: part == .motion ? nil : info.origin
            )
            // One pass: the photo streams from the library straight into the upload body and
            // through SHA-1, so the checksum is exactly that of the uploaded bytes.
            let body = try connection.backup.uploadBody(for: item)
            let writer = try BodyWriter(url: bodyURL)
            try writer.write(body.prefix, hash: false)
            do {
                try await exporter.stream(localID: task.localId, part: part, allowNetwork: allowNetwork) { chunk in
                    try writer.write(chunk, hash: true)
                }
            } catch {
                writer.close()
                throw error
            }
            try writer.write(body.suffix, hash: false)
            let (checksum, bytes) = try writer.finish()
            item.checksum = checksum
            task.checksum = checksum
            task.fileName = info.fileName
            if part != .motion {
                try await database.writer.write { db in
                    try LocalStore.setChecksum(checksum, source: .hashed, id: localID, modifiedAt: version, in: db)
                }
            }
            // (a) Cloud's records, (b) the server, right before uploading.
            let ownerID = ownerID
            if let known = try await database.reader.read({ db in
                try String.fetchOne(db, sql: "SELECT id FROM remoteAsset WHERE ownerId = ? AND checksum = ?", arguments: [ownerID, checksum])
            }) {
                return try await finish(task, remoteID: known, note: "already in Cloud")
            }
            if let found = try await connection.existingAssets([(itemID: String(id), checksum: checksum)]).first(where: \.exists) {
                return try await finish(task, remoteID: found.assetID, note: "already in Cloud")
            }

            var request = connection.backup.uploadRequest(for: item, body: body)
            request.allowsCellularAccess = settings.allowsMobileData
            request.allowsExpensiveNetworkAccess = settings.allowsMobileData
            request.allowsConstrainedNetworkAccess = settings.allowsMobileData
            task.state = .uploading
            task.bodyFile = bodyURL.lastPathComponent
            task.bytes = bytes
            task.attempts += 1
            task.lastError = nil
            try await database.writer.write { [task] db in try BackupStore.save(task, in: db) }
            started = true
            task.sessionTaskId = await session.start(request, bodyFile: bodyURL, description: Self.description(for: id))
            try await database.writer.write { [task] db in try BackupStore.save(task, in: db) }
            Log.backup.info("Uploading \(info.fileName, privacy: .public) (\(task.part.rawValue, privacy: .public), \(bytes) bytes)")
        } catch let error as ChecksumError where error == .notOnPhone {
            await retryLater(task, message: settings.downloadsFromICloud
                ? String(localized: "The original is in iCloud and will be downloaded on Wi-Fi.")
                : String(localized: "The original is only in iCloud; downloading from iCloud is off."), minimumDelay: 3600)
        } catch let error as ChecksumError where error == .assetGone {
            try? await database.writer.write { db in try db.execute(sql: "DELETE FROM uploadTask WHERE id = ?", arguments: [id]) }
        } catch let error as ChecksumError where error == .noUploadResource {
            await fail(task, message: error.localizedDescription)
        } catch {
            await retryLater(task, message: Self.readable(error))
        }
    }

    private static func readable(_ error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, [NSFileWriteOutOfSpaceError, 640].contains(nsError.code) {
            return String(localized: "Not enough free space on this iPhone to prepare the upload.")
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return String(localized: "Not enough free space on this iPhone to prepare the upload.")
        }
        return CloudError.wrap(error, operation: "Backup").message
    }

    // MARK: Crash guard

    private var preparingKey: String { "backup.preparing.\(ownerID)" }

    private func markPreparing(_ id: Int64) {
        crashMarkers.set(Int(id), forKey: preparingKey)
    }

    private func clearPreparing() {
        crashMarkers.removeObject(forKey: preparingKey)
    }

    /// The app stopped (crashed or was killed) while preparing a file last time: try it
    /// again later, and after three such stops skip it, so one bad file can't stop the app
    /// from opening.
    private func recoverFromInterruptedPreparation() async {
        guard let marked = crashMarkers.object(forKey: preparingKey) as? Int else { return }
        clearPreparing()
        guard var task = try? await database.reader.read({ db in try BackupStore.task(id: Int64(marked), in: db) }),
              task.state == .pending || task.state == .waiting else { return }
        task.attempts += 1
        try? FileManager.default.removeItem(at: folder.appending(path: "body-\(marked)"))
        if task.attempts >= 3 {
            await fail(task, message: String(localized: "The app stopped while preparing this file three times, so it was skipped. Try Again retries it."))
        } else {
            await retryLater(task, message: String(localized: "The app stopped while preparing this file."), minimumDelay: 600)
        }
        Log.backup.error("Backup was interrupted while preparing task \(marked) (attempt \(task.attempts))")
    }

    static func description(for id: Int64) -> String { "upload:\(id)" }

    static func taskID(from description: String) -> Int64? {
        guard description.hasPrefix("upload:") else { return nil }
        return Int64(description.dropFirst(7))
    }

    // MARK: Results

    /// Upload progress and results from the background session.
    public func handle(_ event: UploadEvent) async {
        switch event {
        case .progress(let description, let sent, let total):
            guard Self.taskID(from: description) != nil, total > 0 else { return }
            status.currentProgress = Double(sent) / Double(total)
            await publish(force: false)
        case .finished(let description, let statusCode, let body, let error):
            guard let id = Self.taskID(from: description),
                  let task = try? await database.reader.read({ db in try BackupStore.task(id: id, in: db) }) else { return }
            await finished(task, statusCode: statusCode, body: body, error: error)
            status.currentProgress = nil
            await run()
        }
    }

    private func finished(_ task: UploadTaskRecord, statusCode: Int?, body: Data, error: (any Error)?) async {
        deleteBody(task)
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                await retryLater(task, message: String(localized: "The upload was interrupted."), minimumDelay: 0)
            } else {
                await retryLater(task, message: CloudError.wrap(error, operation: "Upload").message)
            }
            return
        }
        guard let statusCode else {
            return await retryLater(task, message: String(localized: "Upload: no answer from the server."))
        }
        switch parse(statusCode, body) {
        case .success(let result):
            try? await finish(task, remoteID: result.assetID, note: result.created ? "uploaded" : "server already had it")
        case .failure(let error):
            switch error.kind {
            case .unauthorized:
                needsSignIn = true
                await retryLater(task, message: error.message, minimumDelay: 0)
            case .http(let status) where status == 408 || status == 429 || status >= 500:
                await retryLater(task, message: error.message)
            default:
                await fail(task, message: error.message)
            }
        }
    }

    private func finish(_ task: UploadTaskRecord, remoteID: String?, note: String) async throws {
        var task = task
        deleteBody(task)
        task.state = .done
        task.remoteId = remoteID
        task.bodyFile = nil
        task.bytes = nil
        task.lastError = nil
        task.finishedAt = .now
        try await database.writer.write { [task] db in try BackupStore.save(task, in: db) }
        Log.backup.info("\(task.fileName ?? task.localId, privacy: .public): \(note, privacy: .public)")
        // An edited photo: stack the new version over its earlier upload, like the official app.
        if let old = task.replacesRemoteId, let new = remoteID, old != new, let connection = await connection() {
            do {
                try await connection.stack(assetIDs: [new, old])
            } catch {
                Log.backup.notice("Stacking the edited version failed: \(CloudError.wrap(error, operation: "Stack").message, privacy: .public)")
            }
        }
        await publish(force: true)
    }

    private func retryLater(_ task: UploadTaskRecord, message: String, minimumDelay: TimeInterval = 30) async {
        var task = task
        task.state = .waiting
        task.lastError = message
        task.bodyFile = nil
        task.bytes = nil
        task.nextAttemptAt = .now.addingTimeInterval(max(minimumDelay, Backoff.delay(afterAttempt: max(task.attempts, 1))))
        try? await database.writer.write { [task] db in try BackupStore.save(task, in: db) }
        Log.backup.notice("\(task.fileName ?? task.localId, privacy: .public): retrying later — \(message, privacy: .public)")
    }

    private func fail(_ task: UploadTaskRecord, message: String) async {
        var task = task
        task.state = .failed
        task.lastError = message
        task.bodyFile = nil
        task.bytes = nil
        task.finishedAt = .now
        try? await database.writer.write { [task] db in try BackupStore.save(task, in: db) }
        Log.backup.error("\(task.fileName ?? task.localId, privacy: .public): \(message, privacy: .public)")
    }

    private func deleteBody(_ task: UploadTaskRecord) {
        if let name = task.bodyFile { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    // MARK: Launch

    /// After a launch or relaunch: uploads the system no longer runs go back to the queue
    /// (re-sending is safe: the server recognises the checksum), and temp files nothing
    /// refers to are deleted.
    public func reconcile() async {
        await recoverFromInterruptedPreparation()
        let active = await session.activeDescriptions()
        let stale = ((try? await database.reader.read { db in try BackupStore.inFlight(in: db) }) ?? [])
            .filter { $0.id.map { !active.contains(Self.description(for: $0)) } ?? false }
        for var task in stale {
            deleteBody(task)
            task.state = .pending
            task.bodyFile = nil
            task.bytes = nil
            try? await database.writer.write { [task] db in try BackupStore.save(task, in: db) }
        }
        if !stale.isEmpty { Log.backup.notice("\(stale.count) uploads were interrupted; queued again") }
        let referenced = (try? await database.reader.read { db in try BackupStore.referencedBodyFiles(in: db) }) ?? []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in files where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
            removed += 1
        }
        if removed > 0 { Log.backup.info("Removed \(removed) leftover temporary files") }
    }

    public func signedInAgain() {
        needsSignIn = false
    }

    public func retryFailed() async {
        try? await database.writer.write { db in try BackupStore.retryFailed(in: db) }
        await run()
    }

    // MARK: Status

    public func currentStatus() async -> BackupStatus {
        await refreshCounts()
        return status
    }

    private func refreshCounts() async {
        let scope = await scope()
        let ownerID = ownerID
        if let (counts, problems) = try? await database.reader.read({ db in
            (try BackupStore.counts(ownerID: ownerID, scope: scope, in: db), try BackupStore.problems(limit: 20, in: db))
        }) {
            status.counts = counts
            status.problems = problems.map { "\($0.fileName ?? String(localized: "A photo")): \($0.lastError ?? "")" }
        }
    }

    private func publish(force: Bool) async {
        let now = ContinuousClock.now
        guard force || now - lastPublish > .milliseconds(500) else { return }
        lastPublish = now
        if force { await refreshCounts() }
        onStatus(status)
    }
}

/// The upload body file being written, with the running checksum of the file part.
final class BodyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var hasher = ChecksumHasher()
    private var bytes = 0

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data, hash: Bool) throws {
        try lock.withLock {
            try handle.write(contentsOf: data)
            bytes += data.count
            if hash { hasher.update(data) }
        }
    }

    func finish() throws -> (checksum: String, bytes: Int) {
        try lock.withLock {
            try handle.synchronize()
            try handle.close()
            return (hasher.finalize(), bytes)
        }
    }

    func close() {
        lock.withLock { try? handle.close() }
    }
}
