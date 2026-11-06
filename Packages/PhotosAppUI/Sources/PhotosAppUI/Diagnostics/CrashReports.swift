import Core
import Foundation
import MetricKit

/// Keeps crash reports (with call stacks) that iOS hands to the app through MetricKit on
/// the next launch, so a rare crash can be diagnosed later from Cloud Server Settings ›
/// Diagnostics, even when the phone isn't connected to the Mac.
public final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = CrashReports()

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CrashReports", directoryHint: .isDirectory)
    }()

    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty || !(payload.hangDiagnostics ?? []).isEmpty {
            let name = payload.timeStampEnd.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            try? payload.jsonRepresentation().write(to: folder.appending(path: "\(name).json"))
            Log.ui.error("MetricKit delivered a crash/hang report (\(name, privacy: .public))")
        }
    }

    /// Saved reports, newest first.
    public func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// A one-line summary: exception type, signal and the top frames of the crashed thread.
    public func summary(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crashes = json["crashDiagnostics"] as? [[String: Any]], let crash = crashes.first,
              let meta = crash["diagnosticMetaData"] as? [String: Any] else { return url.lastPathComponent }
        let reason = [meta["exceptionType"], meta["signal"], meta["terminationReason"]].compactMap { $0.map { "\($0)" } }.joined(separator: " · ")
        return "\(url.deletingPathExtension().lastPathComponent): \(reason)"
    }
}
