import Core
import Foundation

/// The app's temporary files. Shares, exports, edits and downloads write working copies
/// there; anything left from an earlier run (the app was closed mid-share, or a folder was
/// never removed) is deleted at launch, when nothing can still be using it. iOS clears an
/// app's temporary folder only now and then, and a shared 4K video can be gigabytes.
enum TempFiles {
    /// Our working folders, and the share sheet's own copies of shared files.
    private static let prefixes = [
        "share-", "phone-export-", "original-", "edit-", "duplicate-", "selftest-", "video-test-",
        "log-export", "airplay-clips", "render.", ".com.apple.ShareSheet.Activity.", "TemporaryItems",
    ]

    /// Deletes leftovers in the background; logs what was freed.
    static func sweepLeftovers() {
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
            guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
            var freed: Int64 = 0, removed = 0
            for name in names where prefixes.contains(where: name.hasPrefix) {
                let url = root.appending(path: name)
                freed += size(of: url)
                if (try? manager.removeItem(at: url)) != nil { removed += 1 }
            }
            if removed > 0 {
                Log.ui.notice("Removed \(removed) leftover temporary items (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file), privacy: .public))")
            }
        }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
