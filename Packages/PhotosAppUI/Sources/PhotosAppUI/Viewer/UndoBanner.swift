import UIKit

/// "Moved to Trash · Undo" style message above the toolbar, hiding after a few seconds.
final class UndoBanner: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var hideWork: DispatchWorkItem?
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        alpha = 0
        isHidden = true

        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ message: String, actionTitle: String? = nil, duration: TimeInterval = 5, action: (() -> Void)? = nil) {
        label.text = message
        button.setTitle(actionTitle, for: .normal)
        button.isHidden = actionTitle == nil
        self.action = action
        isHidden = false
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: message)

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Changes the text without restarting the timer (e.g. download progress).
    func setMessage(_ message: String) {
        label.text = message
    }

    func hide() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.2) { self.alpha = 0 } completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        }
    }

    @objc private func tapped() {
        let action = self.action
        hide()
        action?()
    }
}
