import Backup
import BackgroundTasks
import Core
import Foundation

/// Background work: uploads continue on a background URLSession on their own;
/// these tasks let iOS wake the app to find new photos and queue them.
extension AppModel {
    /// Long-running, ideally on power: index, identify and queue new photos.
    public static let backupTaskID = "com.ethwood.photos.backup"
    /// Short and periodic: spot new photos and do a light sync.
    public static let refreshTaskID = "com.ethwood.photos.refresh"

    /// Must run before the app finishes launching.
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backupTaskID, using: nil) { [weak self] task in
            Task { @MainActor in self?.runBackgroundTask(task, light: false) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { [weak self] task in
            Task { @MainActor in self?.runBackgroundTask(task, light: true) }
        }
    }

    private func runBackgroundTask(_ task: BGTask, light: Bool) {
        start()
        scheduleBackgroundTasks()
        let work = Task { @MainActor [weak self] in
            guard let session = self?.session else { return }
            if light {
                session.syncNow()
            }
            await session.runBackgroundBackup()
            // The long task also fetches thumbnails and Keep Offline originals (Wi-Fi only).
            if !light, let offline = session.runOfflineWork() {
                await withTaskCancellationHandler { await offline.value } onCancel: { offline.cancel() }
            }
            // Give started uploads a moment to hand over to the background session.
            try? await Task.sleep(for: .seconds(light ? 5 : 25))
        }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
        Log.backup.info("Background \(light ? "refresh" : "processing", privacy: .public) task started")
    }

    /// Asks iOS for the next background runs (called when the app goes to the background).
    public func scheduleBackgroundTasks() {
        let settings = BackupSettings.load()
        let backsUp = settings.isEnabled && !settings.isPaused
        let offline = OfflineSettings.downloadsAllThumbnails || OfflineSettings.keepsFavourites || !OfflineSettings.albumIDs.isEmpty
        guard backsUp || offline else { return }
        let processing = BGProcessingTaskRequest(identifier: Self.backupTaskID)
        processing.requiresNetworkConnectivity = true
        // Offline downloads alone wait for the charger.
        processing.requiresExternalPower = backsUp ? settings.onlyWhileCharging : true
        processing.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        refresh.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(processing)
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            Log.backup.notice("Couldn't schedule background work: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iOS relaunched the app to deliver background upload results.
    public func handleBackgroundUploadEvents(identifier: String, completion: @escaping () -> Void) {
        start()
        if session?.handleBackgroundUploadEvents(identifier: identifier, completion: completion) != true {
            completion()
        }
    }
}
