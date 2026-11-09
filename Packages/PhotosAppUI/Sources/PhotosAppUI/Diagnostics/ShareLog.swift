import Foundation

/// A small log of what sharing did (files prepared, what each destination was given, how the
/// share ended), kept in Library/Caches/diagnostics/share.log so it can be read after a
/// problem (`devicectl device copy from ... --source Library/Caches/diagnostics`).
enum ShareLog {
    static func write(_ message: String) { DiagnosticLog.write(message, to: "share.log") }

    static func size(of url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        return bytes < 0 ? "missing" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Delete, recover, hide: what was asked, what iOS and the server answered (actions.log).
enum ActionLog {
    static func write(_ message: String) { DiagnosticLog.write(message, to: "actions.log") }
}

/// Append-only logs in Library/Caches/diagnostics, each at most 512 KB.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "com.ethwood.photos.diagnosticlog")
    private static let maxBytes = 512 * 1024

    static func file(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "diagnostics", directoryHint: .isDirectory)
            .appending(path: name)
    }

    static func write(_ message: String, to name: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        queue.async {
            let url = file(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
