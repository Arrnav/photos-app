import Core
import Foundation

/// Raw image bytes on disk, one file per key, trimmed oldest-first to a byte limit.
/// Files are "touched" on read (at most once a day) so trimming keeps recently seen images.
public final class DiskCache: Sendable {
    public let directory: URL
    private let touchInterval: TimeInterval = 24 * 60 * 60

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        let shard = String(safe.prefix(2))
        return directory.appending(path: shard, directoryHint: .isDirectory).appending(path: safe)
    }

    public func data(for key: String) -> Data? {
        let url = url(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        touchIfStale(url)
        return data
    }

    public func store(_ data: Data, for key: String) {
        let url = url(for: key)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.media.error("Disk cache write failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    public func contains(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    /// Total bytes currently stored (only files whose name matches, if given).
    public func size(matching match: (String) -> Bool = { _ in true }) -> Int {
        files().filter { match($0.url.lastPathComponent) }.reduce(0) { $0 + $1.size }
    }

    /// Deletes least recently used files until the cache fits in `maxBytes`. Files `keeping`
    /// matches (by name) are never deleted and don't count towards the limit.
    @discardableResult
    public func trim(toBytes maxBytes: Int, keeping keep: (String) -> Bool = { _ in false }) -> Int {
        var entries = files().filter { !keep($0.url.lastPathComponent) }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return 0 }
        entries.sort { $0.date < $1.date }
        var removed = 0
        for entry in entries where total > maxBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
                removed += 1
            }
        }
        Log.media.info("Trimmed \(removed) cached files; \(total) bytes remain")
        return removed
    }

    private func files() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var result: [(URL, Int, Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            result.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    private func touchIfStale(_ url: URL) {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date.now.timeIntervalSince(date) > touchInterval
        else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
    }
}
