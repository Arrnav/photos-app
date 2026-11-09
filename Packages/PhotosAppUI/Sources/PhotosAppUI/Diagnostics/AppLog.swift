import Core
import Foundation
import OSLog
import SwiftUI
import UIKit

/// One line of the app's own log (OSLog, subsystem `Log.subsystem`).
struct AppLogEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let date: Date
    let level: Level
    let category: String
    let message: String

    enum Level: String, Sendable, Comparable {
        case debug, info, notice, error, fault

        init(_ level: OSLogEntryLog.Level) {
            switch level {
            case .debug: self = .debug
            case .info: self = .info
            case .notice: self = .notice
            case .error: self = .error
            case .fault: self = .fault
            default: self = .notice
            }
        }

        private var rank: Int { [.debug, .info, .notice, .error, .fault].firstIndex(of: self) ?? 0 }
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    var line: String {
        "\(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))\t\(level.rawValue)\t\(category)\t\(message)"
    }

    init(id: Int, date: Date, level: Level, category: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    /// Reads a line written by `line`.
    init?(id: Int, line: Substring) {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let date = try? Date(String(parts[0]), strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) else { return nil }
        self.init(id: id, date: date, level: Level(rawValue: String(parts[1])) ?? .notice, category: String(parts[2]), message: String(parts[3]))
    }
}

/// The app's log for Settings › Logs: this launch from the system log store, earlier launches
/// from a file written each time the app goes to the background (iOS only lets an app read
/// its own current process's log). At most about 2 MB is kept.
enum AppLog {
    private static let maxBytes = 2 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.ethwood.photos.applog")
    nonisolated(unsafe) private static var savedUntil: Date?
    nonisolated(unsafe) private static var observer: (any NSObjectProtocol)?

    static var archiveURL: URL { DiagnosticLog.file("app.log") }

    /// Saves this launch's log whenever the app goes to the background.
    @MainActor static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            let task = UIApplication.shared.beginBackgroundTask(withName: "Save log")
            queue.async {
                save()
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    /// Entries of this launch from the log store, oldest first.
    static func currentLaunch(after date: Date? = nil) -> [AppLogEntry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = date.map { store.position(date: $0) }
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
        var result: [AppLogEntry] = []
        for case let entry as OSLogEntryLog in entries {
            if let date, entry.date <= date { continue }
            result.append(AppLogEntry(id: result.count, date: entry.date, level: AppLogEntry.Level(entry.level), category: entry.category, message: entry.composedMessage))
        }
        return result
    }

    /// Appends what this launch logged since the last save to the archive.
    private static func save() {
        let fresh = currentLaunch(after: savedUntil)
        guard let last = fresh.last else { return }
        savedUntil = last.date
        let text = fresh.map(\.line).joined(separator: "\n") + "\n"
        let url = archiveURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        trim(url)
    }

    /// Keeps the newest half when the archive grows past the limit.
    private static func trim(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[(newline + 1)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }

    /// Earlier launches (from the archive) then this launch, oldest first.
    static func allEntries() async -> [AppLogEntry] {
        await withCheckedContinuation { continuation in
            queue.async {
                var entries: [AppLogEntry] = []
                if let text = try? String(contentsOf: archiveURL, encoding: .utf8) {
                    for line in text.split(separator: "\n") {
                        if let entry = AppLogEntry(id: entries.count, line: line) { entries.append(entry) }
                    }
                }
                let saved = savedUntil
                for entry in currentLaunch(after: saved) {
                    entries.append(AppLogEntry(id: entries.count, date: entry.date, level: entry.level, category: entry.category, message: entry.message))
                }
                continuation.resume(returning: entries)
            }
        }
    }

    /// A text file to share: the app's version and phone, the log, then the share and action logs.
    static func exportFile(_ entries: [AppLogEntry]) throws -> URL {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var text = "Photos \(version), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "Exported \(Date().formatted(.iso8601))\n\n"
        text += entries.map(\.line).joined(separator: "\n")
        for name in ["actions.log", "share.log"] {
            if let extra = try? String(contentsOf: DiagnosticLog.file(name), encoding: .utf8), !extra.isEmpty {
                text += "\n\n== \(name)\n" + extra
            }
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "log-export", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let url = folder.appending(path: "Photos Log \(stamp).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Deletes the saved logs (this launch's stays in the system until the app quits).
    static func clear() {
        queue.sync {
            savedUntil = currentLaunch().last?.date ?? .now
            for name in ["app.log", "actions.log", "share.log"] { try? FileManager.default.removeItem(at: DiagnosticLog.file(name)) }
        }
    }
}

/// Settings › Logs: what the app logged, newest first, filtered by area and level, shareable as a text file.
struct LogViewerView: View {
    @State private var entries: [AppLogEntry]?
    @State private var category = Category.all
    @State private var problemsOnly = false
    @State private var query = ""
    @State private var exportURL: URL?
    @State private var confirmClear = false

    enum Category: String, CaseIterable, Identifiable {
        case all, sync, backup, networking, library, other
        var id: Self { self }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .sync: String(localized: "Sync")
            case .backup: String(localized: "Backup")
            case .networking: String(localized: "Network")
            case .library: String(localized: "Library")
            case .other: String(localized: "Other")
            }
        }

        func matches(_ name: String) -> Bool {
            switch self {
            case .all: true
            case .other: !["sync", "backup", "networking", "library"].contains(name)
            default: name == rawValue
            }
        }
    }

    private var shown: [AppLogEntry] {
        (entries ?? []).reversed().filter { entry in
            category.matches(entry.category)
                && (!problemsOnly || entry.level >= .error)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Group {
            if let entries {
                let shown = shown
                if entries.isEmpty {
                    ContentUnavailableView("No Log Yet", systemImage: "doc.text", description: Text("What the app does is logged here as you use it."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(shown) { entry in
                        LogRow(entry: entry)
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .safeAreaInset(edge: .top) {
            Picker("Area", selection: $category) {
                ForEach(Category.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("Errors Only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    Button("Clear Saved Logs", systemImage: "trash", role: .destructive) { confirmClear = true }
                } label: {
                    Label("Options", systemImage: "line.3.horizontal.decrease")
                }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share Log", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .confirmationDialog("Clear the saved logs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Saved Logs", role: .destructive) {
                AppLog.clear()
                Task { await load() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let all = await AppLog.allEntries()
        entries = all
        exportURL = try? AppLog.exportFile(all)
    }
}

private struct LogRow: View {
    let entry: AppLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if entry.level >= .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.level == .fault ? .red : .orange)
                        .accessibilityLabel(entry.level == .fault ? "Fault" : "Error")
                }
                Text(entry.category.capitalized)
                    .fontWeight(.semibold)
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
