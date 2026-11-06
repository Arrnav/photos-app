import CoreGraphics

/// Row heights for the single-column level, where each photo keeps its aspect
/// ratio instead of a square crop. Built once per (width, items); immutable.
public final class HeightTable: Sendable {
    /// Width / height limits: very tall or very wide items are cropped to these.
    public static let ratioRange: ClosedRange<Double> = 0.5...3.0

    /// `offsets[i]` is the top of item i; `offsets[count]` is the content height + spacing.
    let offsets: [CGFloat]
    let heights: [CGFloat]

    public init(aspectRatios: [Double], width: CGFloat, spacing: CGFloat) {
        var offsets: [CGFloat] = []
        var heights: [CGFloat] = []
        offsets.reserveCapacity(aspectRatios.count + 1)
        heights.reserveCapacity(aspectRatios.count)
        var y: CGFloat = 0
        for ratio in aspectRatios {
            let clamped = min(max(ratio.isFinite && ratio > 0 ? ratio : 1, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            let height = (width / CGFloat(clamped)).rounded(.toNearestOrAwayFromZero)
            offsets.append(y)
            heights.append(height)
            y += height + spacing
        }
        offsets.append(y)
        self.offsets = offsets
        self.heights = heights
    }

    var count: Int { heights.count }

    /// Index of the item containing `y` (clamped to the ends). Binary search.
    func index(atY y: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// The photo grid's geometry for one zoom level. Square tiles (O(1) arithmetic),
/// except the single-column level, which uses a `HeightTable` (binary search).
public struct GridMetrics: Sendable, Equatable {
    public let columns: Int
    public let width: CGFloat
    public let spacing: CGFloat
    public let itemCount: Int
    public let heights: HeightTable?

    public init(columns: Int, width: CGFloat, spacing: CGFloat, itemCount: Int, heights: HeightTable? = nil) {
        self.columns = max(1, columns)
        self.width = max(0, width)
        self.spacing = spacing
        self.itemCount = max(0, itemCount)
        self.heights = heights.flatMap { $0.count == itemCount ? $0 : nil }
    }

    public static func == (lhs: GridMetrics, rhs: GridMetrics) -> Bool {
        lhs.columns == rhs.columns && lhs.width == rhs.width && lhs.spacing == rhs.spacing
            && lhs.itemCount == rhs.itemCount && lhs.heights === rhs.heights
    }

    /// Tile width (and height, for square tiles).
    public var side: CGFloat {
        guard width > 0 else { return 0 }
        return (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    public var rowHeight: CGFloat { side + spacing }
    public var rows: Int { (itemCount + columns - 1) / columns }

    public var contentHeight: CGFloat {
        if let heights { return max(0, heights.offsets[heights.count] - spacing) }
        return max(0, CGFloat(rows) * rowHeight - spacing)
    }

    public func frame(at index: Int) -> CGRect {
        if let heights {
            return CGRect(x: 0, y: heights.offsets[index], width: width, height: heights.heights[index])
        }
        let row = index / columns
        let column = index % columns
        return CGRect(x: CGFloat(column) * (side + spacing), y: CGFloat(row) * rowHeight, width: side, height: side)
    }

    /// The item whose tile contains `point`, or the nearest one.
    public func index(near point: CGPoint) -> Int? {
        guard itemCount > 0, side > 0 else { return nil }
        if let heights { return heights.index(atY: point.y) }
        let row = min(max(0, Int(point.y / rowHeight)), rows - 1)
        let column = min(max(0, Int(point.x / (side + spacing))), columns - 1)
        return min(row * columns + column, itemCount - 1)
    }

    /// Items intersecting `minY...maxY`.
    public func indexRange(minY: CGFloat, maxY: CGFloat) -> Range<Int> {
        guard itemCount > 0, side > 0, maxY >= minY else { return 0..<0 }
        if let heights {
            guard maxY >= 0, minY <= contentHeight else { return 0..<0 }
            return heights.index(atY: minY)..<(heights.index(atY: maxY) + 1)
        }
        let firstRow = max(0, Int((minY / rowHeight).rounded(.down)))
        let lastRow = min(rows - 1, Int((maxY / rowHeight).rounded(.down)))
        guard firstRow <= lastRow else { return 0..<0 }
        return (firstRow * columns)..<min(itemCount, (lastRow + 1) * columns)
    }

    /// The offset range a scroll view with these insets allows.
    public func offsetBounds(viewportHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) -> ClosedRange<CGFloat> {
        let minY = -insetTop
        let maxY = max(minY, contentHeight - viewportHeight + insetBottom)
        return minY...maxY
    }
}

/// The zoom levels: 1 (uncropped), 3, 5, 15 and 30 columns.
public enum GridLevels {
    public static let columns = [1, 3, 5, 15, 30]

    /// Gaps shrink at the dense levels so tiles don't drown in spacing.
    public static func spacing(columns: Int) -> CGFloat {
        switch columns {
        case ...5: 2
        case ...15: 1
        default: 0.5
        }
    }

    public static func side(columns: Int, width: CGFloat) -> CGFloat {
        GridMetrics(columns: columns, width: width, spacing: spacing(columns: columns), itemCount: 1).side
    }
}

/// Pure maths for the pinch. The grid is scaled about the
/// screen's horizontal centre (it never slides sideways) and follows the fingers
/// vertically. Underneath, the densest level that still covers the screen is
/// shown, scaled up, so the grid always overfills the screen and no background
/// shows; levels swap in place as the scale passes them.
public enum ZoomMath {
    /// Fractional change in log-scale ignored at the start of a pinch, so tiny finger movements do nothing.
    public static let deadZone: CGFloat = 0.06
    /// Log-scale margin before the shown level changes, so it doesn't flicker around a switching point.
    public static let hysteresis: CGFloat = 0.05

    /// The pinch scale after the dead zone: 1 until the fingers have moved by `deadZone` (in log terms),
    /// then continuous from there.
    public static func visualScale(_ raw: CGFloat, deadZone: CGFloat = deadZone) -> CGFloat {
        guard raw > 0 else { return 1 }
        let l = log(raw)
        let adjusted = l > 0 ? max(0, l - deadZone) : min(0, l + deadZone)
        return exp(adjusted)
    }

    /// Clamps a tile size to the range the levels cover (no over-zoom past 1 or 30 columns).
    /// Returns whether the clamp kicked in, for the haptic stop.
    public static func clampSide(_ side: CGFloat, width: CGFloat, levels: [Int] = GridLevels.columns) -> (side: CGFloat, clamped: Bool) {
        let sides = levels.map { GridLevels.side(columns: $0, width: width) }
        let lower = sides.min() ?? side, upper = sides.max() ?? side
        let clampedSide = min(max(side, lower), upper)
        return (clampedSide, abs(clampedSide - side) > 0.0001)
    }

    /// The densest level whose tiles are not bigger than `effectiveSide`, so the grid
    /// shown is scaled up (never down) and always covers the screen. With `current`,
    /// the current level is kept until the side is `hysteresis` past the next bigger
    /// level. The margin is only ever on that side: keeping a level whose tiles are
    /// bigger than `effectiveSide` would mean drawing it below 1× (background showing).
    public static func coveringLevel(effectiveSide: CGFloat, width: CGFloat, current: Int? = nil, levels: [Int] = GridLevels.columns) -> Int {
        // Biggest tiles first.
        let sorted = levels.sorted { GridLevels.side(columns: $0, width: width) > GridLevels.side(columns: $1, width: width) }
        if let current, let i = sorted.firstIndex(of: current) {
            let side = GridLevels.side(columns: current, width: width)
            let biggerSide = i > 0 ? GridLevels.side(columns: sorted[i - 1], width: width) : .infinity
            let lowerOK = effectiveSide >= side * 0.9999 || i == sorted.count - 1
            let upperOK = effectiveSide < biggerSide * exp(hysteresis)
            if lowerOK && upperOK { return current }
        }
        return sorted.first { GridLevels.side(columns: $0, width: width) <= effectiveSide * 1.0001 } ?? sorted.last!
    }

    /// The level whose tile size is nearest `effectiveSide` in log terms (so 3→5 and 15→30 feel equally far).
    public static func nearestLevel(effectiveSide: CGFloat, width: CGFloat, levels: [Int] = GridLevels.columns) -> Int {
        let target = log(max(effectiveSide, 0.01))
        return levels.min { a, b in
            abs(log(GridLevels.side(columns: a, width: width)) - target) < abs(log(GridLevels.side(columns: b, width: width)) - target)
        }!
    }

    /// Where a pinch released with `velocity` (scale per second) would come to rest.
    /// Only clearly quick pinches carry on; slow releases stay where the fingers are.
    public static func projectedScale(_ scale: CGFloat, velocity: CGFloat, minimumVelocity: CGFloat = 1.5, lookahead: CGFloat = 0.12) -> CGFloat {
        guard abs(velocity) >= minimumVelocity else { return scale }
        let excess = velocity > 0 ? velocity - minimumVelocity : velocity + minimumVelocity
        return max(0.01, scale * exp(excess / max(scale, 0.01) * lookahead))
    }

    /// Vertical translation that draws the anchor (view y, unscaled) at `fingerY` with
    /// the grid scaled by `scale` about `centerY`, then clamped so the scaled content
    /// still covers the viewport whenever it is tall enough to.
    ///
    /// - Parameters:
    ///   - contentTop, contentBottom: the content's extent in view coordinates (unscaled).
    public static func verticalTranslation(
        anchorY: CGFloat,
        fingerY: CGFloat,
        scale: CGFloat,
        centerY: CGFloat,
        contentTop: CGFloat,
        contentBottom: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let wanted = fingerY - centerY - scale * (anchorY - centerY)
        // displayed(y) = centerY + scale * (y - centerY) + t
        let maxT = -(centerY + scale * (contentTop - centerY))                  // top edge at or above 0
        let minT = viewportHeight - (centerY + scale * (contentBottom - centerY)) // bottom edge at or below the viewport
        guard minT <= maxT else { return wanted }
        return min(max(wanted, minT), maxT)
    }

    /// Applies scale `scale` about `center` plus translation (UIKit's transform maths).
    public static func apply(scale: CGFloat, translation: CGPoint, center: CGPoint, to point: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + scale * (point.x - center.x) + translation.x,
            y: center.y + scale * (point.y - center.y) + translation.y
        )
    }
}
