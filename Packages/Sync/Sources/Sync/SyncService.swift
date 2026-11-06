import Core
import Foundation
import GRDB
import ImmichAPI
import OpenAPIRuntime
import Persistence

/// The two calls the sync stream needs, so tests can replace the server.
public protocol SyncAPI: Sendable {
    /// `reset` asks the server to discard this session's checkpoints and send everything again.
    func openStream(types: [Schemas.SyncRequestType], reset: Bool) async throws -> HTTPBody
    func ack(_ acks: [String]) async throws
    /// Forgets the checkpoints for these types, so the server sends all of their data again.
    func resend(_ types: [Schemas.SyncEntityType]) async throws
}

/// `SyncAPI` backed by the generated client.
public struct ClientSyncAPI: SyncAPI {
    let client: Client

    public init(client: Client) {
        self.client = client
    }

    public func openStream(types: [Schemas.SyncRequestType], reset: Bool) async throws -> HTTPBody {
        let output: Operations.GetSyncStream.Output
        do {
            output = try await client.getSyncStream(body: .json(.init(reset: reset ? true : nil, types: types)))
        } catch {
            throw APIError.wrap(error, operation: "Sync")
        }
        switch output {
        case .ok(let response):
            guard case .any(let body) = response.body else {
                throw APIError(kind: .decoding, message: "Sync: the server sent an unexpected response.")
            }
            return body
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "sync")
        }
    }

    public func resend(_ types: [Schemas.SyncEntityType]) async throws {
        let output: Operations.DeleteSyncAck.Output
        do {
            output = try await client.deleteSyncAck(body: .json(.init(types: types)))
        } catch {
            throw APIError.wrap(error, operation: "Sync reset")
        }
        switch output {
        case .noContent:
            return
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "sync reset")
        }
    }

    public func ack(_ acks: [String]) async throws {
        let output: Operations.SendSyncAck.Output
        do {
            output = try await client.sendSyncAck(body: .json(.init(acks: acks)))
        } catch {
            throw APIError.wrap(error, operation: "Sync acknowledgement")
        }
        switch output {
        case .noContent:
            return
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "sync acknowledgement")
        }
    }
}

public struct SyncReport: Sendable, Equatable {
    public var eventsApplied = 0
    public var resets = 0
    /// Events of unknown types (expected; not an error).
    public var ignored = 0
    /// Events of known types that could not be read, by type, with the first reason seen.
    public var undecodable: [String: (count: Int, reason: String)] = [:]

    public var skipped: Int { ignored + undecodable.values.reduce(0) { $0 + $1.count } }

    /// e.g. "AssetV2: 3 (keyNotFound …)", or nil when nothing was unreadable.
    public var undecodableSummary: String? {
        guard !undecodable.isEmpty else { return nil }
        return undecodable.keys.sorted().map { type in
            let entry = undecodable[type]!
            return "\(type): \(entry.count) (\(entry.reason))"
        }.joined(separator: "; ")
    }

    public static func == (lhs: SyncReport, rhs: SyncReport) -> Bool {
        lhs.eventsApplied == rhs.eventsApplied && lhs.resets == rhs.resets && lhs.ignored == rhs.ignored
            && lhs.undecodableSummary == rhs.undecodableSummary
    }
}

/// Runs `/sync/stream` to completion: decodes lines, applies them in runs of the
/// same type (at most `batchSize` per transaction) and acks each run.
public actor SyncService {
    private let database: AppDatabase
    private let api: any SyncAPI
    private let batchSize: Int
    private let types: [Schemas.SyncRequestType]

    public init(
        database: AppDatabase,
        api: any SyncAPI,
        types: [Schemas.SyncRequestType] = SyncRequestTypes.current,
        batchSize: Int = 1000
    ) {
        self.database = database
        self.api = api
        self.types = types
        self.batchSize = batchSize
    }

    /// - Parameter sessionFingerprint: identifies the server session (token). The server
    ///   keeps checkpoints per session, so data from another session is cleared first.
    /// - Parameter fromScratch: clear local data and have the server resend everything.
    public func run(
        sessionFingerprint: String,
        fromScratch: Bool = false,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> SyncReport {
        let start = ContinuousClock.now
        try await database.writer.write { db in
            if fromScratch {
                Log.sync.notice("Full resync requested; clearing synced data")
                try RemoteStore.resetAll(in: db)
                try SyncState.set(.sessionFingerprint, sessionFingerprint, in: db)
            } else if try SyncState.value(.sessionFingerprint, in: db) != sessionFingerprint {
                Log.sync.info("New server session; clearing previously synced data")
                try RemoteStore.resetAll(in: db)
                try SyncState.set(.sessionFingerprint, sessionFingerprint, in: db)
            }
        }

        try await resendIfNeeded()

        var report = SyncReport()
        // A reset ends the stream; run it once more to receive the fresh state.
        var askServerToReset = fromScratch
        for _ in 0..<2 {
            let resetRequested = try await streamOnce(into: &report, reset: askServerToReset, onProgress: onProgress)
            askServerToReset = false
            if !resetRequested { break }
        }
        let summary = report.undecodableSummary
        try await database.writer.write { db in
            try SyncState.set(.lastSkipped, summary, in: db)
        }
        let elapsed = ContinuousClock.now - start
        Log.sync.info("Sync finished: \(report.eventsApplied) events, \(report.skipped) skipped, \(report.resets) resets in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
        return report
    }

    /// Types whose data must be sent again because an older version of the app read it
    /// wrongly. Revision 1: `mobile-app` metadata was read with the key "cloudId"
    /// instead of "iCloudId", so every iCloud identity was missing.
    static let resendRevisions: [(revision: Int, types: [Schemas.SyncEntityType])] = [
        (1, [.assetMetadataV1]),
    ]

    private func resendIfNeeded() async throws {
        let current = try await database.reader.read { db in
            try SyncState.value(.resendRevision, in: db).flatMap(Int.init) ?? 0
        }
        let due = Self.resendRevisions.filter { $0.revision > current }
        guard let latest = due.map(\.revision).max() else { return }
        let types = Array(Set(due.flatMap(\.types)))
        Log.sync.notice("Asking the server to resend \(types.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        try await api.resend(types)
        try await database.writer.write { db in
            try SyncState.set(.resendRevision, String(latest), in: db)
        }
    }

    private func streamOnce(into report: inout SyncReport, reset: Bool, onProgress: @Sendable (Int) -> Void) async throws -> Bool {
        let body = try await api.openStream(types: types, reset: reset)
        let decoder = ImmichDateParser.makeJSONDecoder()
        var run: [SyncLine] = []
        run.reserveCapacity(batchSize)
        var resetRequested = false

        do {
            for try await data in JSONLines(body) {
                try Task.checkCancellation()
                let line: SyncLine
                do {
                    line = try decoder.decode(SyncLine.self, from: data)
                } catch {
                    let preview = String(decoding: data.prefix(200), as: UTF8.self)
                    throw APIError(kind: .decoding, message: "Sync: a line from the server could not be read (\(preview)).")
                }
                if let current = run.first, current.type != line.type || run.count >= batchSize {
                    resetRequested = try await apply(run, report: &report, onProgress: onProgress) || resetRequested
                    run.removeAll(keepingCapacity: true)
                }
                run.append(line)
            }
            resetRequested = try await apply(run, report: &report, onProgress: onProgress) || resetRequested
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.wrap(error, operation: "Sync")
        }
        return resetRequested
    }

    /// Writes one run and acks its last line. Returns true if the run was a reset.
    /// Unreadable lines are counted and skipped; the readable ones in the same run are still applied.
    private func apply(_ batch: [SyncLine], report: inout SyncReport, onProgress: @Sendable (Int) -> Void) async throws -> Bool {
        guard let last = batch.last else { return false }
        var readable: [SyncLine] = []
        readable.reserveCapacity(batch.count)
        for line in batch {
            if case .undecodable(let reason) = line.event {
                let existing = report.undecodable[line.type]
                report.undecodable[line.type] = ((existing?.count ?? 0) + 1, existing?.reason ?? String(reason.prefix(300)))
                Log.sync.error("Unreadable \(line.type, privacy: .public) event: \(reason, privacy: .public)")
            } else {
                readable.append(line)
            }
        }
        if !readable.isEmpty {
            let lines = readable
            try await database.writer.write { db in
                try SyncApplier.apply(lines[...], in: db)
            }
        }
        // The ack covers the whole run, including unreadable lines: they would fail the same way again.
        try await api.ack([last.ack])

        var wasReset = false
        switch readable.first?.event {
        case .reset?:
            wasReset = true
            report.resets += 1
        case .ignored?:
            report.ignored += readable.count
        case nil, .complete?:
            break
        default:
            report.eventsApplied += readable.count
        }
        onProgress(report.eventsApplied)
        return wasReset
    }
}
