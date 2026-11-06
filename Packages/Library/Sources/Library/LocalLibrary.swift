import Core
import Foundation
import GRDB
import Persistence
import Photos

/// Keeps the database's copy of the phone's photo library (`localAsset`) up to date and
/// works out each photo's checksum, so the timeline can pair it with the server's copy.
///
/// - First run: a full scan. Later: only PhotoKit's persistent changes since last time,
///   so launch stays instant. While running, library changes are picked up live.
/// - Checksums come from the server's upload records when the iCloud identity, capture
///   time and edit time all match (no hashing; this is how a reinstall recovers), else by
///   hashing the file a backup would upload (only files already on the phone here).
public actor LocalLibrary {
    private let database: AppDatabase
    private let ownerID: String
    private var observer: ChangeObserver?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    /// Called after each pass that changed something (e.g. to update status in the UI).
    private var onChange: (@Sendable () -> Void)?

    public init(database: AppDatabase, ownerID: String) {
        self.database = database
        self.ownerID = ownerID
    }

    // MARK: Access

    public static var authorization: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public static var canRead: Bool {
        let status = authorization
        return status == .authorized || status == .limited
    }

    // MARK: Indexing

    /// Indexes the library (incrementally when possible), then fills in checksums from
    /// the server's records. Safe to call often; concurrent calls coalesce.
    public func refresh() async {
        guard Self.canRead else { return }
        if let refreshTask {
            pendingRefresh = true
            await refreshTask.value
            return
        }
        let task = Task { await runRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
        if pendingRefresh {
            pendingRefresh = false
            await refresh()
        }
    }

    public func startObserving(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard observer == nil, Self.canRead else { return }
        let observer = ChangeObserver { [weak self] in
            Task { await self?.libraryDidChange() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    public func stopObserving() {
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        observer = nil
    }

    private func libraryDidChange() async {
        // PhotoKit sends bursts of changes (e.g. while iCloud downloads); wait a moment.
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    private func runRefresh() async {
        let start = ContinuousClock.now
        do {
            let changed: Int
            if let token = try await storedToken(), let incremental = try await applyPersistentChanges(since: token) {
                changed = incremental
            } else {
                changed = try await fullScan()
            }
            try await saveToken(PHPhotoLibrary.shared().currentChangeToken)
            let matched = try await reconcileChecksums()
            Log.library.info("Photo library indexed: \(changed) changed, \(matched) matched by iCloud identity in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
            if changed > 0 || matched > 0 { onChange?() }
        } catch {
            Log.library.error("Indexing the photo library failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Hidden photos are indexed too (flagged), so Back Up Hidden Photos can find them; the
    /// Library never shows them.
    private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return options
    }

    /// Reads every asset; removes rows for assets that are gone.
    private func fullScan() async throws -> Int {
        let result = PHAsset.fetchAssets(with: Self.fetchOptions())
        var seen = Set<String>()
        seen.reserveCapacity(result.count)
        var batch: [LocalAssetRecord] = []
        batch.reserveCapacity(1000)
        for index in 0..<result.count {
            let asset = result.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            seen.insert(asset.localIdentifier)
            batch.append(Self.record(for: asset))
            if batch.count == 1000 {
                try await write(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try await write(batch)
        let seenNow = seen
        let removed = try await database.writer.write { db in try LocalStore.deleteAll(except: seenNow, in: db) }
        try await resolveCloudIds(Array(seen), onlyMissing: true)
        Log.library.info("Full scan: \(seen.count) photos and videos, \(removed) removed")
        return seen.count
    }

    /// Applies PhotoKit's changes since `token`; nil when PhotoKit can't (token expired), so a full scan runs.
    private func applyPersistentChanges(since token: PHPersistentChangeToken) async throws -> Int? {
        let changes: PHPersistentChangeFetchResult
        do {
            changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
        } catch {
            Log.library.notice("Persistent changes unavailable (\(error.localizedDescription, privacy: .public)); scanning everything")
            return nil
        }
        var upserted = Set<String>()
        var deleted = Set<String>()
        for change in changes {
            guard let details = try? change.changeDetails(for: .asset) else { continue }
            upserted.formUnion(details.insertedLocalIdentifiers)
            upserted.formUnion(details.updatedLocalIdentifiers)
            deleted.formUnion(details.deletedLocalIdentifiers)
            upserted.subtract(details.deletedLocalIdentifiers)
        }
        guard !upserted.isEmpty || !deleted.isEmpty else { return 0 }
        // Fetching with the usual options drops assets that aren't photos: treat as deleted.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(upserted), options: Self.fetchOptions())
        var records: [LocalAssetRecord] = []
        fetched.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video { records.append(Self.record(for: asset)) }
        }
        let present = Set(records.map(\.id))
        let gone = Array(deleted.union(upserted.subtracting(present)))
        try await write(records)
        try await database.writer.write { db in try LocalStore.delete(ids: gone, in: db) }
        try await resolveCloudIds(Array(present), onlyMissing: false)
        return records.count + gone.count
    }

    private func write(_ records: [LocalAssetRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writer.write { db in try LocalStore.upsert(records, in: db) }
    }

    static func record(for asset: PHAsset) -> LocalAssetRecord {
        let created = asset.creationDate
        return LocalAssetRecord(
            id: asset.localIdentifier,
            mediaType: asset.mediaType.rawValue,
            subtypes: Int(asset.mediaSubtypes.rawValue),
            createdAt: created,
            localDateTime: created.map(wallClock),
            modifiedAt: asset.modificationDate,
            adjustmentTime: asset.photosEditTimestamp,
            isFavorite: asset.isFavorite,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            durationMs: asset.mediaType == .video ? Int((asset.duration * 1000).rounded()) : nil,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            isHidden: asset.isHidden
        )
    }

    /// The capture time as wall-clock time stored as UTC (how the server's timeline is
    /// ordered). PhotoKit doesn't expose the capture time zone, so the phone's is used.
    static func wallClock(_ instant: Date) -> Date {
        instant.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: instant)))
    }

    // MARK: iCloud identities

    /// Looks up iCloud identities (only with iCloud Photos on), in batches.
    private func resolveCloudIds(_ ids: [String], onlyMissing: Bool) async throws {
        var targets = ids
        if onlyMissing {
            let have = try await database.reader.read { db in
                Set(try String.fetchAll(db, sql: "SELECT id FROM localAsset WHERE cloudId IS NOT NULL"))
            }
            targets = ids.filter { !have.contains($0) }
        }
        guard !targets.isEmpty else { return }
        var mapping: [String: String] = [:]
        for start in stride(from: 0, to: targets.count, by: 1000) {
            let batch = Array(targets[start..<min(start + 1000, targets.count)])
            let results = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: batch)
            for (localID, result) in results {
                if case .success(let cloud) = result { mapping[localID] = cloud.stringValue }
            }
        }
        let resolved = mapping
        try await database.writer.write { db in try LocalStore.setCloudIds(resolved, in: db) }
        Log.library.info("iCloud identities: \(resolved.count) of \(targets.count)")
    }

    // MARK: Checksums

    /// Takes checksums from the server's upload records where the photo is provably the
    /// same version: same iCloud identity, same capture time and same edit time.
    @discardableResult
    public func reconcileChecksums() async throws -> Int {
        let ownerID = ownerID
        let candidates = try await database.reader.read { db in try LocalStore.cloudIdCandidates(ownerID: ownerID, in: db) }
        let matches = candidates.filter(Self.isSameVersion)
        guard !matches.isEmpty else { return 0 }
        try await database.writer.write { db in
            for match in matches {
                try LocalStore.setChecksum(match.remoteChecksum, source: .cloudId, id: match.localID, modifiedAt: match.modifiedAt, in: db)
            }
        }
        return matches.count
    }

    static func isSameVersion(_ candidate: CloudIdCandidate) -> Bool {
        guard let created = candidate.createdAt,
              let remoteCreated = candidate.remoteCreatedAt.flatMap(Self.parseDate),
              abs(created.timeIntervalSince(remoteCreated)) < 1 else { return false }
        switch (candidate.adjustmentTime, candidate.remoteAdjustmentTime.flatMap(Self.parseDate)) {
        case (nil, nil): return true
        case let (local?, remote?): return abs(local.timeIntervalSince(remote)) < 1
        default: return false
        }
    }

    /// The official app has written these as UTC ("…Z") and, in older versions, as local
    /// time without an offset; both are read.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Hashes photos still without a checksum, newest first, two at a time. Without
    /// `allowNetwork`, photos whose original is only in iCloud are skipped (marked).
    public func hashPending(limit: Int = 500, allowNetwork: Bool = false) async -> HashReport {
        var report = HashReport()
        guard Self.canRead else { return report }
        let pending = (try? await database.reader.read { db in try LocalStore.needingChecksum(limit: limit, in: db) }) ?? []
        let database = database
        await withTaskGroup(of: (String, Result<String, ChecksumError>, Date?).self) { group in
            var iterator = pending.makeIterator()
            func addNext() -> Bool {
                guard let record = iterator.next() else { return false }
                group.addTask(priority: .utility) {
                    (record.id, await Self.computeChecksum(localID: record.id, allowNetwork: allowNetwork), record.modifiedAt)
                }
                return true
            }
            for _ in 0..<2 { _ = addNext() }
            while let (id, result, modifiedAt) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                switch result {
                case .success(let checksum):
                    try? await database.writer.write { db in
                        try LocalStore.setChecksum(checksum, source: .hashed, id: id, modifiedAt: modifiedAt, in: db)
                    }
                    report.hashed += 1
                case .failure(let error):
                    try? await database.writer.write { db in try LocalStore.setHashError(error.code, id: id, in: db) }
                    if error == .notOnPhone { report.inCloudOnly += 1 } else { report.failed += 1 }
                }
                _ = addNext()
            }
        }
        if report.hashed > 0 { onChange?() }
        return report
    }

    /// The checksum of the file a backup of this asset would upload.
    public static func computeChecksum(localID: String, allowNetwork: Bool) async -> Result<String, ChecksumError> {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            return .failure(.assetGone)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = ResourceSelection.uploadResource(among: resources, mediaType: asset.mediaType) else {
            return .failure(.noUploadResource)
        }
        do {
            return .success(try await ResourceHashing.checksum(of: resource, allowNetwork: allowNetwork))
        } catch let error as ChecksumError {
            return .failure(error)
        } catch {
            return .failure(.photoKit(error.localizedDescription))
        }
    }

    /// PLAN.md D5 check: re-hashes phone photos whose checksum came from the official
    /// app's upload records and compares. Every one must match, or backups would duplicate.
    public func verifyMatchedChecksums(limit: Int) async -> ChecksumVerification {
        var result = ChecksumVerification()
        let rows: [(id: String, checksum: String)] = (try? await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, checksum FROM localAsset WHERE checksumSource = 'cloudId' ORDER BY random() LIMIT ?", arguments: [limit])
                .map { (id: $0["id"], checksum: $0["checksum"]) }
        }) ?? []
        for (id, expected) in rows {
            if Task.isCancelled { break }
            switch await Self.computeChecksum(localID: id, allowNetwork: false) {
            case .success(let actual):
                if actual == expected {
                    result.matched += 1
                } else {
                    result.mismatches.append(.init(localID: id, expected: expected, actual: actual, resources: Self.resourceSummary(localID: id)))
                }
            case .failure(.notOnPhone):
                result.onlyInCloud += 1
            case .failure(let error):
                result.errors.append("\(id): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func resourceSummary(localID: String) -> String {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return "gone" }
        return PHAssetResource.assetResources(for: asset)
            .map { "\($0.type.rawValue)\($0.isCurrent ? "*" : "")" }
            .joined(separator: ",")
    }

    /// Clears "only in iCloud" marks so those photos are hashed again (when downloading is allowed).
    public func retryCloudOnly() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE localAsset SET hashError = NULL WHERE hashError = ?", arguments: [ChecksumError.notOnPhone.code])
        }
    }

    // MARK: Albums (backup selection)

    /// The phone's albums for choosing what to back up: user albums and the main system ones.
    public static func albums() -> [PhoneAlbum] {
        var albums: [PhoneAlbum] = []
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        func add(_ collections: PHFetchResult<PHAssetCollection>) {
            collections.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: options).count
                guard count > 0 else { return }
                albums.append(PhoneAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album", count: count,
                                         isSystem: collection.assetCollectionType == .smartAlbum))
            }
        }
        for subtype in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumScreenshots, .smartAlbumSelfPortraits, .smartAlbumVideos] {
            add(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil))
        }
        add(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
        return albums
    }

    /// Assets in the backup scope: everything (nil) unless albums are chosen; minus excluded albums.
    public static func assetIDs(including: [String], excluding: [String]) -> Set<String>? {
        func ids(in albumIDs: [String]) -> Set<String> {
            var result = Set<String>()
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
            collections.enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
            }
            return result
        }
        guard !including.isEmpty || !excluding.isEmpty else { return nil }
        var scope: Set<String>
        if including.isEmpty {
            scope = []
            PHAsset.fetchAssets(with: fetchOptions()).enumerateObjects { asset, _, _ in scope.insert(asset.localIdentifier) }
        } else {
            scope = ids(in: including)
        }
        return scope.subtracting(ids(in: excluding))
    }

    // MARK: Change token

    private func storedToken() async throws -> PHPersistentChangeToken? {
        guard let text = try await database.reader.read({ db in try SyncState.value(.photoLibraryChangeToken, in: db) }),
              let data = Data(base64Encoded: text) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func saveToken(_ token: PHPersistentChangeToken) async throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        try await database.writer.write { db in try SyncState.set(.photoLibraryChangeToken, data.base64EncodedString(), in: db) }
    }
}

public struct ChecksumVerification: Sendable, Equatable {
    public struct Mismatch: Sendable, Equatable {
        public let localID: String
        public let expected: String
        public let actual: String
        /// Resource type numbers, "*" marking the current one.
        public let resources: String
    }

    public var matched = 0
    public var mismatches: [Mismatch] = []
    public var onlyInCloud = 0
    public var errors: [String] = []

    public var checked: Int { matched + mismatches.count }
    public var summary: String {
        "\(matched) of \(checked) match (\(onlyInCloud) skipped: only in iCloud, \(errors.count) errors)"
    }
}

public struct PhoneAlbum: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let count: Int
    public let isSystem: Bool
}

public struct HashReport: Sendable, Equatable {
    public var hashed = 0
    public var inCloudOnly = 0
    public var failed = 0
}

extension ChecksumError {
    /// Stored in `localAsset.hashError`.
    var code: String {
        switch self {
        case .notOnPhone: "notOnPhone"
        case .noUploadResource: "noUploadResource"
        case .assetGone: "assetGone"
        case .photoKit(let message): "photoKit: \(message)"
        }
    }
}

extension PHAsset {
    /// When the photo was last edited on the phone (private key; the official app reads it the same way).
    public var photosEditTimestamp: Date? {
        guard responds(to: NSSelectorFromString("adjustmentTimestamp")) else { return nil }
        return value(forKey: "adjustmentTimestamp") as? Date
    }
}

/// Forwards PhotoKit change notifications.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler()
    }
}
