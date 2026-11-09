import UIKit

/// Fast-scroll handle on the right edge. Appears while scrolling, can be dragged
/// to jump through the library, and shows the month under the handle.
final class ScrubberView: UIView {
    /// Called while dragging with the fraction 0...1 of the scrollable range.
    var onScrub: ((CGFloat) -> Void)?
    var onScrubEnded: (() -> Void)?
    /// Supplies the label for a fraction (e.g. "June 2025").
    var labelForFraction: ((CGFloat) -> String?)?

    private let handle = UIView()
    private let bubble = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let bubbleLabel = UILabel()
    private let haptics = UISelectionFeedbackGenerator()
    private var hideWork: DispatchWorkItem?
    private var fraction: CGFloat = 0
    private var lastLabel: String?
    private(set) var isDragging = false

    private let handleSize = CGSize(width: 6, height: 44)
    private let touchWidth: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        handle.backgroundColor = .secondaryLabel
        handle.layer.cornerRadius = handleSize.width / 2
        addSubview(handle)

        bubble.layer.cornerRadius = 12
        bubble.clipsToBounds = true
        bubbleLabel.font = .preferredFont(forTextStyle: .headline)
        bubbleLabel.adjustsFontForContentSizeCategory = true
        bubbleLabel.textColor = .label
        bubbleLabel.textAlignment = .center
        bubble.contentView.addSubview(bubbleLabel)
        bubble.alpha = 0
        addSubview(bubble)

        alpha = 0
        isAccessibilityElement = false // VoiceOver users scroll with three fingers
        // A zero-delay press tracks the finger from touch-down, so the handle grabs instantly.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only the strip under the handle takes touches; the rest passes through to the grid.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard alpha > 0.01 else { return false }
        let strip = CGRect(x: bounds.width - touchWidth, y: handle.frame.minY - 20, width: touchWidth, height: handle.frame.height + 40)
        return isDragging || strip.contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHandle()
    }

    /// Updates the handle position from the scroll view (when not dragging).
    func scrollPositionChanged(fraction: CGFloat) {
        guard !isDragging else { return }
        self.fraction = min(max(fraction, 0), 1)
        layoutHandle()
        reveal()
    }

    private func layoutHandle() {
        let travel = max(0, bounds.height - handleSize.height)
        handle.frame = CGRect(
            x: bounds.width - handleSize.width - 3,
            y: travel * fraction,
            width: handleSize.width,
            height: handleSize.height
        )
        let size = bubbleLabel.intrinsicContentSize
        let bubbleSize = CGSize(width: size.width + 28, height: size.height + 16)
        bubble.frame = CGRect(
            x: handle.frame.minX - bubbleSize.width - 16,
            y: min(max(0, handle.frame.midY - bubbleSize.height / 2), bounds.height - bubbleSize.height),
            width: bubbleSize.width,
            height: bubbleSize.height
        )
        bubbleLabel.frame = bubble.bounds
    }

    private func reveal() {
        hideWork?.cancel()
        if alpha < 1 {
            UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            UIView.animate(withDuration: 0.3) { self.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    @objc private func drag(_ gesture: UIGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            isDragging = true
            haptics.prepare()
            UIView.animate(withDuration: 0.15) {
                self.bubble.alpha = 1
                self.handle.transform = CGAffineTransform(scaleX: 1.6, y: 1)
            }
            fallthrough
        case .changed:
            let travel = max(1, bounds.height - handleSize.height)
            fraction = min(max((location.y - handleSize.height / 2) / travel, 0), 1)
            updateBubble()
            layoutHandle()
            onScrub?(fraction)
        case .ended, .cancelled, .failed:
            isDragging = false
            onScrubEnded?()
            UIView.animate(withDuration: 0.2) {
                self.bubble.alpha = 0
                self.handle.transform = .identity
            }
            reveal()
        default:
            break
        }
    }

    private func updateBubble() {
        let text = labelForFraction?(fraction)
        if text != lastLabel {
            lastLabel = text
            bubbleLabel.text = text
            haptics.selectionChanged()
        }
    }
}
