import UIKit

/// Liquid Glass controls for iOS 26, with a blurred-material
/// fallback on iOS 18–25.
@MainActor
enum Glass {
    /// Standard control height in the viewer (round buttons and capsules).
    static let controlHeight: CGFloat = 48

    static func effect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            return glass
        }
        return UIBlurEffect(style: .systemChromeMaterial)
    }

    /// Makes a view a capsule (glass uses the system corner configuration on iOS 26).
    static func makeCapsule(_ view: UIView) {
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .capsule()
        } else {
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
        }
    }

    /// Keeps the capsule radius right on iOS 18–25 (iOS 26 does it automatically).
    static func updateCapsuleRadius(_ view: UIView) {
        if #unavailable(iOS 26.0) {
            view.layer.cornerRadius = view.bounds.height / 2
        }
    }
}

/// A round glass button with an SF Symbol (back, more, share, delete).
final class GlassCircleButton: UIButton {
    init(symbol: String, label: String, pointSize: CGFloat = 19) {
        super.init(frame: .zero)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.background.visualEffect = UIBlurEffect(style: .systemChromeMaterial)
            configuration.background.backgroundColor = .clear
        }
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        self.configuration = configuration
        accessibilityLabel = label
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Glass.controlHeight),
            heightAnchor.constraint(equalToConstant: Glass.controlHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ symbol: String) {
        configuration?.image = UIImage(systemName: symbol)
    }
}

/// A glass capsule holding a row of plain buttons (Favourite and Info in the middle of the toolbar).
final class GlassButtonGroup: UIView {
    private let effectView = UIVisualEffectView(effect: Glass.effect())
    private let stack = UIStackView()

    init(buttons: [UIButton]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        Glass.makeCapsule(effectView)
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)
        buttons.forEach(stack.addArrangedSubview)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Glass.controlHeight),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        Glass.updateCapsuleRadius(effectView)
    }

    /// A plain symbol button sized for the group.
    static func button(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return button
    }
}

/// A glass capsule with arbitrary content (the title in the top bar).
final class GlassCapsuleView: UIView {
    private let effectView = UIVisualEffectView(effect: Glass.effect())
    var contentView: UIView { effectView.contentView }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        Glass.makeCapsule(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        Glass.updateCapsuleRadius(effectView)
    }
}
