import Backup
import CloudCore
import Core
import Foundation
import Library
import Persistence
import UIKit

/// The latest network path, readable from any task (backup checks it before each run).
final class NetworkState: @unchecked Sendable {
    private let lock = NSLock()
    private var path: NetworkPath?
    private var task: Task<Void, Never>?

    func start(onChange: @escaping @Sendable () -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await path in NetworkPathObserver.changes() {
                self?.lock.withLock { self?.path = path }
                onChange()
            }
        }
    }

    var current: NetworkPath? { lock.withLock { path } }
}

extension LibrarySession {
    static func backupSessionIdentifier(userID: String) -> String { "com.ethwood.photos.backup.\(userID)" }

    /// Builds the engine and resumes whatever the background session finished while the app was away.
    func startBackup() {
        let database = database
        let provider = provider
        let network = network
        let folder = paths.database.deletingLastPathComponent().appending(path: "BackupTemp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)

        let engine = BackupEngine(
            database: database, ownerID: account.userID, exporter: PhotoKitExporter(), session: backupSession, folder: folder,
            deviceID: Self.deviceID,
            connection: { [weak self] in await MainActor.run { self?.connection } },
            parse: { provider.uploadResult(statusCode: $0, body: $1) },
            conditions: {
                let path = network.current
                let charging = await MainActor.run { () -> Bool in
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    return UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
                }
                return BackupConditions(isOnline: path?.isSatisfied ?? true, isExpensiveNetwork: path?.isExpensive ?? false, isCharging: charging)
            },
            scope: {
                guard LocalLibrary.canRead else { return [] }
                let selection = (try? await database.reader.read { db in try BackupStore.albumSelection(in: db) }) ?? []
                return LocalLibrary.assetIDs(including: selection.filter(\.include).map(\.id), excluding: selection.filter { !$0.include }.map(\.id))
            },
            settings: { BackupSettings.load() },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.backupStatusChanged(status) }
            }
        )
        backup = engine
        backupSession.setEventHandler { event in
            Task { await engine.handle(event) }
        }
        network.start { [weak self] in
            Task { @MainActor in self?.runBackup() }
        }
        Task {
            await engine.reconcile()
            await engine.run()
        }
    }

    /// Runs the queue (no-op when backup is off or conditions don't allow).
    func runBackup() {
        guard let backup else { return }
        Task { await backup.run() }
    }

    private func backupStatusChanged(_ status: BackupStatus) {
        let uploadedMore = status.counts.backedUp > backupStatus.counts.backedUp
        backupStatus = status
        // When the queue settles, add what was uploaded to the synced albums.
        if status.counts.uploading == 0, status.activity == .idle { syncAlbumsIfEnabled() }
        // Fresh uploads appear in the timeline as "in Cloud" after the next sync.
        if uploadedMore, status.counts.uploading == 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.syncSoon()
            }
        }
    }

    /// A sync that ignores the usual one-a-minute limit (after uploads finish).
    func syncSoon() {
        syncNow()
    }

    public func refreshBackupStatus() async {
        guard let backup else { return }
        backupStatus = await backup.currentStatus()
    }

    public func retryFailedBackups() {
        guard let backup else { return }
        Task { await backup.retryFailed() }
    }

    /// iOS relaunched the app to deliver upload results; `completion` tells it we're done.
    public func handleBackgroundUploadEvents(identifier: String, completion: @escaping () -> Void) -> Bool {
        guard identifier == backupSession.identifier else { return false }
        backupSession.setFinishEventsHandler(completion)
        return true
    }

    /// Background processing (BGProcessingTask): index new photos, identify them, and queue uploads.
    public func runBackgroundBackup() async {
        await phoneLibrary.refresh()
        _ = try? await phoneLibrary.reconcileChecksums()
        await backup?.run()
    }

    public func setBackupAlbum(_ album: PhoneAlbum, mode: String?) async {
        try? await database.writer.write { db in try BackupStore.setAlbum(id: album.id, title: album.title, mode: mode, in: db) }
        runBackup()
    }

    public func backupAlbumSelection() async -> [String: Bool] {
        let rows = (try? await database.reader.read { db in try BackupStore.albumSelection(in: db) }) ?? []
        return Dictionary(rows.map { ($0.id, $0.include) }, uniquingKeysWith: { a, _ in a })
    }

    /// A stable id for this phone (sent with uploads, like the official app's device id).
    static var deviceID: String {
        let key = "backup.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
