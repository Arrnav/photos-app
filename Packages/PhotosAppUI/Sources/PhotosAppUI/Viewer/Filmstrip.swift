import MediaCache
import Persistence
import UIKit

/// The strip of small thumbnails above the toolbar: the current photo
/// is wider (its own aspect ratio), dragging scrubs through the library, tapping jumps.
final class FilmstripView: UIView {
    var onSelect: ((Int) -> Void)?

    private let layout = FilmstripLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var items: [TimelineItem] = []
    private let pipeline: RemoteImagePipeline
    private let placeholder: (TimelineItem) -> UIImage?
    private var isUserScrubbing = false

    init(pipeline: RemoteImagePipeline, placeholder: @escaping (TimelineItem) -> UIImage?) {
        self.pipeline = pipeline
        self.placeholder = placeholder
        super.init(frame: .zero)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.register(FilmstripCell.self, forCellWithReuseIdentifier: FilmstripCell.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: FilmstripLayout.itemHeight),
        ])
        isAccessibilityElement = false
        accessibilityElementsHidden = true // the pager is the accessible way to move between photos
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = bounds.width / 2 - FilmstripLayout.itemWidth / 2
        if collectionView.contentInset.left != inset {
            collectionView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            centerCurrent(animated: false)
        }
    }

    func setItems(_ items: [TimelineItem], current: Int) {
        self.items = items
        layout.aspectRatios = items.map(\.aspectRatio)
        layout.current = current
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        centerCurrent(animated: false)
    }

    /// Follows the pager (unless the user is scrubbing the strip itself).
    func setCurrent(_ index: Int, animated: Bool) {
        guard index != layout.current || !isUserScrubbing else { return }
        layout.current = index
        if animated {
            UIView.animate(withDuration: 0.25) {
                self.layout.invalidateLayout()
                self.collectionView.layoutIfNeeded()
                if !self.isUserScrubbing { self.centerCurrent(animated: false) }
            }
        } else {
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if !isUserScrubbing { centerCurrent(animated: false) }
        }
    }

    private func centerCurrent(animated: Bool) {
        guard items.indices.contains(layout.current) else { return }
        let center = layout.centerX(of: layout.current)
        let offset = CGPoint(x: center - collectionView.bounds.width / 2, y: 0)
        collectionView.setContentOffset(offset, animated: animated)
    }
}

extension FilmstripView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripCell.reuseIdentifier, for: indexPath) as! FilmstripCell
        cell.configure(item: items[indexPath.item], pipeline: pipeline, placeholder: placeholder(items[indexPath.item]))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
        setCurrent(indexPath.item, animated: true)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrubbing = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isUserScrubbing, !items.isEmpty else { return }
        let index = layout.index(nearestX: scrollView.contentOffset.x + scrollView.bounds.width / 2)
        if index != layout.current {
            layout.current = index
            layout.invalidateLayout()
            onSelect?(index)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrubbing() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScrubbing()
    }

    private func finishScrubbing() {
        isUserScrubbing = false
        centerCurrent(animated: true)
    }
}

/// O(1) layout: uniform slim thumbnails, the current one widened to its aspect ratio.
final class FilmstripLayout: UICollectionViewLayout {
    static let itemHeight: CGFloat = 36
    static let itemWidth: CGFloat = 22
    static let spacing: CGFloat = 2

    var aspectRatios: [Double] = []
    var current = 0

    private var currentWidth: CGFloat {
        guard aspectRatios.indices.contains(current) else { return Self.itemWidth }
        return min(max(CGFloat(aspectRatios[current]) * Self.itemHeight, Self.itemWidth), Self.itemHeight * 1.8)
    }

    private var extra: CGFloat { currentWidth - Self.itemWidth + Self.spacing * 2 }

    func frame(of index: Int) -> CGRect {
        let pitch = Self.itemWidth + Self.spacing
        var x = CGFloat(index) * pitch
        if index > current { x += extra }
        if index == current { x += Self.spacing }
        let width = index == current ? currentWidth : Self.itemWidth
        return CGRect(x: x, y: 0, width: width, height: Self.itemHeight)
    }

    func centerX(of index: Int) -> CGFloat { frame(of: index).midX }

    func index(nearestX x: CGFloat) -> Int {
        let pitch = Self.itemWidth + Self.spacing
        let guess = Int((x / pitch).rounded(.down))
        let candidates = [guess - 1, guess, guess + 1].filter { aspectRatios.indices.contains($0) }
        return candidates.min { abs(centerX(of: $0) - x) < abs(centerX(of: $1) - x) } ?? 0
    }

    override var collectionViewContentSize: CGSize {
        guard !aspectRatios.isEmpty else { return .zero }
        return CGSize(width: frame(of: aspectRatios.count - 1).maxX, height: Self.itemHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !aspectRatios.isEmpty else { return [] }
        let pitch = Self.itemWidth + Self.spacing
        let first = max(0, Int((rect.minX - extra) / pitch) - 1)
        let last = min(aspectRatios.count - 1, Int(rect.maxX / pitch) + 1)
        guard first <= last else { return [] }
        return (first...last).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            .filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard aspectRatios.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame(of: indexPath.item)
        return attributes
    }
}

private final class FilmstripCell: UICollectionViewCell {
    static let reuseIdentifier = "FilmstripCell"
    private let imageView = UIImageView()
    private var task: Task<Void, Never>?
    private var id: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .systemGray5
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        id = nil
        imageView.image = nil
    }

    func configure(item: TimelineItem, pipeline: RemoteImagePipeline, placeholder: UIImage?) {
        id = item.id
        if let cached = pipeline.cachedImage(assetID: item.id, size: .thumbnail, maxPixelSize: PhotoGridViewController.thumbnailPixelSize) {
            imageView.image = UIImage(cgImage: cached)
            return
        }
        imageView.image = placeholder
        let id = item.id
        let revision = item.thumbhash
        task = Task { [weak self] in
            guard let image = try? await pipeline.image(assetID: id, size: .thumbnail, maxPixelSize: PhotoGridViewController.thumbnailPixelSize, revision: revision, priority: .prefetch),
                  let self, self.id == id
            else { return }
            self.imageView.image = UIImage(cgImage: image)
        }
    }
}
