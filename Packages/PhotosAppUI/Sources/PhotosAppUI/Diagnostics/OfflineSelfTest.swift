import GRDB
import Persistence
import SwiftUI
import UIKit

/// Development aid (`-OfflineSelfTest`): a small sample of Download All Thumbnails and Keep
/// Offline, ignoring the Wi-Fi rule (about 40 thumbnails and one original), plus a snapshot of
/// the settings. Nothing is left behind: the kept original goes back to the ordinary cache.
@MainActor
enum OfflineSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-OfflineSelfTest") }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data(("OFFLINETEST " + text + "\n").utf8))
    }

    static func run(session: LibrarySession) async {
        ScreenCapture.reset()
        let me = session.account.userID
        let rows = (try? await session.database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.thumbhash, a.originalFileName, a.type FROM remoteAsset a
                WHERE a.ownerId = ? AND a.deletedAt IS NULL AND a.thumbhash IS NOT NULL AND a.visibility = 'timeline'
                  AND NOT EXISTS (SELECT 1 FROM localAsset l WHERE l.checksum = a.checksum)
                ORDER BY a.localDateTime DESC
                """, arguments: [me]).map { (id: $0[0] as String, revision: $0[1] as String?, name: $0[2] as String, type: $0[3] as String) }
        }) ?? []
        let pipeline = session.pipeline
        let missing = await Task.detached { rows.filter { !pipeline.isOnDisk(assetID: $0.id, size: .thumbnail) } }.value
        say("Cloud-only items \(rows.count), thumbnails missing \(missing.count)")
        let sample = Array(missing.prefix(40))
        let start = Date()
        var fetched = 0
        for item in sample where await pipeline.prefetch(assetID: item.id, size: .thumbnail, revision: item.revision, priority: .background) {
            fetched += 1
        }
        let stillMissing = sample.filter { !pipeline.isOnDisk(assetID: $0.id, size: .thumbnail) }.count
        say("thumbnails: fetched \(fetched)/\(sample.count) in \(Int(Date().timeIntervalSince(start) * 1000)) ms, still missing \(stillMissing)")
        let usage = await session.thumbnailCacheSize()
        say("cache: thumbnails \(Formatting.bytes(usage.thumbnails)), previews \(Formatting.bytes(usage.previews)), keep thumbnails \(LibrarySession.keepsAllThumbnails)")

        // Keep Offline round trip on the newest Cloud-only photo.
        if let photo = rows.first(where: { $0.type == "IMAGE" }) {
            do {
                let before = session.originals.offlineAssetIDs().count
                try await session.originals.keepOffline(assetID: photo.id, fileName: photo.name)
                let file = session.originals.cachedFile(assetID: photo.id)
                say("keep offline: \(photo.name) → \(file?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent ?? "missing"), kept \(before) → \(session.originals.offlineAssetIDs().count)")
                let offline = await session.offlineUsage()
                say("kept on this iPhone: \(offline.items) item(s), \(Formatting.bytes(offline.bytes))")
                await session.originals.removeOffline([photo.id])
                let back = session.originals.cachedFile(assetID: photo.id)
                say("released → \(back?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent ?? "missing"), kept \(session.originals.offlineAssetIDs().count)")
            } catch {
                say("keep offline failed: \(error)")
            }
        }

        // The real job waits for Wi-Fi on mobile data and hotspots.
        let path = session.network.current
        session.runOfflineWork()
        say("network expensive \(path?.isExpensive ?? false), constrained \(path?.isConstrained ?? false); job running \(session.offlineWork.isRunning), waiting \(session.offlineWork.waitingReason ?? "-")")
        session.offlineWork.task?.cancel()
        session.offlineWork.task = nil

        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let root = window.rootViewController else { return say("done") }
        let host = UIHostingController(rootView: NavigationStack {
            List {
                OfflineSettingsSection(session: session)
                CacheSettingsSection(session: session)
            }
            .navigationTitle("Storage")
        })
        host.modalPresentationStyle = .fullScreen
        root.present(host, animated: false)
        try? await Task.sleep(for: .seconds(4))
        ScreenCapture.snapshot(window, name: "offline-settings")
        host.dismiss(animated: false)
        say("done")
    }
}
