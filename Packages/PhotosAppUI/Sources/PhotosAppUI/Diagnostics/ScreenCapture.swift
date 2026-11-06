import UIKit

/// Development aid (launch argument `-ShareScreenSelfTest`): records the app's window as
/// JPEG frames in Library/Caches/selftest, to check animations and layout on a device.
@MainActor
enum ScreenCapture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-ShareScreenSelfTest") }

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "selftest", directoryHint: .isDirectory)
    }

    /// Prints at once (the console is a pipe, so stdout would be buffered) and keeps a copy in the folder.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("SHARETEST " + message + "\n").utf8))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "log.txt")
        let line = Data((message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Captures `count` frames, one every `interval`, named with the prefix and elapsed ms.
    static func record(_ prefix: String, in window: UIWindow?, count: Int, interval: TimeInterval = 1.0 / 30) {
        guard let window else { return }
        let start = CACurrentMediaTime()
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * interval) {
                let elapsed = Int((CACurrentMediaTime() - start) * 1000)
                snapshot(window, name: String(format: "%@-%03d-%05dms", prefix, index, elapsed))
            }
        }
    }

    static func snapshot(_ window: UIWindow, name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try? image.jpegData(compressionQuality: 0.6)?.write(to: folder.appending(path: name + ".jpg"))
    }

    /// Prints the frames of a view tree (window coordinates), for checking layout.
    static func dump(_ view: UIView, depth: Int = 0, maxDepth: Int = 4) {
        guard depth <= maxDepth else { return }
        let frame = view.convert(view.bounds, to: nil)
        log(String(repeating: "  ", count: depth) + "\(type(of: view)) \(frame.integral) alpha=\(view.alpha) hidden=\(view.isHidden)")
        for subview in view.subviews { dump(subview, depth: depth + 1, maxDepth: maxDepth) }
    }
}
