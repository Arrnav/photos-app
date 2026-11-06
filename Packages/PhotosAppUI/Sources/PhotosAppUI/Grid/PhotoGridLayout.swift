import GridGeometry
import UIKit

/// The photo grid at one zoom level (PLAN.md D10): square tiles from `GridMetrics`
/// (O(1) per query), or at one column each photo at its own aspect ratio.
/// Pinch-zoom never interpolates tile positions here; the view controller scales
/// the whole collection view and switches this layout's level underneath.
final class PhotoGridLayout: UICollectionViewLayout {
    private(set) var columns: Int
    private(set) var metrics: GridMetrics

    /// Width / height per item, used only by the single-column level.
    private var aspectRatios: [Double] = []
    private var ratiosVersion = 0
    private var heightTable: (width: CGFloat, version: Int, table: HeightTable)?

    init(columns: Int) {
        self.columns = max(1, columns)
        metrics = GridMetrics(columns: columns, width: 0, spacing: GridLevels.spacing(columns: columns), itemCount: 0)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var itemSide: CGFloat { metrics.side }

    /// Must be called whenever the items change (before the collection view reloads).
    func setAspectRatios(_ ratios: [Double]) {
        aspectRatios = ratios
        ratiosVersion += 1
        invalidateLayout()
    }

    func setColumns(_ newColumns: Int) {
        guard newColumns != columns else { return }
        columns = newColumns
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        var heights: HeightTable?
        if columns == 1, aspectRatios.count == count {
            if let cached = heightTable, cached.width == width, cached.version == ratiosVersion {
                heights = cached.table
            } else {
                let table = HeightTable(aspectRatios: aspectRatios, width: width, spacing: GridLevels.spacing(columns: 1))
                heightTable = (width, ratiosVersion, table)
                heights = table
            }
        }
        metrics = GridMetrics(
            columns: columns, width: width, spacing: GridLevels.spacing(columns: columns),
            itemCount: count, heights: heights
        )
    }

    /// Metrics for another level at the current width, e.g. to plan where an anchor lands.
    func metrics(forColumns other: Int) -> GridMetrics {
        guard other != columns else { return metrics }
        var heights: HeightTable?
        if other == 1, aspectRatios.count == metrics.itemCount {
            heights = HeightTable(aspectRatios: aspectRatios, width: metrics.width, spacing: GridLevels.spacing(columns: 1))
        }
        return GridMetrics(
            columns: other, width: metrics.width, spacing: GridLevels.spacing(columns: other),
            itemCount: metrics.itemCount, heights: heights
        )
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: metrics.width, height: metrics.contentHeight)
    }

    func frame(forItemAt index: Int) -> CGRect { metrics.frame(at: index) }

    func index(near point: CGPoint) -> Int? { metrics.index(near: point) }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        metrics.indexRange(minY: rect.minY, maxY: rect.maxY).map { attributes(at: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < metrics.itemCount else { return nil }
        return attributes(at: indexPath.item)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = metrics.frame(at: index)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != metrics.width
    }

    /// The content offset that puts `point` at `viewY` in the visible area, clamped.
    func clampedOffset(placing point: CGPoint, atViewY viewY: CGFloat, in collectionView: UICollectionView) -> CGPoint {
        let insets = collectionView.adjustedContentInset
        let bounds = metrics.offsetBounds(viewportHeight: collectionView.bounds.height, insetTop: insets.top, insetBottom: insets.bottom)
        return CGPoint(x: collectionView.contentOffset.x, y: min(max(point.y - viewY, bounds.lowerBound), bounds.upperBound))
    }
}
