import Darwin
import QuartzCore
import UIKit

/// Development aid (launch argument `-ScrollSelfTest`): scrolls the Library grid (only the
/// Library: no albums, no photo opened, nothing saved) from the newest photos to the oldest
/// and back at a fast-flick speed, then logs dropped frames and memory.
@MainActor
final class ScrollSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-ScrollSelfTest") }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data(("SCROLLTEST " + text + "\n").utf8))
    }

    private var link: CADisplayLink?
    private weak var grid: UICollectionView?
    private var direction: CGFloat = -1
    private var speed: CGFloat = 5000 // points per second, a fast flick
    private var lastTimestamp: CFTimeInterval = 0
    private var expected: CFTimeInterval = 1 / 60
    private var frames = 0
    private var hitches = 0
    private var hitchTime: CFTimeInterval = 0
    private var longest: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var peakMemory = 0
    private var passes = 0
    private var finished: CheckedContinuation<Void, Never>?

    static func run() async {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let grid = largestCollectionView(in: window) else { return say("no grid") }
        let test = ScrollSelfTest()
        test.grid = grid
        say("start: \(grid.numberOfItems(inSection: 0)) items, content \(Int(grid.contentSize.height)) pt, memory \(memoryMB()) MB, max fps \(UIScreen.main.maximumFramesPerSecond)")
        await test.scroll()
    }

    private func scroll() async {
        expected = 1 / Double(UIScreen.main.maximumFramesPerSecond)
        peakMemory = Self.memoryMB()
        await withCheckedContinuation { continuation in
            finished = continuation
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let grid else { return stop() }
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            started = link.timestamp
            return
        }
        let delta = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        frames += 1
        // A frame that took more than 1.5 frame intervals: at least one frame was dropped.
        if delta > expected * 1.5 {
            hitches += 1
            hitchTime += delta - expected
        }
        longest = max(longest, delta)
        if frames % 30 == 0 { peakMemory = max(peakMemory, Self.memoryMB()) }

        let top = -grid.adjustedContentInset.top
        let bottom = max(top, grid.contentSize.height - grid.bounds.height + grid.adjustedContentInset.bottom)
        var y = grid.contentOffset.y + direction * speed * CGFloat(delta)
        if y <= top || y >= bottom {
            y = min(max(y, top), bottom)
            direction = -direction
            passes += 1
        }
        grid.contentOffset.y = y
        if passes >= 2 || link.timestamp - started > 40 { stop() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        let seconds = lastTimestamp - started
        Self.say("done: \(frames) frames in \(String(format: "%.1f", seconds)) s, \(hitches) hitches, "
            + "hitch time \(String(format: "%.1f", seconds > 0 ? hitchTime * 1000 / seconds : 0)) ms/s, longest frame \(Int(longest * 1000)) ms, "
            + "memory peak \(peakMemory) MB, now \(Self.memoryMB()) MB")
        finished?.resume()
        finished = nil
    }

    /// The app's memory footprint as iOS counts it for jetsam.
    static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func largestCollectionView(in view: UIView) -> UICollectionView? {
        var best: UICollectionView?
        func visit(_ view: UIView) {
            if let grid = view as? UICollectionView, grid.numberOfSections > 0,
               grid.numberOfItems(inSection: 0) > (best?.numberOfItems(inSection: 0) ?? 0) { best = grid }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
