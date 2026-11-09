import Core
import MediaCache
import Persistence
import Photos
import UIKit

/// One grid tile. Kept light because the 30-column level puts about 2,000 on
/// screen: badges are created only when needed and the VoiceOver label is
/// computed only when asked for.
final class PhotoGridCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoGridCell"

    enum Loading: Equatable {
        /// Fetch the thumbnail from the server if it isn't cached.
        case network
        /// Show only what's cached (dense levels); `loadThumbnailIfNeeded` fetches at rest.
        case cachedOnly(includingDisk: Bool)
    }

    /// Below this tile width, badges are hidden (they'd be unreadable).
    private static let badgeMinimumSide: CGFloat = 40

    private let imageView = UIImageView()
    private var overlay: BadgeOverlay?
    /// Blue check in select mode.
    private lazy var checkmark: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "checkmark.circle.fill")?
            .applyingSymbolConfiguration(.init(paletteColors: [.white, .systemBlue])))
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.25
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = .zero
        view.isHidden = true
        contentView.addSubview(view)
        return view
    }()
    private var isAspectFit = false
    private var isChecked = false

    private(set) var assetID: String?
    var currentImage: UIImage? { imageView.image }
    private var item: TimelineItem?
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var showsPreview = false
    private var showsThumbnail = false
    /// Photos on the phone load from PhotoKit (set by the grid).
    var phone: PhoneImages?
    /// Phone / Cloud / both badge (Settings › Show Status on Tiles).
    var showsStatus = true
    /// Centred text at the bottom ("15 days" in Recently Deleted).
    var caption: TileCaption?

    func setCaption(_ caption: TileCaption?) {
        guard caption != self.caption else { return }
        self.caption = caption
        updateOverlay()
    }
    private var phoneRequest: PHImageRequestID?
    private var phoneQuality = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Visible against the black background in dark mode, for items whose preview the server hasn't made yet.
        contentView.backgroundColor = .systemGray5
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.accessibilityIgnoresInvertColors = true
        contentView.addSubview(imageView)

        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityLabel: String? {
        get { item.map(Formatting.accessibilityLabel(for:)) }
        set {}
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        updateOverlay()
        if isChecked {
            let size = min(24, contentView.bounds.width * 0.4)
            checkmark.frame = CGRect(x: contentView.bounds.maxX - size - 5, y: contentView.bounds.maxY - size - 5, width: size, height: size)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        previewTask?.cancel()
        previewTask = nil
        phone?.cancel(phoneRequest)
        phoneRequest = nil
        phoneQuality = 0
        assetID = nil
        item = nil
        showsPreview = false
        showsThumbnail = false
        imageView.image = nil
    }

    /// Aspect Ratio Grid (whole photo, letterboxed) and the select-mode check.
    func setDisplay(aspectFit: Bool, selectable: Bool, selected: Bool) {
        if aspectFit != isAspectFit {
            isAspectFit = aspectFit
            imageView.contentMode = aspectFit ? .scaleAspectFit : .scaleAspectFill
            contentView.backgroundColor = aspectFit ? .clear : .systemGray5
        }
        let checked = selectable && selected
        if checked != isChecked || checkmark.isHidden == checked {
            isChecked = checked
            checkmark.isHidden = !checked
            setNeedsLayout()
        }
        accessibilityTraits = checked ? [.image, .button, .selected] : [.image, .button]
    }

    /// Shows the best image already in memory (preview, then thumbnail), otherwise
    /// the thumbhash placeholder, and loads the thumbnail if `loading` allows.
    func configure(
        with item: TimelineItem,
        placeholder: UIImage?,
        pipeline: RemoteImagePipeline,
        thumbnailPixelSize: Int,
        previewPixelSize: Int?,
        loading: Loading
    ) {
        if assetID != item.id {
            loadTask?.cancel()
            loadTask = nil
            previewTask?.cancel()
            previewTask = nil
            phone?.cancel(phoneRequest)
            phoneRequest = nil
            phoneQuality = 0
            showsPreview = false
            showsThumbnail = false
        }
        assetID = item.id
        self.item = item
        updateOverlay()

        // On the phone: PhotoKit (fast, offline, and nothing asked of the server).
        if let localID = item.localID, let phone {
            if phoneQuality == 0 { imageView.image = placeholder }
            if case .cachedOnly(false) = loading { return }
            requestPhoneImage(localID: localID, phone: phone, pixelSize: previewPixelSize ?? thumbnailPixelSize, quality: previewPixelSize == nil ? 1 : 2)
            return
        }

        if let previewPixelSize, let preview = pipeline.cachedImage(assetID: item.id, size: .preview, maxPixelSize: previewPixelSize) {
            imageView.image = UIImage(cgImage: preview)
            showsPreview = true
            return
        }
        if showsPreview || showsThumbnail { return }
        if let cached = pipeline.cachedImage(assetID: item.id, size: .thumbnail, maxPixelSize: thumbnailPixelSize) {
            imageView.image = UIImage(cgImage: cached)
            showsThumbnail = true
            return
        }
        imageView.image = placeholder

        switch loading {
        case .network:
            loadThumbnailIfNeeded(pipeline: pipeline, maxPixelSize: thumbnailPixelSize)
        case .cachedOnly(let includingDisk):
            if includingDisk {
                loadThumbnailIfNeeded(pipeline: pipeline, maxPixelSize: thumbnailPixelSize, diskOnly: true)
            }
        }
    }

    /// Asks PhotoKit for the tile image; `quality` 1 = thumbnail, 2 = big-tile preview.
    private func requestPhoneImage(localID: String, phone: PhoneImages, pixelSize: Int, quality: Int) {
        guard quality > phoneQuality, phoneRequest == nil || quality == 2 else { return }
        phone.cancel(phoneRequest)
        let id = assetID
        let size = CGSize(width: pixelSize, height: pixelSize)
        phoneRequest = phone.requestImage(localID: localID, pixelSize: size, fill: !isAspectFit, quality: quality == 2 ? .high : .fast) { [weak self] image, degraded in
            guard let self, self.assetID == id else { return }
            let first = self.phoneQuality == 0
            if !degraded {
                self.phoneQuality = quality
                self.phoneRequest = nil
            }
            if first {
                self.imageView.image = image
            } else if !degraded {
                self.crossfade(to: image)
            }
            self.showsThumbnail = true
        }
    }

    /// Loads the thumbnail (from disk, or the server unless `diskOnly`).
    func loadThumbnailIfNeeded(pipeline: RemoteImagePipeline, maxPixelSize: Int, diskOnly: Bool = false) {
        if let localID = item?.localID, let phone {
            requestPhoneImage(localID: localID, phone: phone, pixelSize: maxPixelSize, quality: 1)
            return
        }
        guard let id = assetID, !showsThumbnail, !showsPreview, loadTask == nil else { return }
        let revision = item?.thumbhash
        loadTask = Task { [weak self] in
            defer { if self?.assetID == id { self?.loadTask = nil } }
            do {
                let image: CGImage
                if diskOnly {
                    guard let cached = await pipeline.diskCachedImage(assetID: id, size: .thumbnail, maxPixelSize: maxPixelSize) else { return }
                    image = cached
                } else {
                    image = try await pipeline.image(assetID: id, size: .thumbnail, maxPixelSize: maxPixelSize, revision: revision)
                }
                guard let self, self.assetID == id, !self.showsPreview else { return }
                self.showsThumbnail = true
                self.crossfade(to: image)
            } catch {
                Self.logFailure(error, id: id, kind: "Thumbnail")
            }
        }
    }

    /// Replaces the thumbnail with the sharper server preview (big tiles, grid at rest).
    func upgradeToPreview(pipeline: RemoteImagePipeline, maxPixelSize: Int) {
        if let localID = item?.localID, let phone {
            requestPhoneImage(localID: localID, phone: phone, pixelSize: maxPixelSize, quality: 2)
            return
        }
        guard let id = assetID, !showsPreview, previewTask == nil else { return }
        let revision = item?.thumbhash
        previewTask = Task { [weak self] in
            defer { if self?.assetID == id { self?.previewTask = nil } }
            do {
                let image = try await pipeline.image(assetID: id, size: .preview, maxPixelSize: maxPixelSize, revision: revision)
                guard let self, self.assetID == id else { return }
                self.showsPreview = true
                self.loadTask?.cancel()
                self.crossfade(to: image)
            } catch {
                Self.logFailure(error, id: id, kind: "Preview")
            }
        }
    }

    private func updateOverlay() {
        let side = contentView.bounds.width
        let needsBadge = (item?.isVideo ?? false) || (item?.isFavorite ?? false) || showsStatus || caption != nil
        guard needsBadge, side >= Self.badgeMinimumSide, let item else {
            overlay?.isHidden = true
            return
        }
        let overlay = overlay ?? {
            let created = BadgeOverlay()
            contentView.addSubview(created)
            self.overlay = created
            return created
        }()
        overlay.isHidden = false
        overlay.frame = contentView.bounds
        overlay.configure(
            duration: item.isVideo ? Formatting.duration(milliseconds: item.durationMs) : nil,
            isFavorite: item.isFavorite,
            status: showsStatus ? TileStatus(item) : nil,
            caption: caption
        )
    }

    private func crossfade(to image: CGImage) {
        crossfade(to: UIImage(cgImage: image))
    }

    private func crossfade(to image: UIImage) {
        UIView.transition(with: imageView, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.imageView.image = image
        }
    }

    private static func logFailure(_ error: any Error, id: String, kind: String) {
        switch error {
        case is CancellationError:
            return
        case let error as MediaError where error.kind == .backingOff || error.kind == .notFound:
            // Usually still being generated on the server. The pipeline retries later,
            // or immediately once sync delivers a thumbhash for it.
            return
        default:
            // The placeholder stays; the tile retries the next time it is displayed.
            Log.media.debug("\(kind, privacy: .public) \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Video duration and favourite heart over a bottom shade.
private final class BadgeOverlay: UIView {
    private let shade = CAGradientLayer()
    private let durationLabel = UILabel()
    private let heart = UIImageView(image: UIImage(systemName: "heart.fill"))
    private let status = UIImageView()
    private let captionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        captionLabel.textAlignment = .center
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.6
        captionLabel.layer.shadowColor = UIColor.black.cgColor
        captionLabel.layer.shadowOpacity = 0.55
        captionLabel.layer.shadowRadius = 2
        captionLabel.layer.shadowOffset = .zero
        shade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.35).cgColor]
        layer.addSublayer(shade)
        durationLabel.textColor = .white
        addSubview(durationLabel)
        heart.tintColor = .white
        heart.contentMode = .scaleAspectFit
        addSubview(heart)
        status.tintColor = .white
        status.contentMode = .scaleAspectFit
        status.layer.shadowColor = UIColor.black.cgColor
        status.layer.shadowOpacity = 0.4
        status.layer.shadowRadius = 1.5
        status.layer.shadowOffset = .zero
        addSubview(status)
        addSubview(captionLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(duration: String?, isFavorite: Bool, status tileStatus: TileStatus?, caption: TileCaption?) {
        captionLabel.isHidden = caption == nil
        captionLabel.text = caption?.text
        captionLabel.textColor = caption?.isUrgent == true ? .systemRed : .white
        // With a caption (Recently Deleted's days left) it's the only label on the tile.
        durationLabel.isHidden = duration == nil || caption != nil
        durationLabel.text = duration
        heart.isHidden = !isFavorite || caption != nil
        status.isHidden = tileStatus == nil || caption != nil
        status.image = tileStatus.map { UIImage(systemName: $0.symbol) } ?? nil
        // The shade is only for video length and favourites; the status glyph has its own shadow.
        shade.isHidden = duration == nil && !isFavorite && caption == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = CGRect(x: 0, y: bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4)
        CATransaction.commit()

        let compact = bounds.width < 60
        durationLabel.font = .monospacedDigitSystemFont(ofSize: compact ? 9 : 12, weight: .semibold)
        durationLabel.sizeToFit()
        durationLabel.frame.origin = CGPoint(x: bounds.width - durationLabel.bounds.width - 4, y: bounds.height - durationLabel.bounds.height - 3)
        let size: CGFloat = compact ? 9 : 12
        heart.frame = CGRect(x: 4, y: bounds.height - size - 4, width: size, height: size)
        let statusSize: CGFloat = compact ? 9 : 12
        status.frame = CGRect(x: heart.isHidden ? 4 : heart.frame.maxX + 3, y: bounds.height - statusSize - 4, width: statusSize, height: statusSize)
        // Recently Deleted's days left: centred at the bottom (about 13 pt at five columns).
        let captionSize = min(max(bounds.width * 0.15, 9), 14)
        captionLabel.font = .systemFont(ofSize: captionSize, weight: .medium)
        captionLabel.frame = CGRect(x: 4, y: bounds.height - captionSize * 1.3 - 5, width: bounds.width - 8, height: captionSize * 1.3)
    }
}

/// Text centred at the bottom of a tile, e.g. the days left in Recently Deleted.
struct TileCaption: Equatable {
    let text: String
    /// Shown in red (about to be removed for good).
    var isUrgent = false
}

/// Where a photo is: only on this iPhone, only in the Cloud, or both.
enum TileStatus: Equatable {
    case phoneOnly, cloudOnly, both

    init(_ item: TimelineItem) {
        switch (item.isLocal, item.isRemote) {
        case (true, false): self = .phoneOnly
        case (false, _): self = .cloudOnly
        case (true, true): self = .both
        }
    }

    var symbol: String {
        switch self {
        case .phoneOnly: "iphone"
        case .cloudOnly: "cloud"
        case .both: "checkmark.icloud"
        }
    }
}
