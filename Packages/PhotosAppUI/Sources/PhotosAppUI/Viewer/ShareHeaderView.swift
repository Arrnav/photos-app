import SwiftUI
import UIKit

/// Top of the share screen: thumbnail, "1 Photo Selected",
/// "Location Included", Options, and a close button.
final class ShareHeaderView: PassthroughView {
    let closeButton = GlassCircleButton(symbol: "xmark", label: String(localized: "Close"))
    let optionsButton = UIButton(type: .system)
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let locationLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 10
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.backgroundColor = .systemGray5
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 24)
        titleLabel.adjustsFontForContentSizeCategory = true
        locationLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 20)
        locationLabel.adjustsFontForContentSizeCategory = true
        locationLabel.textColor = .secondaryLabel

        var options = UIButton.Configuration.gray()
        options.title = String(localized: "Options")
        options.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        options.imagePlacement = .trailing
        options.imagePadding = 4
        options.cornerStyle = .capsule
        options.baseForegroundColor = .label
        options.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 12)
        optionsButton.configuration = options

        let text = UIStackView(arrangedSubviews: [titleLabel, locationLabel, optionsButton])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(10, after: locationLabel)
        text.translatesAutoresizingMaskIntoConstraints = false

        for view in [thumbnail, text, closeButton] as [UIView] { addSubview(view) }
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            thumbnail.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumbnail.widthAnchor.constraint(equalToConstant: 60),
            thumbnail.heightAnchor.constraint(equalToConstant: 60),
            text.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 14),
            text.topAnchor.constraint(equalTo: thumbnail.topAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// When the share options are pulled up, the location line goes.
    func setCompact(_ compact: Bool) {
        locationLabel.isHidden = compact
        locationLabel.alpha = compact ? 0 : 1
    }

    func update(photos: Int, videos: Int, includesLocation: Bool, hasLocation: Bool, thumbnail image: UIImage?) {
        let total = photos + videos
        switch (photos, videos) {
        case (0, 0): titleLabel.text = String(localized: "Select Items")
        case (_, 0): titleLabel.text = photos == 1 ? String(localized: "1 Photo Selected") : String(localized: "\(photos) Photos Selected")
        case (0, _): titleLabel.text = videos == 1 ? String(localized: "1 Video Selected") : String(localized: "\(videos) Videos Selected")
        default: titleLabel.text = String(localized: "\(total) Items Selected")
        }
        let symbol = NSTextAttachment(image: UIImage(systemName: includesLocation && hasLocation ? "location.fill" : "location.slash")!.withTintColor(.secondaryLabel))
        let text = NSMutableAttributedString(attachment: symbol)
        let phrase = !hasLocation ? String(localized: "No Location") : includesLocation ? String(localized: "Location Included") : String(localized: "No Location")
        text.append(NSAttributedString(string: " \(phrase)"))
        locationLabel.attributedText = text
        thumbnail.image = image
    }
}

/// Share › Options.
struct ShareOptionsView: View {
    @State var options: ShareOptions
    let onChange: (ShareOptions) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Include") {
                    Toggle("Location", isOn: $options.includeLocation)
                }
                Section {
                    Picker("Format", selection: $options.format) {
                        Text("Automatic").tag(ShareOptions.Format.automatic)
                        Text("Current").tag(ShareOptions.Format.current)
                        Text("Most Compatible").tag(ShareOptions.Format.mostCompatible)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Format")
                } footer: {
                    Text("Choose Automatic for the best format for the destination or Current to prevent file format conversions. Photos and videos may convert to JPEG, PNG and H.264 formats if you choose Most Compatible.")
                }
                Section {
                    Toggle("All Photos Data", isOn: $options.allPhotosData)
                } header: {
                    Text("AirDrop & Shared Albums Only")
                } footer: {
                    Text("Original-quality files will include edit history and metadata like location, depth information and captions. The recipient can view the current version and modify any edits.")
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .onChange(of: options) { _, new in onChange(new) }
        }
    }
}
