import Core
import GridGeometry
import MediaCache
import Persistence
import UIKit

/// The library grid: oldest at the top, newest at the bottom (opens at the bottom),
/// pinch to change density, fast scrubber, thumbhash placeholders then thumbnails.
///
/// Pinch: the whole grid is scaled about the screen's
/// horizontal centre (it never slides sideways) and follows the fingers vertically.
/// Underneath, the densest level that still covers the screen is shown scaled up,
/// so the grid always overfills the screen and tiles look soft; as the scale passes
/// a level, tiles swap in place (centred levels line up) with the old ones blurring
/// out. On release a quick pinch carries on to further levels; the grid settles on
/// the nearest one. Zoom stops at 1 and 30 columns with a light tap.
final class PhotoGridViewController: UIViewController {
    /// Server thumbnails are at most ~250 px, so every level shares one decoded size.
    static let thumbnailPixelSize = 256
    /// Tiles bigger than this (3 and 1 columns) switch to the server preview once the grid is at rest.
    static let previewThresholdPixels: CGFloat = 330

    var onColumnsChanged: ((Int) -> Void)?
    /// Scrolling reports for the Library header and bar: visible dates, whether the
    /// user is touching or moving the grid, whether it's at the newest photos, and
    /// whether the user scrolled (which morphs the bottom bar).
    var onScrollInfo: ((_ range: ClosedRange<Date>?, _ interacting: Bool, _ atBottom: Bool, _ userScrolled: Bool) -> Void)?
    /// Space under the overlaid header and above the floating bar.
    var contentInsets = UIEdgeInsets.zero {
        didSet { if contentInsets != oldValue { applyInsets() } }
    }
    /// View Options › Aspect Ratio Grid: whole photos in their tiles instead of square crops.
    var aspectRatioGrid = false {
        didSet { if aspectRatioGrid != oldValue { reconfigureVisibleCells() } }
    }

    // Select mode
    var isSelecting = false {
        didSet { if isSelecting != oldValue { reconfigureVisibleCells() } }
    }
    var isSelected: (String) -> Bool = { _ in false }
    var onSelectionChange: ((_ ids: [String], _ selected: Bool) -> Void)?
    /// Builds the viewer for a tapped item (set by the SwiftUI wrapper, which has the session).
    var makeViewer: ((_ items: [TimelineItem], _ index: Int, _ source: ViewerTransitionSource, _ placeholder: @escaping (TimelineItem) -> UIImage?) -> UIViewController?)?
    /// Builds the share screen for selected items (select mode's Share button).
    /// Photos on the phone load from here instead of the server.
    var phoneImages: PhoneImages?
    /// Phone / Cloud / both badges on tiles.
    var showsStatus = true {
        didSet {
            guard showsStatus != oldValue, isViewLoaded else { return }
            for case let cell as PhotoGridCell in collectionView.visibleCells {
                cell.showsStatus = showsStatus
                cell.setNeedsLayout()
            }
        }
    }
    /// Text centred at the bottom of each tile (Recently Deleted's days left).
    var caption: ((TimelineItem) -> TileCaption?)? {
        didSet { if isViewLoaded { reconfigureVisibleCells() } }
    }
    var makeShare: ((_ items: [TimelineItem], _ index: Int, _ selection: [String], _ origin: (frame: CGRect, image: UIImage?)?, _ placeholder: @escaping (TimelineItem) -> UIImage?) -> UIViewController?)?

    private let pipeline: RemoteImagePipeline
    private var items: [TimelineItem] = []
    private var version = -1
    private(set) var columns: Int

    private var collectionView: UICollectionView!
    private var gridLayout: PhotoGridLayout { collectionView.collectionViewLayout as! PhotoGridLayout }
    private let scrubber = ScrubberView()
    private var lastReport: (range: ClosedRange<Date>?, interacting: Bool, atBottom: Bool)?
    private var userScrollReported = false

    // Drag to select
    private var selectPan: UIPanGestureRecognizer!
    private struct DragSelection {
        let startIndex: Int
        /// Select (true) or deselect (false), decided by the first tile touched.
        let selecting: Bool
        /// Tiles changed by this drag and their state before it.
        var original: [Int: Bool] = [:]
        var location: CGPoint
    }
    private var dragSelection: DragSelection?
    private var autoScrollLink: CADisplayLink?
    private var autoScrollSpeed: CGFloat = 0
    private let placeholders = PlaceholderCache()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var didInitialScroll = false
    /// The tile hidden while a photo zooms to or from it.
    private var hiddenTileID: String?

    // Pinch state
    private struct Pinch {
        /// Tile size of the level the pinch started on.
        let startSide: CGFloat
        /// The item under the fingers, and where inside it (0...1, vertically) the fingers are.
        let anchorIndex: Int
        let anchorRelativeY: CGFloat
        var fingerY: CGFloat
        /// Raw gesture scale since the pinch began.
        var rawScale: CGFloat = 1
        /// Tile size being shown (after dead zone and clamping).
        var effectiveSide: CGFloat
        var atLimit = false
    }
    private var pinch: Pinch?
    private var isSettling = false
    private var fadingSnapshot: UIView?
    private var isZooming: Bool { pinch != nil || isSettling }
    /// Items that arrived during a pinch; applied when it ends (reloading mid-zoom would jump).
    private var deferredItems: (items: [TimelineItem], version: Int)?
    private let levelHaptics = UISelectionFeedbackGenerator()
    private let limitHaptics = UIImpactFeedbackGenerator(style: .light)

    init(pipeline: RemoteImagePipeline, columns: Int) {
        self.pipeline = pipeline
        self.columns = GridLevels.columns.contains(columns) ? columns : 5
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: PhotoGridLayout(columns: columns))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.allowsMultipleSelection = false
        collectionView.register(PhotoGridCell.self, forCellWithReuseIdentifier: PhotoGridCell.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        collectionView.accessibilityLabel = String(localized: "Library")
        view.addSubview(collectionView)
        gridLayout.setAspectRatios(items.map(\.aspectRatio))

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrubber)
        scrubberTop = scrubber.topAnchor.constraint(equalTo: view.topAnchor, constant: 120)
        scrubberBottom = scrubber.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -110)
        NSLayoutConstraint.activate([
            scrubberTop!,
            scrubberBottom!,
            scrubber.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrubber.widthAnchor.constraint(equalToConstant: 260),
        ])

        scrubber.onScrub = { [weak self] fraction in self?.scrub(to: fraction) }
        scrubber.onScrubEnded = { [weak self] in self?.loadVisibleTilesIfIdle() }
        scrubber.labelForFraction = { [weak self] fraction in self?.monthLabel(atFraction: fraction) }

        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))

        selectPan = UIPanGestureRecognizer(target: self, action: #selector(dragSelect(_:)))
        selectPan.delegate = self
        collectionView.addGestureRecognizer(selectPan)
        collectionView.panGestureRecognizer.require(toFail: selectPan)
        applyInsets()
    }

    private var scrubberTop: NSLayoutConstraint?
    private var scrubberBottom: NSLayoutConstraint?

    private func applyInsets() {
        guard isViewLoaded else { return }
        let wasAtBottom = isNearBottom
        collectionView.contentInset = UIEdgeInsets(top: contentInsets.top, left: 0, bottom: contentInsets.bottom, right: 0)
        collectionView.verticalScrollIndicatorInsets = collectionView.contentInset
        scrubberTop?.constant = contentInsets.top + 4
        scrubberBottom?.constant = -contentInsets.bottom - 4
        if wasAtBottom, didInitialScroll { scrollToBottom() }
    }

    /// Select mode › Share: opens the share screen at the first selected item, which
    /// shrinks from its tile into the carousel.
    /// `-ShareScreenSelfTest`: opens the share screen on the newest photo and video.
    private var didRunShareSelfTest = false
    private func runShareSelfTestIfNeeded() {
        guard ScreenCapture.isEnabled, !didRunShareSelfTest, !items.isEmpty, view.window != nil else { return }
        didRunShareSelfTest = true
        ScreenCapture.reset()
        ScreenCapture.log("grid ready with \(items.count) items")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let recent = self.items.suffix(60)
            let photo = recent.last { !$0.isVideo }
            let video = recent.last { $0.isVideo }
            let selection = [photo, video].compactMap { $0?.id }
            ScreenCapture.log("selection \(selection), presented: \(String(describing: self.presentedViewController))")
            self.presentShare(selection: selection)
        }
    }

    func presentShare(selection: [String]) {
        guard let first = selection.first, let index = items.firstIndex(where: { $0.id == first }), presentedViewController == nil else { return }
        let tile = transitionTile(for: first, scrollIntoView: true)
        guard let screen = makeShare?(items, index, selection, tile, { [weak self] item in self?.placeholderImage(for: item) }) else { return }
        present(screen, animated: false)
    }

    /// The image a visible tile shows (phone photos have no server cache to look in).
    private func visibleTileImage(for id: String) -> UIImage? {
        for case let cell as PhotoGridCell in collectionView.visibleCells where cell.assetID == id {
            return cell.currentImage
        }
        return nil
    }

    private func placeholderImage(for item: TimelineItem) -> UIImage? {
        if item.localID != nil, let tile = visibleTileImage(for: item.id) { return tile }
        if let cached = pipeline.cachedImage(assetID: item.id, size: .thumbnail, maxPixelSize: Self.thumbnailPixelSize) {
            return UIImage(cgImage: cached)
        }
        return placeholders.image(for: item)
    }

    /// The selection changed outside the grid (Deselect All, the selected-items sheet).
    func refreshSelection() {
        reconfigureVisibleCells()
    }

    private func reconfigureVisibleCells() {
        guard isViewLoaded else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell, indexPath.item < items.count else { continue }
            let item = items[indexPath.item]
            cell.setDisplay(aspectFit: aspectRatioGrid, selectable: isSelecting, selected: isSelected(item.id))
            cell.setCaption(caption?(item))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        runShareSelfTestIfNeeded()
        if !didInitialScroll, !items.isEmpty, collectionView.bounds.height > 0 {
            didInitialScroll = true
            scrollToBottom()
        }
        reportScroll()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        let anchor = captureAnchor()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
            self.restore(anchor)
        }
    }

    // MARK: Data

    /// Replaces the items, keeping whatever is on screen in place (new photos arrive
    /// at the bottom; older ones synced later arrive above).
    func apply(items newItems: [TimelineItem], version newVersion: Int) {
        guard newVersion != version else { return }
        defer { DispatchQueue.main.async { self.runShareSelfTestIfNeeded() } }
        if isZooming {
            deferredItems = (newItems, newVersion)
            return
        }
        version = newVersion
        guard isViewLoaded else {
            items = newItems
            return
        }
        let wasAtBottom = isNearBottom
        let anchor = items.isEmpty ? nil : captureAnchor()
        items = newItems
        gridLayout.setAspectRatios(newItems.map(\.aspectRatio))
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        if !didInitialScroll || wasAtBottom {
            if !items.isEmpty, collectionView.bounds.height > 0 {
                didInitialScroll = true
                scrollToBottom()
            }
        } else {
            restore(anchor)
        }
        reportScroll()
        loadVisibleTilesIfIdle()
    }

    private var isNearBottom: Bool {
        let insets = collectionView.adjustedContentInset
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        return collectionView.contentOffset.y >= maxOffset - max(gridLayout.itemSide, 44)
    }

    private func scrollToBottom() {
        let insets = collectionView.adjustedContentInset
        let maxOffset = max(-insets.top, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: false)
    }

    private struct Anchor {
        let id: String
        let viewY: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard let index = gridLayout.index(near: CGPoint(x: 1, y: max(0, visibleTop))), index < items.count else { return nil }
        let frame = gridLayout.frame(forItemAt: index)
        return Anchor(id: items[index].id, viewY: frame.minY - collectionView.contentOffset.y)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let index = items.firstIndex(where: { $0.id == anchor.id }) else { return }
        let frame = gridLayout.frame(forItemAt: index)
        let offset = gridLayout.clampedOffset(placing: frame.origin, atViewY: anchor.viewY, in: collectionView)
        collectionView.setContentOffset(offset, animated: false)
    }

    // MARK: Scrubbing and date header

    private var scrollFraction: CGFloat {
        let insets = collectionView.adjustedContentInset
        let range = collectionView.contentSize.height - collectionView.bounds.height + insets.top + insets.bottom
        guard range > 0 else { return 1 }
        return (collectionView.contentOffset.y + insets.top) / range
    }

    private func scrub(to fraction: CGFloat) {
        let insets = collectionView.adjustedContentInset
        let range = collectionView.contentSize.height - collectionView.bounds.height + insets.top + insets.bottom
        guard range > 0 else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: fraction * range - insets.top), animated: false)
    }

    private func monthLabel(atFraction fraction: CGFloat) -> String? {
        guard !items.isEmpty else { return nil }
        let insets = collectionView.adjustedContentInset
        let range = collectionView.contentSize.height - collectionView.bounds.height + insets.top + insets.bottom
        let y = max(0, fraction * range + collectionView.bounds.height / 2 - insets.top)
        guard let index = gridLayout.index(near: CGPoint(x: 1, y: y)) else { return nil }
        return Formatting.monthYear(items[index].date)
    }

    /// Tells the Library header what's on screen (only when something changed).
    private func reportScroll(userScrolled: Bool = false) {
        guard isViewLoaded, collectionView.bounds.height > 0 else { return }
        let offset = collectionView.contentOffset.y
        let visible = gridLayout.metrics.indexRange(
            minY: offset + contentInsets.top,
            maxY: offset + collectionView.bounds.height - contentInsets.bottom
        ).clamped(to: 0..<items.count)
        var range: ClosedRange<Date>?
        if !visible.isEmpty {
            var low = items[visible.lowerBound].date, high = low
            for index in visible {
                let date = items[index].date
                if date < low { low = date }
                if date > high { high = date }
            }
            range = low...high
        }
        let interacting = collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
            || scrubber.isDragging || isZooming || dragSelection != nil
        let atBottom = isNearBottom
        let report = (range, interacting, atBottom)
        let changed = lastReport.map { $0.range != range || $0.interacting != interacting || $0.atBottom != atBottom } ?? true
        let firstUserScroll = userScrolled && !userScrollReported
        if firstUserScroll { userScrollReported = true }
        guard changed || firstUserScroll else { return }
        lastReport = report
        onScrollInfo?(range, interacting, atBottom, firstUserScroll)
    }

    // MARK: Commands from the Library menus

    /// View Options › Zoom In / Zoom Out: one level, centred on the middle of the screen.
    func stepZoom(in zoomIn: Bool) {
        guard !items.isEmpty, !isZooming, let level = GridLevels.columns.firstIndex(of: columns) else { return }
        let next = zoomIn ? level - 1 : level + 1
        guard GridLevels.columns.indices.contains(next) else {
            limitHaptics.impactOccurred()
            return
        }
        let center = CGPoint(x: collectionView.bounds.midX, y: collectionView.contentOffset.y + collectionView.bounds.height / 2)
        guard let index = gridLayout.index(near: center) else { return }
        let frame = gridLayout.frame(forItemAt: index)
        let relativeY = min(max((center.y - frame.minY) / max(frame.height, 1), 0), 1)
        let pinch = Pinch(startSide: gridLayout.itemSide, anchorIndex: index, anchorRelativeY: relativeY,
                          fingerY: collectionView.bounds.height / 2, effectiveSide: gridLayout.itemSide)
        switchLevel(to: GridLevels.columns[next], pinch: pinch)
        onColumnsChanged?(columns)
        reportScroll()
        loadVisibleTilesIfIdle()
    }

    /// Years/Months › a month: shows the first photo on or after `date` near the top.
    func scroll(to date: Date) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.date >= date } ?? items.count - 1
        let frame = gridLayout.frame(forItemAt: index)
        let offset = gridLayout.clampedOffset(placing: frame.origin, atViewY: contentInsets.top + 8, in: collectionView)
        collectionView.setContentOffset(offset, animated: false)
        reportScroll()
        loadVisibleTilesIfIdle()
    }

    // MARK: Pinch to zoom

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginPinch(gesture)
        case .changed:
            updatePinch(gesture)
        case .ended:
            endPinch(velocity: gesture.velocity)
        case .cancelled, .failed:
            endPinch(velocity: 0)
        default:
            break
        }
    }

    private func beginPinch(_ gesture: UIPinchGestureRecognizer) {
        guard !items.isEmpty, !isSettling else { return }
        // Hold the grid still: stop any deceleration and keep the two-finger pan from scrolling it.
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        collectionView.panGestureRecognizer.isEnabled = false

        let finger = gesture.location(in: view)
        let contentPoint = CGPoint(x: finger.x, y: finger.y + collectionView.contentOffset.y)
        guard let index = gridLayout.index(near: contentPoint) else { return }
        let frame = gridLayout.frame(forItemAt: index)
        let relativeY = min(max((contentPoint.y - frame.minY) / max(frame.height, 1), 0), 1)
        pinch = Pinch(
            startSide: gridLayout.itemSide, anchorIndex: index, anchorRelativeY: relativeY,
            fingerY: finger.y, effectiveSide: gridLayout.itemSide
        )
        gesture.scale = 1
        levelHaptics.prepare()
        limitHaptics.prepare()
    }

    private func updatePinch(_ gesture: UIPinchGestureRecognizer) {
        guard var pinch else { return }
        let width = collectionView.bounds.width
        pinch.rawScale = gesture.scale
        pinch.fingerY = gesture.location(in: view).y
        let (side, clamped) = ZoomMath.clampSide(pinch.startSide * ZoomMath.visualScale(pinch.rawScale), width: width)
        if clamped && !pinch.atLimit { limitHaptics.impactOccurred() }
        pinch.atLimit = clamped
        pinch.effectiveSide = side
        self.pinch = pinch

        let level = ZoomMath.coveringLevel(effectiveSide: side, width: width, current: columns)
        if level != columns {
            switchLevel(to: level, pinch: pinch)
        }
        applyPose(effectiveSide: side, pinch: pinch)
    }

    private func endPinch(velocity: CGFloat) {
        collectionView.panGestureRecognizer.isEnabled = true
        guard let pinch else { return }
        self.pinch = nil

        let width = collectionView.bounds.width
        let projectedRaw = ZoomMath.projectedScale(pinch.rawScale, velocity: velocity)
        let projected = ZoomMath.clampSide(pinch.startSide * ZoomMath.visualScale(projectedRaw), width: width).side
        let target = ZoomMath.nearestLevel(effectiveSide: projected, width: width)
        let targetSide = GridLevels.side(columns: target, width: width)

        isSettling = true
        let settle = { (animations: @escaping () -> Void, completion: @escaping () -> Void) in
            UIView.animate(springDuration: 0.5, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: animations) { _ in completion() }
        }

        if targetSide > gridLayout.itemSide * 1.0001 {
            // Settling on bigger tiles: grow the denser grid shown now up to the target's
            // tile size (it keeps covering the screen), then swap to the target in place.
            settle({
                self.applyPose(effectiveSide: targetSide, pinch: pinch)
            }, {
                self.switchLevel(to: target, pinch: pinch)
                self.collectionView.transform = .identity
                self.finishSettling()
            })
        } else {
            // Settling on the shown level or a denser one: show it, then relax to natural size.
            if target != columns {
                switchLevel(to: target, pinch: pinch)
                applyPose(effectiveSide: pinch.effectiveSide, pinch: pinch)
            }
            settle({
                self.collectionView.transform = .identity
            }, {
                self.finishSettling()
            })
        }
    }

    private func finishSettling() {
        isSettling = false
        onColumnsChanged?(columns)
        finishZooming()
    }

    /// Scales the grid about the screen's horizontal centre so tiles appear
    /// `effectiveSide` wide, with the anchor row under the fingers (clamped so the
    /// grid always covers the screen).
    private func applyPose(effectiveSide: CGFloat, pinch: Pinch) {
        let scale = max(1, effectiveSide / max(gridLayout.itemSide, 0.01))
        let frame = gridLayout.frame(forItemAt: pinch.anchorIndex)
        let offsetY = collectionView.contentOffset.y
        let anchorY = frame.minY + pinch.anchorRelativeY * frame.height - offsetY
        let ty = ZoomMath.verticalTranslation(
            anchorY: anchorY,
            fingerY: pinch.fingerY,
            scale: scale,
            centerY: collectionView.bounds.height / 2,
            contentTop: -offsetY,
            contentBottom: gridLayout.collectionViewContentSize.height - offsetY,
            viewportHeight: collectionView.bounds.height
        )
        collectionView.transform = CGAffineTransform(translationX: 0, y: ty).scaledBy(x: scale, y: scale)
    }

    /// Shows another level in place. The old level is snapshotted at low resolution
    /// (so it looks blurred) and fades out over the new one, whose tiles start as
    /// cached thumbnails or blurred placeholders. The new level is scrolled so the
    /// anchor row is under the fingers.
    private func switchLevel(to level: Int, pinch: Pinch) {
        if let snapshot = collectionView.snapshotView(afterScreenUpdates: false) {
            fadingSnapshot?.removeFromSuperview()
            snapshot.bounds = CGRect(origin: .zero, size: collectionView.bounds.size)
            snapshot.center = collectionView.center
            snapshot.transform = collectionView.transform
            snapshot.isUserInteractionEnabled = false
            snapshot.layer.shouldRasterize = true
            snapshot.layer.rasterizationScale = 0.25
            snapshot.layer.minificationFilter = .linear
            snapshot.layer.magnificationFilter = .linear
            view.insertSubview(snapshot, aboveSubview: collectionView)
            fadingSnapshot = snapshot
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }

        let target = gridLayout.metrics(forColumns: level)
        let frame = target.frame(at: pinch.anchorIndex)
        let anchorY = frame.minY + pinch.anchorRelativeY * frame.height
        let insets = collectionView.adjustedContentInset
        let bounds = target.offsetBounds(viewportHeight: collectionView.bounds.height, insetTop: insets.top, insetBottom: insets.bottom)
        let offsetY = min(max(anchorY - pinch.fingerY, bounds.lowerBound), bounds.upperBound)

        UIView.performWithoutAnimation {
            gridLayout.setColumns(level)
            collectionView.contentOffset = CGPoint(x: 0, y: offsetY)
            collectionView.layoutIfNeeded()
        }
        columns = level
        levelHaptics.selectionChanged()
    }

    private func finishZooming() {
        if let deferred = deferredItems {
            deferredItems = nil
            apply(items: deferred.items, version: deferred.version)
        }
        reportScroll()
        loadVisibleTilesIfIdle()
    }

    // MARK: Loading policy per level

    /// How tiles load at the current level. The densest levels show hundreds to
    /// thousands of tiles, so they rely on placeholders and what's already cached.
    private var tileLoading: PhotoGridCell.Loading {
        switch columns {
        case ...5: .network
        case ...15: .cachedOnly(includingDisk: true)
        default: .cachedOnly(includingDisk: false)
        }
    }

    private func previewPixelSize(for index: Int) -> Int? {
        guard columns <= 3 else { return nil }
        let frame = gridLayout.frame(forItemAt: index)
        let pixels = max(frame.width, frame.height) * (view.window?.screen.scale ?? 3)
        return pixels > Self.previewThresholdPixels ? Int(pixels.rounded(.up)) : nil
    }

    private var isIdle: Bool {
        !isZooming && !collectionView.isDragging && !collectionView.isDecelerating && !scrubber.isDragging
    }

    /// Once the grid is at rest: sharper previews at 3 and 1 columns, real thumbnails at 15.
    /// Never mid-flick, to spare the Pi.
    private func loadVisibleTilesIfIdle() {
        guard isIdle else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? PhotoGridCell, let index = collectionView.indexPath(for: cell)?.item else { continue }
            if let size = previewPixelSize(for: index) {
                cell.upgradeToPreview(pipeline: pipeline, maxPixelSize: size)
            } else if columns > 5, columns <= 15 {
                cell.loadThumbnailIfNeeded(pipeline: pipeline, maxPixelSize: Self.thumbnailPixelSize)
            }
        }
    }
}

// MARK: - Data source, prefetching, delegate

extension PhotoGridViewController: UICollectionViewDataSource, UICollectionViewDataSourcePrefetching, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoGridCell.reuseIdentifier, for: indexPath) as! PhotoGridCell
        let item = items[indexPath.item]
        cell.phone = phoneImages
        cell.showsStatus = showsStatus
        cell.caption = caption?(item)
        let previewSize = previewPixelSize(for: indexPath.item)
        cell.configure(
            with: item,
            placeholder: placeholders.image(for: item),
            pipeline: pipeline,
            thumbnailPixelSize: Self.thumbnailPixelSize,
            previewPixelSize: previewSize,
            loading: tileLoading
        )
        if isIdle, let previewSize {
            cell.upgradeToPreview(pipeline: pipeline, maxPixelSize: previewSize)
        }
        cell.contentView.alpha = item.id == hiddenTileID ? 0 : 1
        cell.setDisplay(aspectFit: aspectRatioGrid, selectable: isSelecting, selected: isSelecting && isSelected(item.id))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // Dense levels don't prefetch: they'd queue hundreds of requests per screen.
        guard columns <= 5 else { return }
        for indexPath in indexPaths where indexPath.item < items.count {
            let item = items[indexPath.item]
            let id = item.id
            // Phone photos come from PhotoKit, which is fast enough without prefetching.
            guard item.localID == nil || phoneImages == nil, prefetchTasks[id] == nil else { continue }
            prefetchTasks[id] = Task { [pipeline] in
                await pipeline.prefetch(assetID: id, size: .thumbnail, revision: item.thumbhash)
            }
        }
        // Forget finished prefetches so the dictionary doesn't grow without bound.
        if prefetchTasks.count > 400 {
            prefetchTasks = prefetchTasks.filter { !$0.value.isCancelled }
            if prefetchTasks.count > 400 { prefetchTasks.removeAll() }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.item < items.count {
            prefetchTasks.removeValue(forKey: items[indexPath.item].id)?.cancel()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard indexPath.item < items.count, !isZooming, presentedViewController == nil else { return }
        if isSelecting {
            let id = items[indexPath.item].id
            let selected = !isSelected(id)
            onSelectionChange?([id], selected)
            (collectionView.cellForItem(at: indexPath) as? PhotoGridCell)?.setDisplay(aspectFit: aspectRatioGrid, selectable: true, selected: selected)
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        let placeholderFor: (TimelineItem) -> UIImage? = { [weak self] item in
            guard let self else { return nil }
            if item.localID != nil, let tile = self.visibleTileImage(for: item.id) { return tile }
            if let cached = self.pipeline.cachedImage(assetID: item.id, size: .thumbnail, maxPixelSize: Self.thumbnailPixelSize) {
                return UIImage(cgImage: cached)
            }
            return self.placeholders.image(for: item)
        }
        guard let viewer = makeViewer?(items, indexPath.item, self, placeholderFor) else { return }
        present(viewer, animated: true)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrollReported = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            loadVisibleTilesIfIdle()
            reportScroll()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        loadVisibleTilesIfIdle()
        reportScroll()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportScroll(userScrolled: scrollView.isDragging)
        guard scrollView.isDragging || scrollView.isDecelerating || scrubber.isDragging else { return }
        scrubber.scrollPositionChanged(fraction: scrollFraction)
    }
}

// MARK: - Zoom transition to and from the viewer

extension PhotoGridViewController: ViewerTransitionSource {
    func transitionTile(for itemID: String, scrollIntoView: Bool) -> (frame: CGRect, image: UIImage?)? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let indexPath = IndexPath(item: index, section: 0)
        if scrollIntoView {
            let frame = gridLayout.frame(forItemAt: index)
            let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
            if !visible.contains(frame) {
                // Centre the tile of the photo being closed.
                let offset = gridLayout.clampedOffset(placing: CGPoint(x: 0, y: frame.midY), atViewY: collectionView.bounds.height / 2, in: collectionView)
                collectionView.setContentOffset(offset, animated: false)
                collectionView.layoutIfNeeded()
                reportScroll()
            }
        }
        guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell else { return nil }
        return (cell.convert(cell.bounds, to: nil), cell.currentImage)
    }

    func setTransitionTileHidden(_ itemID: String?) {
        hiddenTileID = itemID
        for case let cell as PhotoGridCell in collectionView.visibleCells {
            cell.contentView.alpha = cell.assetID == itemID && itemID != nil ? 0 : 1
        }
    }
}

// MARK: - Helpers

/// Thumbhash placeholders, decoded once per asset. Sized for the 30-column level
/// (about 2,000 tiles on screen).
@MainActor
final class PlaceholderCache {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 6000
    }

    func image(for item: TimelineItem) -> UIImage? {
        guard let hash = item.thumbhash else { return nil }
        if let cached = cache.object(forKey: item.id as NSString) { return cached }
        guard let cgImage = ThumbHash.image(base64: hash) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: item.id as NSString)
        return image
    }
}

// MARK: - Drag to select

extension PhotoGridViewController: UIGestureRecognizerDelegate {
    /// In select mode, a sideways drag starts selecting (vertical drags still scroll).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === selectPan else { return true }
        guard isSelecting, !isZooming else { return false }
        let velocity = selectPan.velocity(in: collectionView)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func dragSelect(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let index = gridLayout.index(near: location), index < items.count else { return }
            let selecting = !isSelected(items[index].id)
            dragSelection = DragSelection(startIndex: index, selecting: selecting, location: location)
            updateDragSelection()
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            guard dragSelection != nil else { return }
            dragSelection?.location = location
            updateDragSelection()
            updateAutoScroll(viewY: gesture.location(in: view).y)
        default:
            dragSelection = nil
            stopAutoScroll()
            reportScroll()
        }
    }

    /// Applies the drag: everything between the first and current tile takes the
    /// drag's state; tiles the drag has left go back to how they were.
    private func updateDragSelection() {
        guard var drag = dragSelection, let current = gridLayout.index(near: drag.location), !items.isEmpty else { return }
        let lower = min(drag.startIndex, current), upper = max(drag.startIndex, current)
        var toSelect: [String] = [], toDeselect: [String] = []

        for (index, wasSelected) in drag.original where index < lower || index > upper {
            if wasSelected { toSelect.append(items[index].id) } else { toDeselect.append(items[index].id) }
            drag.original[index] = nil
        }
        for index in lower...upper where index < items.count {
            let id = items[index].id
            let now = isSelected(id)
            if drag.original[index] == nil { drag.original[index] = now }
            if now != drag.selecting {
                if drag.selecting { toSelect.append(id) } else { toDeselect.append(id) }
            }
        }
        dragSelection = drag
        if !toSelect.isEmpty { onSelectionChange?(toSelect, true) }
        if !toDeselect.isEmpty { onSelectionChange?(toDeselect, false) }
        if !toSelect.isEmpty || !toDeselect.isEmpty { reconfigureVisibleCells() }
    }

    /// Near the top or bottom edge the grid scrolls by itself, faster the closer the finger.
    private func updateAutoScroll(viewY: CGFloat) {
        let zone: CGFloat = 80
        let top = contentInsets.top + zone
        let bottom = view.bounds.height - contentInsets.bottom - zone
        if viewY < top {
            autoScrollSpeed = -min(1, (top - viewY) / zone) * 900
        } else if viewY > bottom {
            autoScrollSpeed = min(1, (viewY - bottom) / zone) * 900
        } else {
            autoScrollSpeed = 0
        }
        if autoScrollSpeed != 0, autoScrollLink == nil {
            let link = CADisplayLink(target: AutoScrollProxy(self), selector: #selector(AutoScrollProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        } else if autoScrollSpeed == 0 {
            stopAutoScroll()
        }
    }

    fileprivate func autoScrollTick(duration: CFTimeInterval) {
        guard dragSelection != nil, autoScrollSpeed != 0 else {
            stopAutoScroll()
            return
        }
        let insets = collectionView.contentInset
        let minY = -insets.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        let previous = collectionView.contentOffset.y
        let next = min(max(previous + autoScrollSpeed * CGFloat(duration), minY), maxY)
        guard next != previous else { return }
        collectionView.contentOffset.y = next
        // The finger stays put on screen while the content moves under it.
        dragSelection?.location.y += next - previous
        updateDragSelection()
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollSpeed = 0
    }

    @MainActor
    private final class AutoScrollProxy: NSObject {
        weak var owner: PhotoGridViewController?
        init(_ owner: PhotoGridViewController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.autoScrollTick(duration: link.targetTimestamp - link.timestamp) }
    }
}
