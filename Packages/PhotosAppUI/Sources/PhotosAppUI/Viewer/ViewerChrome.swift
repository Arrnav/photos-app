import UIKit

/// A container that only takes touches on its subviews, so taps between the
/// floating glass controls reach the photo.
class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.alpha > 0.01 && $0.point(inside: convert(point, to: $0), with: event) }
    }
}

/// Back button, title capsule (place, or date; then day and time) and the "more"
/// menu, floating in Liquid Glass for iOS 26.
final class ViewerTopBar: PassthroughView {
    let backButton = GlassCircleButton(symbol: "chevron.backward", label: String(localized: "Back to Library"))
    let menuButton = GlassCircleButton(symbol: "ellipsis", label: String(localized: "More"))
    private let titleCapsule = GlassCapsuleView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        menuButton.showsMenuAsPrimaryAction = true

        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 22)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        subtitleLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 13, weight: .medium), maximumPointSize: 17)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .secondaryLabel
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .center
        titles.translatesAutoresizingMaskIntoConstraints = false
        titleCapsule.contentView.addSubview(titles)
        titleCapsule.isAccessibilityElement = true
        titleCapsule.accessibilityTraits = .header

        for view in [backButton, menuButton, titleCapsule] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleCapsule.heightAnchor.constraint(equalToConstant: Glass.controlHeight),
            titleCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 10),
            titleCapsule.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -10),
            titles.centerYAnchor.constraint(equalTo: titleCapsule.contentView.centerYAnchor),
            titles.leadingAnchor.constraint(equalTo: titleCapsule.contentView.leadingAnchor, constant: 22),
            titles.trailingAnchor.constraint(equalTo: titleCapsule.contentView.trailingAnchor, constant: -22),
            heightAnchor.constraint(equalToConstant: Glass.controlHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTitle(_ title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        titleCapsule.accessibilityLabel = "\(title), \(subtitle)"
    }
}

/// Share (left), Favourite and Info in a capsule (middle), Delete (right).
final class ViewerBottomBar: PassthroughView {
    let shareButton = GlassCircleButton(symbol: "square.and.arrow.up", label: String(localized: "Share"))
    let deleteButton = GlassCircleButton(symbol: "trash", label: String(localized: "Delete"))
    let favoriteButton = GlassButtonGroup.button("heart", label: String(localized: "Favourite"))
    let infoButton = GlassButtonGroup.button("info.circle", label: String(localized: "Info"))
    let editButton = GlassButtonGroup.button("slider.horizontal.3", label: String(localized: "Edit"))
    private lazy var middle = GlassButtonGroup(buttons: [favoriteButton, infoButton, editButton])

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [shareButton, middle, deleteButton] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            shareButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            shareButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            middle.centerXAnchor.constraint(equalTo: centerXAnchor),
            middle.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Glass.controlHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Recently Deleted: only Delete (red) and Recover (blue) capsules.
    private(set) lazy var purgeButton = Self.textButton(String(localized: "Delete"), color: .systemRed)
    private(set) lazy var recoverButton = Self.textButton(String(localized: "Recover"), color: .tintColor)

    func showTrashActions() {
        for view in [shareButton, middle, deleteButton] { view.isHidden = true }
        for button in [purgeButton, recoverButton] { addSubview(button) }
        NSLayoutConstraint.activate([
            purgeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            purgeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            recoverButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            recoverButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static func textButton(_ title: String, color: UIColor) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.background.visualEffect = UIBlurEffect(style: .systemChromeMaterial)
            configuration.background.backgroundColor = .clear
        }
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]))
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Glass.controlHeight).isActive = true
        return button
    }

    func setFavorite(_ isFavorite: Bool) {
        favoriteButton.configuration?.image = UIImage(systemName: isFavorite ? "heart.fill" : "heart")
        favoriteButton.accessibilityLabel = isFavorite ? String(localized: "Remove from Favourites") : String(localized: "Favourite")
        favoriteButton.accessibilityTraits = isFavorite ? [.button, .selected] : .button
    }

    /// A photo from a library someone shares with you: view, share and save only.
    func setChangeable(_ changeable: Bool) {
        for button in [favoriteButton, editButton] as [UIButton] { button.isEnabled = changeable }
        deleteButton.isEnabled = changeable
        deleteButton.alpha = changeable ? 1 : 0.35
    }

    func setInfoShown(_ shown: Bool) {
        infoButton.configuration?.image = UIImage(systemName: shown ? "info.circle.fill" : "info.circle")
        infoButton.accessibilityTraits = shown ? [.button, .selected] : .button
    }
}
