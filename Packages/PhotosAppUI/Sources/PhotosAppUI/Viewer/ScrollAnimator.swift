import UIKit

/// Animates a scroll view's content offset frame by frame (ease-in-out), so the
/// scroll view keeps laying out cells along the way. A UIView block animation of
/// `contentOffset` lays out only for the final position, which made the outgoing
/// photo vanish mid-slide; `setContentOffset(_:animated:)` can't set its duration.
@MainActor
final class ScrollAnimator {
    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var start: CGPoint = .zero
    private var target: CGPoint = .zero
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.2
    private var completion: (() -> Void)?

    var isAnimating: Bool { displayLink != nil }

    func animate(_ scrollView: UIScrollView, to target: CGPoint, duration: CFTimeInterval, completion: (() -> Void)? = nil) {
        stop()
        self.scrollView = scrollView
        start = scrollView.contentOffset
        self.target = target
        self.duration = max(duration, 0.01)
        self.completion = completion
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops where it is (e.g. the user touched the pager again).
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        completion = nil
    }

    fileprivate func tick() {
        guard let scrollView else {
            stop()
            return
        }
        let t = min((CACurrentMediaTime() - startTime) / duration, 1)
        // Ease in-out (cubic).
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        scrollView.contentOffset = CGPoint(
            x: start.x + (target.x - start.x) * eased,
            y: start.y + (target.y - start.y) * eased
        )
        if t >= 1 {
            let done = completion
            stop()
            done?()
        }
    }

    /// CADisplayLink retains its target; the proxy avoids a cycle with the animator.
    /// The link is added to the main run loop, so ticks arrive on the main thread.
    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var owner: ScrollAnimator?
        init(_ owner: ScrollAnimator) { self.owner = owner }
        @objc func tick() { owner?.tick() }
    }
}
