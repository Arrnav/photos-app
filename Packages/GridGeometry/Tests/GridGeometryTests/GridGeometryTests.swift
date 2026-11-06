import CoreGraphics
import Foundation
import Testing
@testable import GridGeometry

/// iPhone 12 Pro Max portrait width.
private let width: CGFloat = 428
private func metrics(_ columns: Int, count: Int = 12_501) -> GridMetrics {
    GridMetrics(columns: columns, width: width, spacing: GridLevels.spacing(columns: columns), itemCount: count)
}

@Suite struct GridMetricsTests {
    @Test(arguments: GridLevels.columns)
    func tilesFillTheWidth(columns: Int) {
        let grid = metrics(columns)
        let last = grid.frame(at: columns - 1)
        #expect(abs(last.maxX - width) < 0.001)
        #expect(grid.frame(at: columns).minY == grid.rowHeight)
    }

    @Test func indexNearPointAndRange() {
        let grid = metrics(5)
        let frame = grid.frame(at: 17)
        #expect(grid.index(near: CGPoint(x: frame.midX, y: frame.midY)) == 17)
        #expect(grid.index(near: CGPoint(x: -10, y: -10)) == 0)
        #expect(grid.index(near: CGPoint(x: 9999, y: 1e9)) == 12_500)
        let range = grid.indexRange(minY: frame.minY, maxY: frame.maxY)
        #expect(range.contains(17) && range.count == 5)
    }

    @Test func emptyGrid() {
        let grid = metrics(5, count: 0)
        #expect(grid.index(near: .zero) == nil)
        #expect(grid.indexRange(minY: 0, maxY: 1000).isEmpty)
        #expect(grid.contentHeight == 0)
    }

    @Test func thirtyColumnsAreTiny() {
        #expect(GridLevels.side(columns: 30, width: width) < 14)
        #expect(GridLevels.side(columns: 1, width: width) == width)
    }
}

@Suite struct SingleColumnTests {
    private let ratios: [Double] = [4.0 / 3.0, 3.0 / 4.0, 1, 16.0 / 9.0, 0.2, 10, .nan, 0]

    private var grid: GridMetrics {
        GridMetrics(columns: 1, width: width, spacing: 2, itemCount: ratios.count,
                    heights: HeightTable(aspectRatios: ratios, width: width, spacing: 2))
    }

    @Test func keepsEachPhotosAspectRatio() {
        let grid = grid
        #expect(abs(grid.frame(at: 0).height - 321) < 1)   // landscape 4:3
        #expect(abs(grid.frame(at: 1).height - 571) < 1)   // portrait 3:4
        #expect(grid.frame(at: 2).height == width)          // square
        #expect(grid.frame(at: 0).width == width)
    }

    @Test func clampsExtremesAndBadRatios() {
        let grid = grid
        #expect(grid.frame(at: 4).height == width / 0.5)    // very tall → 1:2
        #expect(abs(grid.frame(at: 5).height - width / 3) < 1) // very wide → 3:1
        #expect(grid.frame(at: 6).height == width)          // NaN → square
        #expect(grid.frame(at: 7).height == width)          // 0 → square
    }

    @Test func framesAreContiguousAndSearchable() {
        let grid = grid
        for i in 1..<ratios.count {
            #expect(grid.frame(at: i).minY == grid.frame(at: i - 1).maxY + 2)
        }
        for i in 0..<ratios.count {
            let frame = grid.frame(at: i)
            #expect(grid.index(near: CGPoint(x: 10, y: frame.midY)) == i)
        }
        let range = grid.indexRange(minY: grid.frame(at: 2).minY + 1, maxY: grid.frame(at: 3).maxY - 1)
        #expect(range == 2..<4)
        #expect(grid.contentHeight == grid.frame(at: ratios.count - 1).maxY)
    }

    @Test func mismatchedTableIsIgnored() {
        let table = HeightTable(aspectRatios: [1, 1], width: width, spacing: 2)
        let grid = GridMetrics(columns: 1, width: width, spacing: 2, itemCount: 5, heights: table)
        #expect(grid.heights == nil)
    }
}

@Suite struct ZoomMathTests {
    private func side(_ columns: Int) -> CGFloat { GridLevels.side(columns: columns, width: width) }

    @Test func coveringLevelIsNeverBiggerThanTheEffectiveTile() {
        #expect(ZoomMath.coveringLevel(effectiveSide: side(5), width: width) == 5)
        #expect(ZoomMath.coveringLevel(effectiveSide: side(5) * 1.3, width: width) == 5)
        #expect(ZoomMath.coveringLevel(effectiveSide: side(5) * 0.95, width: width) == 15)
        #expect(ZoomMath.coveringLevel(effectiveSide: side(3) * 1.01, width: width) == 3)
        #expect(ZoomMath.coveringLevel(effectiveSide: 1, width: width) == 30)
        #expect(ZoomMath.coveringLevel(effectiveSide: 5000, width: width) == 1)
    }

    @Test func nearestLevelUsesLogDistance() {
        // Geometric mean of 5- and 15-column sides is the switching point.
        let mean = sqrt(side(5) * side(15))
        #expect(ZoomMath.nearestLevel(effectiveSide: mean * 1.05, width: width) == 5)
        #expect(ZoomMath.nearestLevel(effectiveSide: mean * 0.95, width: width) == 15)
        #expect(ZoomMath.nearestLevel(effectiveSide: side(30), width: width) == 30)
    }

    @Test func hysteresisKeepsTheCurrentLevelNearItsEdge() {
        // Below 5-column size the 5-column grid can't stay (it would be drawn under 1×).
        #expect(ZoomMath.coveringLevel(effectiveSide: side(5) * 0.98, width: width, current: 5) == 15)
        // Once on 15, coming back just past 5-column size stays on 15 (scaled up) until clearly past.
        #expect(ZoomMath.coveringLevel(effectiveSide: side(5) * 1.02, width: width, current: 15) == 15)
        #expect(ZoomMath.coveringLevel(effectiveSide: side(5) * 1.1, width: width, current: 15) == 5)
        // Just above 3-column size while showing 5 (scaled up): stay on 5 until clearly past.
        #expect(ZoomMath.coveringLevel(effectiveSide: side(3) * 1.02, width: width, current: 5) == 5)
        #expect(ZoomMath.coveringLevel(effectiveSide: side(3) * 1.1, width: width, current: 5) == 3)
    }

    @Test func shownLevelIsNeverDrawnBelowNaturalSize() {
        // Sweep tile sizes up and down with hysteresis: the shown level's tiles never exceed the effective size.
        var current = 5
        let sizes = stride(from: side(1), through: side(30), by: -1.0).map { $0 } + stride(from: side(30), through: side(1), by: 1.0).map { $0 }
        for e in sizes {
            current = ZoomMath.coveringLevel(effectiveSide: e, width: width, current: current)
            #expect(side(current) <= e * 1.0001, "level \(current) shown at size \(e)")
        }
    }

    @Test func deadZoneIgnoresTinyPinches() {
        #expect(ZoomMath.visualScale(1.04) == 1)
        #expect(ZoomMath.visualScale(0.96) == 1)
        #expect(ZoomMath.visualScale(1.5) > 1.35 && ZoomMath.visualScale(1.5) < 1.5)
        // Continuous at the edge of the dead zone.
        #expect(abs(ZoomMath.visualScale(exp(ZoomMath.deadZone) + 0.0001) - 1) < 0.001)
    }

    @Test func clampStopsAtTheFirstAndLastLevels() {
        let (big, bigClamped) = ZoomMath.clampSide(side(1) * 1.3, width: width)
        #expect(big == side(1) && bigClamped)
        let (tiny, tinyClamped) = ZoomMath.clampSide(side(30) * 0.5, width: width)
        #expect(tiny == side(30) && tinyClamped)
        #expect(ZoomMath.clampSide(side(5), width: width).clamped == false)
    }

    @Test func slowReleasesDontJumpLevels() {
        // A small, moderately quick pinch-out from 5 columns stays on 5 or the next level, never 30.
        for velocity in [-0.5, -1.0, -1.4] {
            let projected = ZoomMath.projectedScale(0.97, velocity: velocity)
            #expect(projected == 0.97)
            #expect(ZoomMath.nearestLevel(effectiveSide: side(5) * projected, width: width) == 5)
        }
    }

    @Test func quickPinchStillCrossesSeveralLevels() {
        let projected = ZoomMath.projectedScale(0.6, velocity: -12)
        #expect(ZoomMath.nearestLevel(effectiveSide: side(3) * projected, width: width) == 30)
    }

    @Test(arguments: [1.0, 1.7, 3.2])
    func verticalAnchorStaysUnderTheFinger(scale: Double) {
        let t = ZoomMath.verticalTranslation(anchorY: 300, fingerY: 420, scale: scale, centerY: 463,
                                             contentTop: -50_000, contentBottom: 50_000, viewportHeight: 926)
        let drawn = 463 + scale * (300 - 463) + t
        #expect(abs(drawn - 420) < 0.0001)
    }

    @Test func verticalTranslationNeverRevealsBeyondTheContent() {
        // Content starts at the top of the view (scrolled to the very top).
        let scale: CGFloat = 1.5
        let t = ZoomMath.verticalTranslation(anchorY: 100, fingerY: 800, scale: scale, centerY: 463,
                                             contentTop: 0, contentBottom: 20_000, viewportHeight: 926)
        let top = 463 + scale * (0 - 463) + t
        #expect(top <= 0.0001)
        // And at the bottom.
        let t2 = ZoomMath.verticalTranslation(anchorY: 900, fingerY: 50, scale: scale, centerY: 463,
                                              contentTop: -20_000, contentBottom: 926, viewportHeight: 926)
        let bottom = 463 + scale * (926 - 463) + t2
        #expect(bottom >= 926 - 0.0001)
    }

    @Test func horizontallyCentredLevelsLineUp() {
        // A 5-column grid scaled to 3-column tile size, centred, puts its middle three
        // columns where the 3-column grid's columns are (within the spacing difference).
        let s5 = side(5), s3 = side(3)
        let scale = s3 / s5
        let center = width / 2
        for (c5, c3) in [(1, 0), (2, 1), (3, 2)] {
            let x5 = center + scale * (CGFloat(c5) * (s5 + 2) + s5 / 2 - center)
            let x3 = CGFloat(c3) * (s3 + 2) + s3 / 2
            #expect(abs(x5 - x3) < 3)
        }
    }
}
