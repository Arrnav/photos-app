import CloudCore
import Core
import Foundation
import GRDB
import MediaCache
import Observation
import Persistence

/// What to keep on this iPhone for use without a connection (Cloud Server Settings › Storage).
enum OfflineSettings {
    /// Fetch the grid thumbnail of every Cloud photo, not just those already seen.
    static var downloadsAllThumbnails: Bool {
        get { UserDefaults.standard.object(forKey: "offline.allThumbnails") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offline.allThumbnails") }
    }

    /// Keep the originals of favourites on the phone.
    static var keepsFavourites: Bool {
        get { UserDefaults.standard.bool(forKey: "offline.favourites") }
        set { UserDefaults.standard.set(newValue, forKey: "offline.favourites") }
    }

    /// Keep the originals of these Cloud albums on the phone.
    static var albumIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "offline.albums") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "offline.albums") }
    }
}

/// Progress of the offline downloads, for Settings.
@MainActor
@Observable
final class OfflineWork {
    struct Count: Equatable { var done = 0; var total = 0 }

    var thumbnails: Count?
    var originals: Count?
    var isRunning: Bool { task != nil }
    /// Why it's waiting, when it is (e.g. on mobile data).
    var waitingReason: String?
    @ObservationIgnored var task: Task<Void, Never>?
}

extension LibrarySession {
    /// Runs Download All Thumbnails and Keep Offline when connected over Wi-Fi (not mobile data,
    /// a hotspot or Low Data Mode). Downloads wait whenever something on screen needs the server.
    @discardableResult
    func runOfflineWork() -> Task<Void, Never>? {
        if let task = offlineWork.task { return task }
        guard connection != nil, !needsSignIn else { return nil }
        guard offlineNetworkAllowed() else {
            offlineWork.waitingReason = String(localized: "Waiting for Wi-Fi")
            return nil
        }
        offlineWork.waitingReason = nil
        let task = Task { [weak self] in
            await self?.downloadAllThumbnails()
            await self?.syncKeptOffline()
            self?.offlineWork.task = nil
        }
        offlineWork.task = task
        return task
    }

    /// Stops the current pass (a setting changed, or the network did); the next one picks up.
    func restartOfflineWork() {
        offlineWork.task?.cancel()
        offlineWork.task = nil
        runOfflineWork()
    }

    private func offlineNetworkAllowed() -> Bool {
        guard let path = network.current else { return true }
        return path.isSatisfied && !path.isExpensive && !path.isConstrained
    }

    private func shouldContinueOffline() -> Bool {
        if Task.isCancelled || connection == nil { return false }
        if !offlineNetworkAllowed() {
            offlineWork.waitingReason = String(localized: "Waiting for Wi-Fi")
            return false
        }
        return true
    }

    // MARK: Thumbnails

    private func downloadAllThumbnails() async {
        guard OfflineSettings.downloadsAllThumbnails else { offlineWork.thumbnails = nil; return }
        let me = account.userID
        // Cloud items in the Library, Archive and shared libraries shown in the Library. Items on
        // this iPhone show its own thumbnails; Hidden stays behind Face ID.
        let rows = (try? await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.thumbhash FROM remoteAsset a
                WHERE a.deletedAt IS NULL AND a.thumbhash IS NOT NULL AND a.visibility IN ('timeline', 'archive')
                  AND (a.ownerId = ?1 OR a.ownerId IN (SELECT sharedById FROM partner WHERE sharedWithId = ?1 AND inTimeline = 1))
                  AND NOT EXISTS (SELECT 1 FROM localAsset l WHERE l.checksum = a.checksum AND l.isHidden = 0)
                ORDER BY a.localDateTime DESC
                """, arguments: [me]).map { (id: $0[0] as String, revision: $0[1] as String?) }
        }) ?? []
        let pipeline = pipeline
        let missing = await Task.detached(priority: .utility) {
            rows.filter { !pipeline.isOnDisk(assetID: $0.id, size: .thumbnail) }
        }.value
        var count = OfflineWork.Count(done: rows.count - missing.count, total: rows.count)
        offlineWork.thumbnails = count
        guard !missing.isEmpty else { return }
        Log.media.info("Download All Thumbnails: \(missing.count) of \(rows.count) to fetch")
        var next = missing.makeIterator()
        var failed = 0
        await withTaskGroup(of: Bool.self) { group in
            // Two at a time, behind anything the screen is waiting for (the limit is four).
            for _ in 0..<2 {
                guard let item = next.next() else { break }
                group.addTask { await pipeline.prefetch(assetID: item.id, size: .thumbnail, revision: item.revision, priority: .background) }
            }
            while let ok = await group.next() {
                count.done += ok ? 1 : 0
                failed += ok ? 0 : 1
                if count.done % 20 == 0 { offlineWork.thumbnails = count }
                guard shouldContinueOffline() else { group.cancelAll(); break }
                if let item = next.next() {
                    group.addTask { await pipeline.prefetch(assetID: item.id, size: .thumbnail, revision: item.revision, priority: .background) }
                }
            }
        }
        offlineWork.thumbnails = count
        Log.media.info("Download All Thumbnails: \(count.done) of \(count.total) on the phone, \(failed) failed")
    }

    // MARK: Keep Offline

    /// Downloads what should be kept offline and lets go of what no longer should.
    private func syncKeptOffline() async {
        guard shouldContinueOffline() else { return }
        let wanted = await wantedOffline()
        let kept = originals.offlineAssetIDs()
        let unwanted = kept.subtracting(wanted.keys)
        if !unwanted.isEmpty {
            await originals.removeOffline(unwanted)
            Log.media.info("Keep Offline: released \(unwanted.count) originals")
        }
        let toFetch = wanted.filter { !kept.contains($0.key) }.sorted { $0.key < $1.key }
        var count = OfflineWork.Count(done: wanted.count - toFetch.count, total: wanted.count)
        offlineWork.originals = wanted.isEmpty ? nil : count
        for (id, name) in toFetch {
            guard shouldContinueOffline() else { break }
            do {
                try await originals.keepOffline(assetID: id, fileName: name)
                count.done += 1
                offlineWork.originals = count
            } catch is CancellationError {
                break
            } catch {
                Log.media.error("Keep Offline \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Asset ID → file name for everything Keep Offline covers that isn't on this iPhone
    /// (a Live Photo brings its motion part).
    private func wantedOffline() async -> [String: String] {
        var wanted: [String: String] = [:]
        let me = account.userID
        if OfflineSettings.keepsFavourites {
            let rows = (try? await database.reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT a.id, a.originalFileName, m.id AS motionId, m.originalFileName AS motionName FROM remoteAsset a
                    LEFT JOIN remoteAsset m ON m.id = a.livePhotoVideoId
                    WHERE a.ownerId = ? AND a.isFavorite = 1 AND a.deletedAt IS NULL AND a.visibility IN ('timeline', 'archive')
                      AND NOT EXISTS (SELECT 1 FROM localAsset l WHERE l.checksum = a.checksum)
                    """, arguments: [me]).map { row -> [(String, String)] in
                    var files = [(row["id"] as String, row["originalFileName"] as String)]
                    if let motion: String = row["motionId"] { files.append((motion, row["motionName"] ?? "\(motion).MOV")) }
                    return files
                }
            }) ?? []
            for (id, name) in rows.joined() { wanted[id] = name }
        }
        guard let connection else { return wanted }
        for albumID in OfflineSettings.albumIDs {
            var query = CloudSearchQuery()
            query.albumID = albumID
            guard let assets = try? await connection.search(query, limit: 20_000) else { continue }
            let checksums = assets.compactMap(\.checksum)
            let onPhone = (try? await database.reader.read { db in
                try Set(String.fetchAll(db, sql: "SELECT checksum FROM localAsset WHERE checksum IN (SELECT value FROM json_each(?))",
                                        arguments: [String(data: try JSONEncoder().encode(checksums), encoding: .utf8) ?? "[]"]))
            }) ?? []
            for asset in assets where !asset.isTrashed && !(asset.checksum.map(onPhone.contains) ?? false) {
                let name = asset.originalFileName ?? (asset.isVideo ? "\(asset.id).MOV" : "\(asset.id).HEIC")
                wanted[asset.id] = name
                if let motion = asset.livePhotoVideoID {
                    wanted[motion] = ((name as NSString).deletingPathExtension) + ".MOV"
                }
            }
        }
        return wanted
    }

    /// Bytes kept offline, and how many items.
    func offlineUsage() async -> (bytes: Int, items: Int) {
        await Task.detached { [originals] in (originals.offlineSize(), originals.offlineAssetIDs().count) }.value
    }

    /// The account's albums, to choose which to keep offline.
    func albumsForOffline() async -> [CloudAlbum] {
        guard let connection else { return [] }
        let own = (try? await connection.albums(shared: false)) ?? []
        let shared = (try? await connection.albums(shared: true)) ?? []
        var seen = Set<String>()
        return (own + shared).filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
