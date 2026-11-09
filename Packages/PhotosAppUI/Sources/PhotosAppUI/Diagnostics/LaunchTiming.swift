import Core
import Darwin
import Foundation
import QuartzCore

/// Time from the process starting (as the kernel recorded it, so it includes iOS loading
/// the app) to the first grid of photos on screen. Logged every launch (Settings › Logs);
/// with `-LaunchTiming` also written to the console.
enum LaunchTiming {
    nonisolated(unsafe) private static var reported = false
    nonisolated(unsafe) private static var marks: [String] = []
    private static let lock = NSLock()

    /// Records how long after the process started a step finished (shown with the result).
    static func mark(_ name: String) {
        guard !reported, let start = processStart else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        lock.withLock { marks.append("\(name) \(ms)") }
    }

    static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Call when the first photos are laid out; measured once that frame has been committed.
    @MainActor static func firstGridShown(items: Int) {
        guard !reported else { return }
        mark("cells")
        reported = true
        // The next turn of the main run loop comes after this frame has been committed.
        DispatchQueue.main.async {
            guard let start = processStart else { return }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Log.ui.notice("Launch: first grid frame \(ms) ms after process start (\(items) items)")
            if ProcessInfo.processInfo.arguments.contains("-LaunchTiming") {
                let steps = lock.withLock { marks.joined(separator: ", ") }
                FileHandle.standardError.write(Data("LAUNCHTIMING first grid \(ms) ms, \(items) items [\(steps)]\n".utf8))
            }
        }
    }

    /// With `-LaunchTiming`: whether the grid still shows the newest photos once the
    /// first frame is up and again after the database's own list has replaced the cached one.
    @MainActor static func checkPosition(_ atBottom: @escaping @MainActor () -> Bool) {
        guard ProcessInfo.processInfo.arguments.contains("-LaunchTiming") else { return }
        for delay in [0.1, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                FileHandle.standardError.write(Data("LAUNCHTIMING at newest after \(delay) s: \(atBottom())\n".utf8))
            }
        }
    }
}
