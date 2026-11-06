import Backup
import Core
import CryptoKit
import Library
import Photos
import Foundation
import GRDB
import CloudCore
import MediaCache
import Persistence

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(applied: Int)
    case upToDate(Date)
    case failed(message: String, at: Date)
}

/// The timeline as the grid consumes it. `version` changes whenever `items` does,
/// so SwiftUI updates don't compare 25k-element arrays.
/// What Settings › Diagnostics shows, to compare the phone's copy with the server.
public struct LibraryDiagnostics: Sendable, Equatable {
    public var local = LibraryCounts()
    public var server: CloudLibraryCounts?
    public var serverError: String?
    /// Events the last sync couldn't read, e.g. "AssetV2: 3 (…)".
    public var lastSkipped: String?
    public var thumbnailFailures: [MediaError.Kind: Int] = [:]
}

public struct TimelineSnapshot: Sendable {
    public var items: [TimelineItem] = []
    public var version = 0
    public var isLoaded = false
}

/// Everything that belongs to one signed-in account: its database, image cache,
/// sync state and timeline. Created when the account becomes active.
@MainActor
@Observable
public final class LibrarySession {
    public let account: Account
    public let pipeline: RemoteImagePipeline
    public let originals: OriginalStore
    /// The Hidden album (Immich Locked Folder), unlocked with Face ID.
    @ObservationIgnored public private(set) lazy var hiddenVault = HiddenVault(userID: account.userID) { [weak self] in
        guard let self else { throw CloudError(kind: .transport, message: "Not signed in.") }
        return try self.connected()
    }

    /// The phone's own photo library, indexed into the database and merged into the timeline.
    let phoneLibrary: LocalLibrary
    let phoneImages = PhoneImages()
    /// Photos access for this app (the merged Library needs at least limited access).
    public internal(set) var photoAccess = LocalLibrary.authorization
    @ObservationIgnored var hashTask: Task<Void, Never>?
    /// Backup (PLAN.md M5): uploads run on a background session that outlives the app.
    let backupSession: BackgroundUploadSession
    @ObservationIgnored var backup: BackupEngine!
    public internal(set) var backupStatus = BackupStatus()
    /// Bumped when the account picture changes, so views showing it reload.
    public internal(set) var profileImageVersion = 0
    public internal(set) var backupSettings = BackupSettings.load() {
        didSet { backupSettings.save(); runBackup() }
    }
    @ObservationIgnored let network = NetworkState()
    @ObservationIgnored var albumSyncRunning = false

    public private(set) var timeline = TimelineSnapshot()
    public private(set) var syncStatus: SyncStatus = .idle
    /// Set when the server rejects the token (401); the user must sign in again.
    public private(set) var needsSignIn = false

    let database: AppDatabase
    let token: String
    let paths: AccountPaths
    let provider: any CloudProvider
    /// The active server's connection for this account; nil while no server answers.
    private(set) var connection: (any CloudConnection)?
    private let mediaSource = MediaSourceBox()
    private(set) var server: ActiveServer?
    private var observeTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var lastSyncStarted: ContinuousClock.Instant?
    private var followUpTask: Task<Void, Never>?
    /// Whether the app is in the foreground; follow-up syncs only run then.
    var isActive = true

    /// Automatic syncs (foreground, network change) are at most this frequent.
    private let minimumSyncInterval: Duration = .seconds(60)
    /// While the server is still generating previews, sync this often (foreground only)
    /// so new thumbhashes arrive and those tiles load. An idle delta sync is one small request.
    private let pendingPreviewsSyncInterval: Duration = .seconds(120)
    /// Disk budget for thumbnails and previews (Cloud Server Settings › Storage; 1 GB by default).
    public static var thumbnailCacheLimitBytes: Int {
        UserDefaults.standard.object(forKey: "cache.thumbnailLimit") as? Int ?? 1024 * 1024 * 1024
    }
    /// Disk budget for downloaded originals (viewer zoom, sharing, Live Photos; 2 GB by default).
    public static var originalsCacheLimitBytes: Int {
        UserDefaults.standard.object(forKey: "cache.originalsLimit") as? Int ?? 2 * 1024 * 1024 * 1024
    }

    init(account: Account, token: String, provider: any CloudProvider, mediaSession: URLSession, originalsSession: URLSession) throws {
        self.account = account
        self.token = token
        self.provider = provider
        paths = AccountPaths(userID: account.userID)
        try paths.createDirectories()
        database = try AppDatabase.open(at: paths.database)
        let source = mediaSource
        pipeline = RemoteImagePipeline(
            cacheDirectory: paths.mediaCache.appending(path: "Thumbnails"),
            downloader: URLSessionDownloader(session: mediaSession),
            source: { source.value }
        )
        originals = OriginalStore(
            directory: paths.mediaCache.appending(path: "Originals"),
            downloader: URLSessionFileDownloader(session: originalsSession),
            source: { source.value }
        )
        phoneLibrary = LocalLibrary(database: database, ownerID: account.userID)
        backupSession = BackgroundUploadSession(identifier: Self.backupSessionIdentifier(userID: account.userID))
        observeTimeline()
        startBackup()
        startPhoneLibrary()
        Task.detached(priority: .utility) { [database] in
            // Times already synced before the fix (sync also runs it after each pass).
            if let fixed = try? await database.writer.write({ db in try RemoteStore.fixZonelessLocalTimes(in: db) }), fixed > 0 {
                Log.sync.info("Corrected the local time of \(fixed) photos without a time zone")
            }
        }
        Task.detached(priority: .background) { [pipeline, originals] in
            await pipeline.trimDiskCache(toBytes: Self.thumbnailCacheLimitBytes)
            await originals.trim(toBytes: Self.originalsCacheLimitBytes)
        }
    }

    func close() {
        observeTask?.cancel()
        syncTask?.cancel()
        followUpTask?.cancel()
        hashTask?.cancel()
        Task { [phoneLibrary] in await phoneLibrary.stopObserving() }
    }


    /// Called when the reachable server changes (or becomes unreachable).
    func serverChanged(_ server: ActiveServer?) {
        let changed = self.server != server
        self.server = server
        connection = server.map { provider.connection(to: $0, token: token) }
        mediaSource.value = connection?.media
        if changed, server != nil {
            // Failures seen while on another route (or offline) say nothing about this one.
            Task { [pipeline] in await pipeline.resetFailures() }
        }
        if server != nil {
            syncIfDue()
            runBackup()
            // Links left by an AirPlay session the app didn't finish (e.g. it was closed).
            releaseAirPlayLinks()
        }
    }

    /// Syncs unless one ran recently. Used on launch, foreground and network changes.
    func syncIfDue() {
        if let lastSyncStarted, ContinuousClock.now - lastSyncStarted < minimumSyncInterval { return }
        syncNow()
    }

    /// Clears the phone's copy of the library and downloads it again from the server.
    public func resyncFromScratch() {
        syncTask?.cancel()
        syncTask = nil
        syncNow(fromScratch: true)
    }

    public func syncNow() {
        syncNow(fromScratch: false)
    }

    private func syncNow(fromScratch: Bool) {
        guard syncTask == nil, let connection, !needsSignIn else { return }
        lastSyncStarted = .now
        syncStatus = .syncing(applied: 0)
        let database = database
        let fingerprint = Self.fingerprint(token)
        syncTask = Task { [weak self] in
            do {
                try await connection.syncLibrary(into: database, sessionFingerprint: fingerprint, fromScratch: fromScratch) { applied in
                    Task { @MainActor in
                        guard let self, case .syncing = self.syncStatus else { return }
                        self.syncStatus = .syncing(applied: applied)
                    }
                }
                self?.syncStatus = .upToDate(.now)
                await self?.scheduleFollowUpIfPreviewsPending()
                // New upload records may identify more phone photos (no hashing needed).
                if let self { _ = try? await self.phoneLibrary.reconcileChecksums(); self.scheduleHashing(); self.runBackup() }
            } catch is CancellationError {
                self?.syncStatus = .idle
            } catch let error as CloudError {
                Log.sync.error("Sync failed: \(error.message, privacy: .public)")
                if error.kind == .unauthorized { self?.needsSignIn = true }
                self?.syncStatus = .failed(message: error.message, at: .now)
            } catch {
                Log.sync.error("Sync failed: \(String(describing: error), privacy: .public)")
                self?.syncStatus = .failed(message: error.localizedDescription, at: .now)
            }
            self?.syncTask = nil
        }
    }

    private func scheduleFollowUpIfPreviewsPending() async {
        followUpTask?.cancel()
        let ownerID = account.userID
        let pending = (try? await database.reader.read { db in
            try LibraryCounts.fetch(ownerID: ownerID, in: db).waitingForPreviews
        }) ?? 0
        guard pending > 0 else { return }
        Log.sync.info("\(pending) items are waiting for server previews; syncing again in 2 minutes")
        let interval = pendingPreviewsSyncInterval
        followUpTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.syncNow()
        }
    }

    /// Called by the app on foreground/background changes.
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            startPhoneLibrary()
        } else {
            hashTask?.cancel()
            hashTask = nil
        }
        if !active {
            followUpTask?.cancel()
            // The Hidden album locks again when you leave the app.
            Task { await hiddenVault.lock() }
        }
    }

    public func diagnostics() async -> LibraryDiagnostics {
        var result = LibraryDiagnostics()
        let ownerID = account.userID
        do {
            let (counts, skipped) = try await database.reader.read { db in
                (try LibraryCounts.fetch(ownerID: ownerID, in: db), try SyncState.value(.lastSkipped, in: db))
            }
            result.local = counts
            result.lastSkipped = skipped
        } catch {
            Log.database.error("Diagnostics query failed: \(String(describing: error), privacy: .public)")
        }
        result.thumbnailFailures = await pipeline.failureCounts()
        if let connection {
            do {
                result.server = try await connection.libraryCounts()
            } catch {
                result.serverError = CloudError.wrap(error, operation: "Server statistics").message
            }
        } else {
            result.serverError = "Not connected to the server."
        }
        return result
    }

    // MARK: Viewer actions

    /// Synchronous lookup for configuring viewer pages (a single indexed row; well under a millisecond).
    func detailsNow(for assetID: String) -> AssetDetails? {
        if assetID.hasPrefix("local:") { return phoneDetails(localID: String(assetID.dropFirst(6))) }
        return try? database.reader.read { db in try AssetDetails.fetch(id: assetID, in: db) }
    }

    /// On the home network the viewer fetches originals as soon as a photo settles.
    var isOnHomeNetwork: Bool { server?.route == .local }

    public func details(for assetID: String) async -> AssetDetails? {
        if assetID.hasPrefix("local:") { return phoneDetails(localID: String(assetID.dropFirst(6))) }
        return try? await database.reader.read { db in try AssetDetails.fetch(id: assetID, in: db) }
    }

    public func albums(containing assetID: String) async throws -> [CloudAlbum] {
        try await connected().albums(containing: assetID)
    }

    public func setFavorite(_ isFavorite: Bool, assetIDs ids: [String]) async throws {
        let (assetIDs, phone) = Self.split(ids)
        if !phone.isEmpty { try await setPhoneFavorite(isFavorite, localIDs: phone) }
        guard !assetIDs.isEmpty else { return }
        try await change(assetIDs, local: { db in try RemoteStore.setFavorite(isFavorite, ids: assetIDs, in: db) },
                         revert: { db in try RemoteStore.setFavorite(!isFavorite, ids: assetIDs, in: db) },
                         remote: { try await $0.setFavorite(isFavorite, assetIDs: assetIDs) })
    }

    public func setArchived(_ archived: Bool, assetIDs: [String]) async throws {
        try await change(assetIDs, local: { db in try RemoteStore.setVisibility(archived ? .archive : .timeline, ids: assetIDs, in: db) },
                         revert: { db in try RemoteStore.setVisibility(archived ? .timeline : .archive, ids: assetIDs, in: db) },
                         remote: { try await $0.setArchived(archived, assetIDs: assetIDs) })
    }

    public func setCaption(_ text: String, assetID: String) async throws {
        let previous = detailsNow(for: assetID)?.exif?.description
        try await change([assetID], local: { db in try RemoteStore.setDescription(text, id: assetID, in: db) },
                         revert: { db in try RemoteStore.setDescription(previous, id: assetID, in: db) },
                         remote: { try await $0.setDescription(text, assetID: assetID) })
    }

    // MARK: Hidden (Immich Locked Folder)

    /// Hides in the Cloud (Hidden album) and on the phone, so the photo leaves the Library
    /// everywhere; a photo only on the phone goes to the phone's Hidden album.
    public func hide(assetIDs ids: [String]) async throws {
        let (assetIDs, phone) = await phoneIDs(for: ids)
        try await setPhoneHidden(true, localIDs: phone)
        guard !assetIDs.isEmpty else { return }
        try await change(assetIDs, local: { db in try RemoteStore.setVisibility(.locked, ids: assetIDs, in: db) },
                         revert: { db in try RemoteStore.setVisibility(.timeline, ids: assetIDs, in: db) },
                         remote: { try await $0.setLocked(true, assetIDs: assetIDs) })
    }

    /// Unhiding needs an unlocked session, so this asks for Face ID first if needed.
    public func unhide(assetIDs: [String]) async throws {
        if hiddenVault.state != .unlocked {
            guard await hiddenVault.unlock() else {
                throw CloudError(kind: .unauthorized, message: hiddenVault.errorMessage ?? String(localized: "Unlock the Hidden album to unhide."))
            }
        }
        let (remote, phone) = await phoneIDs(for: assetIDs)
        try await setPhoneHidden(false, localIDs: phone)
        guard !remote.isEmpty else { return }
        try await change(remote, local: { db in try RemoteStore.setVisibility(.timeline, ids: remote, in: db) },
                         revert: { db in try RemoteStore.setVisibility(.locked, ids: remote, in: db) },
                         remote: { try await $0.setLocked(false, assetIDs: remote) })
    }

    // MARK: Duplicate

    /// Uploads a pixel-identical copy as a new asset (see `Duplicator`). Live Photos are
    /// duplicated as a pair. The copy keeps the capture date; it appears after the next sync.
    public func duplicate(assetID: String, keepHidden: Bool = false) async throws {
        try requireServerItems([assetID])
        guard let details = detailsNow(for: assetID) else {
            throw CloudError(kind: .decoding, message: "This item is no longer in the library.")
        }
        let connection = try connected()
        var motionID: String?
        if let motionAssetID = details.asset.livePhotoVideoId, let motion = detailsNow(for: motionAssetID) {
            motionID = try await uploadCopy(of: motion, connection: connection, visibility: .hidden, livePhotoVideoID: nil)
        }
        _ = try await uploadCopy(of: details, connection: connection, visibility: keepHidden ? .locked : nil, livePhotoVideoID: motionID)
        lastSyncStarted = nil
        syncNow()
    }

    private func uploadCopy(of details: AssetDetails, connection: any CloudConnection, visibility: CloudVisibility?, livePhotoVideoID: String?) async throws -> String {
        let original = try await originals.file(assetID: details.asset.id, fileName: details.asset.originalFileName)
        let copy = try await Duplicator.makeCopy(of: original)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let created = details.asset.fileCreatedAt ?? details.asset.localDateTime ?? .now
        let result = try await connection.upload(CloudUploadFile(
            fileURL: copy, fileName: details.asset.originalFileName, createdAt: created, modifiedAt: .now,
            livePhotoVideoID: livePhotoVideoID, visibility: visibility
        ))
        Log.sync.info("Duplicated \(details.asset.id, privacy: .public) as \(result.assetID, privacy: .public) (new: \(result.created))")
        return result.assetID
    }

    /// An Immich shared link for the assets (anyone with the link can view and download).
    public func createSharedLink(assetIDs: [String]) async throws -> URL {
        try requireServerItems(assetIDs)
        return try await connected().createSharedLink(assetIDs: assetIDs, expiresAt: nil).url
    }

    // MARK: Albums, date and location

    public func albums(shared: Bool) async throws -> [CloudAlbum] {
        try await connected().albums(shared: shared)
    }

    public func add(assetIDs: [String], toAlbum album: CloudAlbum) async throws {
        try requireServerItems(assetIDs)
        try await connected().addAssets(assetIDs, toAlbum: album.id)
    }

    public func createAlbum(named name: String, assetIDs: [String], sharedWith userIDs: [String] = []) async throws -> CloudAlbum {
        try requireServerItems(assetIDs)
        return try await connected().createAlbum(name: name, assetIDs: assetIDs, sharedWith: userIDs)
    }

    /// Other people on the server (for New Shared Album).
    public func otherUsers() -> [UserRecord] {
        let me = account.userID
        return (try? database.reader.read { db in
            try UserRecord.filter(Column("id") != me).order(Column("name")).fetchAll(db)
        }) ?? []
    }

    /// New capture date and time, in `timeZone` (the photo's own, so the wall-clock time is what the user picked).
    public func setDate(_ date: Date, timeZone: TimeZone, assetIDs: [String]) async throws {
        try requireServerItems(assetIDs)
        let text = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: timeZone))
        try await connected().setDateTimeOriginal(text, assetIDs: assetIDs)
        lastSyncStarted = nil
        syncNow()
    }

    public func setLocation(latitude: Double, longitude: Double, assetIDs: [String]) async throws {
        try requireServerItems(assetIDs)
        try await connected().setLocation(latitude: latitude, longitude: longitude, assetIDs: assetIDs)
        lastSyncStarted = nil
        syncNow()
    }

    /// Deletes everywhere: from the phone too (iOS asks first; the phone keeps
    /// it in its own Recently Deleted) and into the Cloud trash (restorable for the server's
    /// retention period). Trashing only the Cloud copy left the phone's copy in the Library,
    /// so the photo seemed not to go. If iOS's prompt is declined, nothing is deleted.
    public func moveToTrash(assetIDs ids: [String]) async throws {
        let (assetIDs, phone) = await phoneIDs(for: ids)
        ActionLog.write("delete: \(ids.count) items, \(assetIDs.count) in Cloud, \(phone.count) on the phone")
        if !phone.isEmpty { try await deleteFromPhone(localIDs: phone) }
        guard !assetIDs.isEmpty else { return }
        let now = Date.now
        try await change(assetIDs, local: { db in try RemoteStore.setDeletedAt(now, ids: assetIDs, in: db) },
                         revert: { db in try RemoteStore.setDeletedAt(nil, ids: assetIDs, in: db) },
                         remote: { try await $0.moveToTrash(assetIDs: assetIDs) })
    }

    public func restoreFromTrash(assetIDs: [String]) async throws {
        let now = Date.now
        try await change(assetIDs, local: { db in try RemoteStore.setDeletedAt(nil, ids: assetIDs, in: db) },
                         revert: { db in try RemoteStore.setDeletedAt(now, ids: assetIDs, in: db) },
                         remote: { try await $0.restoreFromTrash(assetIDs: assetIDs) })
    }

    /// Applies a change on the phone straight away (the grid updates at once), then on the
    /// server; if the server refuses, the local change is undone and the error is rethrown.
    /// Server-only actions (archive, hide, albums, dates…) need the item on the server.
    func requireServerItems(_ ids: [String]) throws {
        if ids.contains(where: { $0.hasPrefix("local:") }) {
            throw CloudError(kind: .decoding, message: String(localized: "Some of these are only on this iPhone. Back them up to Cloud first."))
        }
    }

    private func change(
        _ ids: [String],
        local: @escaping @Sendable (Database) throws -> Void,
        revert: @escaping @Sendable (Database) throws -> Void,
        remote: (any CloudConnection) async throws -> Void
    ) async throws {
        try requireServerItems(ids)
        let connection = try connected()
        try await database.writer.write(local)
        do {
            try await remote(connection)
        } catch {
            try? await database.writer.write(revert)
            ActionLog.write("server refused a change to \(ids.count) items: \(CloudError.wrap(error, operation: "Change").message)")
            Log.sync.error("Change to \(ids.count) assets failed: \(CloudError.wrap(error, operation: "Change").message, privacy: .public)")
            throw CloudError.wrap(error, operation: "Change")
        }
    }

    func connected() throws -> any CloudConnection {
        guard let connection else { throw CloudError.notConnected }
        return connection
    }

    public func clearThumbnailCache() async {
        await pipeline.clearMemory()
        await pipeline.trimDiskCache(toBytes: 0)
    }

    /// New cache budgets; the caches shrink to fit straight away.
    public func setCacheLimits(thumbnails: Int? = nil, originals originalsLimit: Int? = nil) async {
        if let thumbnails { UserDefaults.standard.set(thumbnails, forKey: "cache.thumbnailLimit") }
        if let originalsLimit { UserDefaults.standard.set(originalsLimit, forKey: "cache.originalsLimit") }
        await pipeline.trimDiskCache(toBytes: Self.thumbnailCacheLimitBytes)
        await originals.trim(toBytes: Self.originalsCacheLimitBytes)
    }

    public func originalsCacheSize() async -> Int {
        await Task.detached { [originals] in originals.size() }.value
    }

    public func clearOriginalsCache() async {
        await originals.trim(toBytes: 0)
    }

    public func thumbnailCacheSize() async -> Int {
        await Task.detached { [pipeline] in pipeline.diskCacheSize() }.value
    }

    /// Removes this account's database and caches from the phone.
    func deleteLocalData() {
        close()
        paths.removeAll()
    }

    /// The Hidden album's items (visibility `locked`), updated as they change.
    func observeHidden() -> AsyncValueObservation<[TimelineItem]> {
        TimelineQuery.observeRemote(ownerID: account.userID, visibility: .locked, in: database)
    }

    private func observeTimeline() {
        let ownerID = account.userID
        let database = database
        observeTask = Task { [weak self] in
            do {
                for try await items in TimelineQuery.observeMerged(ownerID: ownerID, in: database) {
                    guard let self else { return }
                    self.timeline = TimelineSnapshot(items: items, version: self.timeline.version + 1, isLoaded: true)
                }
            } catch {
                Log.database.error("Timeline observation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The server keeps sync checkpoints per session; this identifies the session
    /// without storing the token itself in the database.
    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Thread-safe holder read by the image pipeline off the main actor.
final class MediaSourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: MediaSource?

    var value: MediaSource? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
