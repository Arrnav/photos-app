import Core
import CloudCore
import MediaCache
import Persistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The full-screen viewer, styled for iOS 26: floating glass
/// controls, a thumbnail strip, paging with a soft spring, pinch and double-tap
/// zoom, swipe down to go back to the grid, and swipe up (or ⓘ) for an info panel
/// that slides the photo up. Tapping hides and shows the controls.
final class ViewerViewController: UIViewController {
    enum TransitionState { case idle, presenting, presented, dismissing, dismissed }
    /// The library, or the Hidden album (Immich Locked Folder).
    /// `.trash`: opened from Recently Deleted (Delete for good and Recover only).
    enum Mode { case library, hidden, trash }

    private(set) var items: [TimelineItem]
    private var currentIndex: Int
    private let session: LibrarySession
    private let placeholder: (TimelineItem) -> UIImage?
    private let transitionController: ViewerTransitionController
    private let media: ViewerMedia
    private let mode: Mode
    private var slideshowTimer: Timer?

    private var collectionView: UICollectionView!
    private let backgroundView = UIView()
    private let topBar = ViewerTopBar()
    private let bottomBar = ViewerBottomBar()
    private let videoControls = VideoControlsView()
    /// The video controls hide first whenever the viewer is leaving the video (closing, a
    /// drag down, or the info panel opening), before those animations run.
    private var videoControlsSuppressed = false {
        didSet {
            guard videoControlsSuppressed != oldValue else { return }
            if videoControlsSuppressed {
                // Hide at once, before the closing or info animation starts.
                videoControls.layer.removeAllAnimations()
                UIView.performWithoutAnimation { self.videoControls.alpha = 0 }
            } else {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.applyVideoControlsVisibility()
                }
            }
        }
    }
    private let liveBadge = LiveBadgeButton()
    private let airPlayButton = AirPlayButton()
    private let airPlayPhotos = AirPlayPhotoPresenter()
    private lazy var filmstrip = FilmstripView(pipeline: session.pipeline, placeholder: placeholder)
    private let banner = UndoBanner()
    private var chromeHidden = false
    private var transitionState = TransitionState.idle
    private var shareTask: Task<Void, Never>?

    /// Gap between pages while swiping (a generous one).
    private let pageGap: CGFloat = 30
    private var dragStartIndex = 0
    private let pageAnimator = ScrollAnimator()
    /// Release-to-nearest-page snap (1.8× quicker than UIKit's ~0.3 s scroll animation).
    private let snapDuration: CFTimeInterval = 0.17

    // Vertical gestures: swipe down to dismiss, up/down to move the info panel.
    private var verticalPan: UIPanGestureRecognizer!
    private enum VerticalMode { case dismiss, panel }
    private var verticalMode: VerticalMode?
    private var panelStartTop: CGFloat = 0

    // Info panel
    private var infoModel: InfoModel?
    private var infoPanel: InfoPanelView?
    private var panelTop: CGFloat = .greatestFiniteMagnitude
    private var infoStop = InfoPanelGeometry.Stop.hidden

    init(items: [TimelineItem], index: Int, session: LibrarySession, source: ViewerTransitionSource, mode: Mode = .library, placeholder: @escaping (TimelineItem) -> UIImage?) {
        self.items = items
        self.mode = mode
        currentIndex = min(max(index, 0), max(items.count - 1, 0))
        self.session = session
        self.placeholder = placeholder
        transitionController = ViewerTransitionController(source: source)
        media = ViewerMedia(
            pipeline: session.pipeline,
            originals: session.originals,
            loadsOriginalWhenSettled: { [weak session] in session?.isOnHomeNetwork ?? false },
            phone: session.phoneImages,
            videoStream: { [weak session] id in session?.connection?.media.videoStream(assetID: id) },
            motionPart: { [weak session] id in
                guard let session, let motionID = session.detailsNow(for: id)?.asset.livePhotoVideoId,
                      let motion = session.detailsNow(for: motionID) else { return nil }
                return (motionID, motion.asset.originalFileName)
            },
            airPlayURL: { [weak session] id in
                guard let session else { throw CancellationError() }
                return try await session.airPlayVideoURL(assetID: id)
            },
            releaseAirPlay: { [weak session] in session?.releaseAirPlayLinks() }
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        transitioningDelegate = transitionController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var currentItem: TimelineItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }

    private var currentPage: ViewerPageCell? {
        collectionView?.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? ViewerPageCell
    }

    var currentPageImage: UIImage? {
        currentPage?.zoomView.imageView.image ?? currentItem.flatMap(placeholder)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backgroundView.frame = view.bounds
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundView.backgroundColor = .systemBackground
        view.addSubview(backgroundView)

        let layout = PagerLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: pagerFrame, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        // Between .fast and .normal: the settle onto the next photo eases in
        // (time constant ~138 ms, 1.2× quicker than the earlier 0.994).
        collectionView.decelerationRate = UIScrollView.DecelerationRate(rawValue: 0.9928)
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(ViewerPageCell.self, forCellWithReuseIdentifier: ViewerPageCell.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        view.addSubview(collectionView)

        videoControls.alpha = 0
        for subview in [topBar, filmstrip, videoControls, bottomBar, banner, liveBadge, airPlayButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            filmstrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -14),
            videoControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Above the filmstrip, which stays visible for videos (reference v1).
            videoControls.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -10),
            videoControls.heightAnchor.constraint(equalToConstant: 76),
            liveBadge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            liveBadge.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            liveBadge.heightAnchor.constraint(equalToConstant: 30),
            airPlayButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            airPlayButton.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            airPlayButton.widthAnchor.constraint(equalToConstant: Glass.controlHeight),
            airPlayButton.heightAnchor.constraint(equalToConstant: Glass.controlHeight),
            banner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            banner.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -12),
        ])

        liveBadge.onChange = { [weak self] off in self?.currentPage?.setLiveOff(off) }
        // While scrubbing a video, everything but the scrubber hides (reference v2).
        videoControls.onScrubbingChanged = { [weak self] _ in
            guard let self else { return }
            UIView.animate(withDuration: 0.2) { self.setChromeAlpha(self.chromeHidden ? 0 : 1) }
        }
        airPlayPhotos.attach(to: view)
        airPlayPhotos.onRouteChange = { [weak self] _ in self?.sendCurrentToAirPlay() }
        airPlayButton.onAvailabilityChange = { [weak self] _ in self?.updateChrome() }
        topBar.backButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        bottomBar.shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)
        bottomBar.favoriteButton.addTarget(self, action: #selector(toggleFavorite), for: .touchUpInside)
        bottomBar.infoButton.addTarget(self, action: #selector(toggleInfo), for: .touchUpInside)
        bottomBar.editButton.addTarget(self, action: #selector(openEditor), for: .touchUpInside)
        bottomBar.deleteButton.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)
        if mode == .trash {
            bottomBar.showTrashActions()
            bottomBar.purgeButton.addTarget(self, action: #selector(confirmPurge), for: .touchUpInside)
            bottomBar.recoverButton.addTarget(self, action: #selector(recoverCurrent), for: .touchUpInside)
            topBar.menuButton.isHidden = true
        }
        filmstrip.setItems(items, current: currentIndex)
        filmstrip.onSelect = { [weak self] index in self?.jump(to: index) }

        verticalPan = UIPanGestureRecognizer(target: self, action: #selector(verticalDrag(_:)))
        verticalPan.delegate = self
        view.addGestureRecognizer(verticalPan)
        collectionView.panGestureRecognizer.require(toFail: verticalPan)

        updateChrome()
    }

    private var pagerFrame: CGRect {
        view.bounds.insetBy(dx: -pageGap / 2, dy: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = pagerFrame
        if collectionView.frame != frame || (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize != frame.size {
            collectionView.frame = frame
            if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
                layout.itemSize = frame.size
                layout.invalidateLayout()
            }
            // The offset first, so the current page never leaves the visible area (its cell stays).
            collectionView.contentOffset = CGPoint(x: CGFloat(currentIndex) * frame.width, y: 0)
            collectionView.layoutIfNeeded()
        }
        if let infoPanel {
            infoPanel.frame = CGRect(x: 0, y: panelTop, width: view.bounds.width, height: view.bounds.height - panelGeometry.top(for: .full))
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let index = currentIndex
        if infoStop != .hidden { setInfoStop(.hidden, animated: false) }
        // Keep the current page on screen throughout the resize, so its cell (and a playing
        // video) is never recycled: it resizes inside iOS's own rotation animation, including
        // a direct turn from one landscape side to the other.
        let pager = collectionView.collectionViewLayout as? PagerLayout
        pager?.pinnedPage = index
        coordinator.animate { _ in
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.collectionView.contentOffset = CGPoint(x: CGFloat(index) * self.collectionView.bounds.width, y: 0)
        } completion: { _ in
            pager?.pinnedPage = nil
            self.collectionView.contentOffset = CGPoint(x: CGFloat(self.currentIndex) * self.collectionView.bounds.width, y: 0)
        }
    }

    override var prefersStatusBarHidden: Bool {
        chromeHidden || transitionState == .presenting || infoStop != .hidden
    }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

    // MARK: Transition support

    func setTransitionState(_ state: TransitionState) {
        transitionState = state
        switch state {
        case .presenting:
            backgroundView.alpha = 0
            setChromeAlpha(0)
            collectionView.isHidden = true
        case .presented:
            backgroundView.alpha = 1
            setChromeAlpha(chromeHidden ? 0 : 1)
        case .idle:
            // Back on screen (presented, or a dismissal that was cancelled).
            videoControlsSuppressed = infoStop != .hidden
            collectionView.isHidden = false
            currentPage?.didBecomeCurrent()
            updateVideoControls()
            sendCurrentToAirPlay()
            if let id = currentItem?.id { SearchHistory.recordViewed(id) }
            setNeedsStatusBarAppearanceUpdate()
        case .dismissing:
            videoControlsSuppressed = true
            videoControls.alpha = 0
            currentPage?.video?.pause()
            collectionView.isHidden = true
            infoPanel?.isHidden = true
            banner.hide()
        case .dismissed:
            backgroundView.alpha = 0
            setChromeAlpha(0)
        }
    }

    /// Where the current photo appears at fit size, in `target`'s coordinates.
    func fittedImageFrame(in target: UIView) -> CGRect {
        view.convert(fittedFrame(for: currentItem), to: target)
    }

    private func fittedFrame(for item: TimelineItem?) -> CGRect {
        let bounds = view.bounds
        let ratio = item?.aspectRatio ?? 1
        let viewRatio = bounds.width / max(bounds.height, 1)
        let size = ratio > viewRatio
            ? CGSize(width: bounds.width, height: bounds.width / ratio)
            : CGSize(width: bounds.height * ratio, height: bounds.height)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Where the current photo is drawn right now (zoomed, mid-drag or moved up for info), in `target`'s coordinates.
    func currentImageFrame(in target: UIView) -> CGRect {
        guard let page = currentPage, page.zoomView.imageView.image != nil else { return fittedImageFrame(in: target) }
        return page.zoomView.imageFrame(in: target)
    }

    // MARK: Chrome

    /// Info panel openness (0 hidden … 1 at half or more): the top bar and strip fade with it.
    private var infoOpenness: CGFloat {
        infoPanel == nil ? 0 : panelGeometry.openness(panelTop: panelTop)
    }

    private func setChromeAlpha(_ alpha: CGFloat) {
        let openness = infoOpenness
        topBar.alpha = alpha * (1 - openness)
        let isLive = currentItem?.isLivePhoto == true
        liveBadge.alpha = isLive ? alpha * (1 - openness) : 0
        airPlayButton.alpha = airPlayButton.isAvailable ? alpha * (1 - openness) : 0
        let isVideo = currentItem?.isVideo == true && currentPage?.video != nil
        let scrubbing = videoControls.isScrubbing
        filmstrip.alpha = scrubbing ? 0 : alpha * (1 - openness)
        _ = isVideo
        applyVideoControlsVisibility()
        if scrubbing {
            topBar.alpha = 0
            bottomBar.alpha = 0
            liveBadge.alpha = 0
            airPlayButton.alpha = 0
            return
        }
        bottomBar.alpha = alpha
    }

    private func toggleChrome() {
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.22) {
            self.setChromeAlpha(self.chromeHidden ? 0 : 1)
            self.backgroundView.backgroundColor = self.chromeHidden ? .black : .systemBackground
            self.setNeedsStatusBarAppearanceUpdate()
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func updateChrome() {
        guard let item = currentItem else { return }
        let details = session.detailsNow(for: item.id)
        let place = details?.exif.flatMap { exif in [exif.city, exif.state].compactMap { $0 }.first { !$0.isEmpty } }
        let title = place ?? Formatting.relativeDay(item.date)
        let subtitle = place == nil
            ? Formatting.time(item.date)
            : "\(Formatting.relativeDay(item.date))  \(Formatting.time(item.date))"
        topBar.setTitle(title, subtitle: subtitle)
        bottomBar.setFavorite(item.isFavorite)
        bottomBar.setInfoShown(infoStop != .hidden)
        topBar.menuButton.menu = moreMenu(for: item)
        liveBadge.set(off: LivePhotoSettings.isOff(item.id))
        setChromeAlpha(chromeHidden ? 0 : 1)
    }

    /// The ··· menu: Copy · Duplicate · Hide on top, then Start Slideshow, Add To ▸ and Adjust Info ▸.
    private func moreMenu(for item: TimelineItem) -> UIMenu {
        let copy = UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copyCurrent()
        }
        let duplicate = UIAction(title: String(localized: "Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.duplicateCurrent()
        }
        let hide: UIAction = mode == .hidden
            ? UIAction(title: String(localized: "Unhide"), image: UIImage(systemName: "eye")) { [weak self] _ in self?.unhideCurrent() }
            : UIAction(title: String(localized: "Hide"), image: UIImage(systemName: "eye.slash")) { [weak self] _ in self?.confirmHide() }
        let row = UIMenu(options: .displayInline, preferredElementSize: .medium, children: [copy, duplicate, hide])

        let slideshow = UIAction(title: String(localized: "Start Slideshow"), image: UIImage(systemName: "play.rectangle")) { [weak self] _ in
            self?.startSlideshow()
        }

        let addTo = UIMenu(title: String(localized: "Add To"), image: UIImage(systemName: "photo.on.rectangle.angled"), children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Album"), image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                    self?.presentSheet { session, ids, done in AlbumPickerView(session: session, shared: false, assetIDs: ids, onDone: done) }
                },
                UIAction(title: String(localized: "Shared Album"), image: UIImage(systemName: "rectangle.stack.badge.person.crop")) { [weak self] _ in
                    self?.presentSheet { session, ids, done in AlbumPickerView(session: session, shared: true, assetIDs: ids, onDone: done) }
                },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "New Album"), image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                    self?.presentSheet { session, ids, done in NewAlbumView(session: session, shared: false, assetIDs: ids, onDone: done) }
                },
                UIAction(title: String(localized: "New Shared Album"), image: UIImage(systemName: "rectangle.stack.badge.person.crop")) { [weak self] _ in
                    self?.presentSheet { session, ids, done in NewAlbumView(session: session, shared: true, assetIDs: ids, onDone: done) }
                },
            ]),
        ])

        let adjustInfo = UIMenu(title: String(localized: "Adjust Info"), image: UIImage(systemName: "info.circle"), children: [
            UIAction(title: String(localized: "Adjust Date & Time"), image: UIImage(systemName: "calendar.badge.clock")) { [weak self] _ in
                self?.presentDetailsSheet { session, details, done in AdjustDateView(session: session, details: details, onDone: done) }
            },
            UIAction(title: String(localized: "Adjust Location"), image: UIImage(systemName: "mappin.and.ellipse")) { [weak self] _ in
                self?.presentDetailsSheet { session, details, done in AdjustLocationView(session: session, details: details, onDone: done) }
            },
        ])

        // Only on this iPhone: the Cloud actions need it backed up first.
        guard item.isRemote else {
            return UIMenu(children: [
                UIMenu(options: .displayInline, preferredElementSize: .medium, children: [copy]),
                UIMenu(options: .displayInline, children: [slideshow]),
            ])
        }
        // Locked (hidden) assets can't be in albums on Immich, so Add To is only offered in the library.
        let collections = mode == .hidden ? [adjustInfo] : [addTo, adjustInfo]
        var sections: [UIMenuElement] = [
            row,
            UIMenu(options: .displayInline, children: [slideshow]),
            UIMenu(options: .displayInline, children: collections),
        ]
        if !item.isLocal && mode == .library {
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Save to This iPhone"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.saveCurrentToPhone()
                },
            ]))
        }
        return UIMenu(children: sections)
    }

    private func presentSheet<Content: View>(_ make: (LibrarySession, [String], @escaping (String) -> Void) -> Content) {
        guard let item = currentItem else { return }
        let sheet = UIHostingController(rootView: make(session, [item.id]) { [weak self] message in
            self?.banner.show(message)
        })
        present(sheet, animated: true)
    }

    private func presentDetailsSheet<Content: View>(_ make: (LibrarySession, AssetDetails, @escaping (String) -> Void) -> Content) {
        guard let item = currentItem, let details = session.detailsNow(for: item.id) else { return }
        let sheet = UIHostingController(rootView: make(session, details) { [weak self] message in
            self?.banner.show(message)
            self?.updateChrome()
        })
        present(sheet, animated: true)
    }

    private func duplicateCurrent() {
        guard let item = currentItem else { return }
        banner.show(String(localized: "Duplicating…"), duration: 600)
        Task {
            do {
                try await session.duplicate(assetID: item.id, keepHidden: mode == .hidden)
                banner.show(item.isVideo ? String(localized: "Video duplicated") : String(localized: "Photo duplicated"))
            } catch {
                banner.hide()
                showError(error)
            }
        }
    }

    /// A confirmation above the button, then the photo leaves the library.
    private func confirmHide() {
        guard let item = currentItem else { return }
        let noun = item.isVideo ? String(localized: "video") : String(localized: "photo")
        let sheet = UIAlertController(
            title: nil,
            message: String(localized: "This \(noun) will be hidden, but can be found in the Hidden album in Collections › Utilities."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: item.isVideo ? String(localized: "Hide Video") : String(localized: "Hide Photo"), style: .default) { [weak self] _ in
            self?.removeCurrent(
                message: String(localized: "Hidden"),
                perform: { session, ids in try await session.hide(assetIDs: ids) },
                undo: { session, ids in try await session.unhide(assetIDs: ids) }
            )
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = topBar.menuButton
        present(sheet, animated: true)
    }

    private func unhideCurrent() {
        removeCurrent(
            message: String(localized: "Unhidden"),
            perform: { session, ids in try await session.unhide(assetIDs: ids) },
            undo: { session, ids in try await session.hide(assetIDs: ids) }
        )
    }

    // MARK: Slideshow

    private var isSlideshowRunning: Bool { slideshowTimer != nil }

    /// Plays forward from the current photo, cross-fading every 3 seconds, with the controls hidden.
    private func startSlideshow() {
        guard !isSlideshowRunning, currentIndex < items.count - 1 else { return }
        if infoStop != .hidden { setInfoStop(.hidden, animated: false) }
        if !chromeHidden { toggleChrome() }
        UIApplication.shared.isIdleTimerDisabled = true
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceSlideshow() }
        }
    }

    private func advanceSlideshow() {
        guard currentIndex < items.count - 1 else {
            stopSlideshow()
            return
        }
        let snapshot = currentPage?.zoomView.snapshotView(afterScreenUpdates: false)
        if let snapshot, let page = currentPage {
            snapshot.frame = page.zoomView.convert(page.zoomView.bounds, to: view)
            view.insertSubview(snapshot, aboveSubview: collectionView)
        }
        jump(to: currentIndex + 1)
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.3 : 0.8, delay: 0, options: [.curveEaseInOut]) {
            snapshot?.alpha = 0
        } completion: { _ in
            snapshot?.removeFromSuperview()
        }
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if chromeHidden { toggleChrome() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            airPlayPhotos.stop()
            ExternalDisplay.shared.clear()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isSlideshowRunning { stopSlideshow() }
    }

    // MARK: Actions

    @objc private func close() {
        videoControlsSuppressed = true
        videoControls.alpha = 0
        dismiss(animated: true)
    }

    /// The Edit screen for the current photo or video.
    @objc private func openEditor() {
        guard let item = currentItem else { return }
        if isSlideshowRunning { stopSlideshow() }
        currentPage?.video?.pause()
        let model = EditorModel(item: item, session: session)
        var host: UIHostingController<EditorView>?
        let editor = EditorView(model: model) { [weak self] saved in
            host?.dismiss(animated: true)
            guard saved, let self else { return }
            self.banner.show(String(localized: "Edit saved"))
            // The phone's library or the next sync brings the new version; show it now.
            self.session.phoneImages.libraryChanged()
            let path = IndexPath(item: self.currentIndex, section: 0)
            UIView.performWithoutAnimation { self.collectionView.reloadItems(at: [path]) }
            DispatchQueue.main.async { self.settleOnCurrentPage() }
        }
        host = UIHostingController(rootView: editor)
        host?.modalPresentationStyle = .fullScreen
        host?.modalTransitionStyle = .crossDissolve
        if let host { present(host, animated: true) }
    }

    @objc private func toggleInfo() {
        setInfoStop(infoStop == .hidden ? .half : .hidden, animated: true)
    }

    @objc private func toggleFavorite() {
        guard let item = currentItem else { return }
        let newValue = !item.isFavorite
        replace(item, with: item.withFavorite(newValue))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await session.setFavorite(newValue, assetIDs: [item.id])
            } catch {
                if let current = items.first(where: { $0.id == item.id }) {
                    replace(current, with: current.withFavorite(!newValue))
                }
                showError(error)
            }
        }
    }

    private func replace(_ item: TimelineItem, with updated: TimelineItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = updated
        if index == currentIndex { updateChrome() }
    }

    /// The confirmation popover above the Delete button.
    @objc private func confirmDelete() {
        guard let item = currentItem else { return }
        let noun = item.isVideo ? String(localized: "video") : String(localized: "photo")
        let days = session.trashRetentionDays
        // Deleted from this iPhone too (iOS asks first).
        let message = switch (item.isRemote, item.isLocal) {
        case (true, true): String(localized: "This \(noun) will be deleted from this iPhone and from Cloud. You can recover it from Recently Deleted for \(days) days.")
        case (false, _): String(localized: "This \(noun) will be deleted from this iPhone. It stays in the iPhone's Recently Deleted for 30 days.")
        default: String(localized: "This \(noun) will be deleted from Cloud. You can recover it from Recently Deleted for \(days) days.")
        }
        let sheet = UIAlertController(title: nil, message: message, preferredStyle: .actionSheet)
        let title = item.isVideo ? String(localized: "Delete Video") : String(localized: "Delete Photo")
        sheet.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
            self?.removeCurrent(
                message: item.isRemote ? String(localized: "Moved to Recently Deleted") : String(localized: "Deleted from iPhone"),
                perform: { session, ids in try await session.moveToTrash(assetIDs: ids) },
                undo: item.isRemote ? { session, ids in try await session.restoreFromTrash(assetIDs: ids) } : nil
            )
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = bottomBar.deleteButton
        present(sheet, animated: true)
    }

    private func saveCurrentToPhone() {
        guard let item = currentItem else { return }
        banner.show(String(localized: "Saving to iPhone…"), duration: 600)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.saveToPhone(item)
                self.banner.show(String(localized: "Saved to iPhone"))
            } catch {
                self.banner.hide()
                self.showError(error)
            }
        }
    }

    private func archiveCurrent() {
        removeCurrent(
            message: String(localized: "Archived"),
            perform: { session, ids in try await session.setArchived(true, assetIDs: ids) },
            undo: { session, ids in try await session.setArchived(false, assetIDs: ids) }
        )
    }

    /// Recently Deleted › Delete: for good, after a confirmation.
    @objc private func confirmPurge() {
        guard let item = currentItem else { return }
        let sheet = UIAlertController(
            title: nil,
            message: item.isVideo
                ? String(localized: "This video will be deleted from Cloud. This action can't be undone.")
                : String(localized: "This photo will be deleted from Cloud. This action can't be undone."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: item.isVideo ? String(localized: "Delete Video") : String(localized: "Delete Photo"), style: .destructive) { [weak self] _ in
            self?.removeCurrent(message: String(localized: "Deleted"), perform: { session, ids in try await session.deletePermanently(assetIDs: ids) }, undo: nil)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = bottomBar.purgeButton
        present(sheet, animated: true)
    }

    /// Recently Deleted › Recover: back to the Library at once (no confirmation here).
    @objc private func recoverCurrent() {
        removeCurrent(message: String(localized: "Recovered"), perform: { session, ids in try await session.restoreFromTrash(assetIDs: ids) }, undo: nil)
    }

    /// Removes the current item from the viewer (trash or archive), with Undo.
    private func removeCurrent(
        message: String,
        perform: @escaping @MainActor (LibrarySession, [String]) async throws -> Void,
        undo: (@MainActor (LibrarySession, [String]) async throws -> Void)?
    ) {
        guard let item = currentItem else { return }
        let index = currentIndex
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await perform(self.session, [item.id])
            } catch is CancellationError {
                return
            } catch {
                self.showError(error)
                return
            }
            // Look the item up again: the user may have swiped while the server answered.
            guard let position = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.removeItem(at: position)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            guard let undo else {
                self.banner.show(message)
                return
            }
            self.banner.show(message, actionTitle: String(localized: "Undo")) { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        try await undo(self.session, [item.id])
                        self.insert(item, at: index)
                    } catch {
                        self.showError(error)
                    }
                }
            }
        }
    }

    private func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if items.isEmpty {
            dismiss(animated: true)
            return
        }
        currentIndex = min(index, items.count - 1)
        collectionView.performBatchUpdates {
            collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
        } completion: { _ in
            self.settleOnCurrentPage()
        }
        filmstrip.setItems(items, current: currentIndex)
        updateChrome()
    }

    private func insert(_ item: TimelineItem, at index: Int) {
        let position = min(index, items.count)
        items.insert(item, at: position)
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: [IndexPath(item: position, section: 0)])
        }
        filmstrip.setItems(items, current: position)
        jump(to: position)
    }

    /// Downloads the original (with progress and Cancel) and hands the file to `use`.
    private func withOriginal(of item: TimelineItem, _ use: @escaping @MainActor (URL) -> Void) {
        guard shareTask == nil else { return }
        if let localID = item.localID {
            let phone = session.phoneImages
            shareTask = Task { [weak self] in
                defer { self?.shareTask = nil }
                do { use(try await phone.exportFile(localID: localID)) } catch { self?.showError(error) }
            }
            return
        }
        let fileName = session.detailsNow(for: item.id)?.asset.originalFileName ?? "\(item.id).jpg"
        let originals = session.originals
        let banner = banner
        shareTask = Task { [weak self] in
            defer { self?.shareTask = nil }
            let needsDownload = originals.cachedFile(assetID: item.id) == nil
            if needsDownload {
                banner.show(String(localized: "Preparing original…"), actionTitle: String(localized: "Cancel"), duration: 600) {
                    self?.shareTask?.cancel()
                }
            }
            do {
                let url = try await originals.file(assetID: item.id, fileName: fileName) { progress in
                    Task { @MainActor in
                        guard needsDownload, progress < 1 else { return }
                        banner.setMessage(String(localized: "Preparing original… \(Int(progress * 100))%"))
                    }
                }
                guard !Task.isCancelled else { return }
                banner.hide()
                use(url)
            } catch is CancellationError {
                banner.hide()
            } catch {
                banner.hide()
                self?.showError(error)
            }
        }
    }

    /// Opens the share screen; the photo shrinks into its carousel.
    @objc private func share() {
        guard let item = currentItem else { return }
        if isSlideshowRunning { stopSlideshow() }
        if infoStop != .hidden { setInfoStop(.hidden, animated: false) }
        let page = currentPage
        page?.zoomView.resetZoom(animated: false)
        let origin = page.map { (frame: $0.zoomView.imageFrame(in: nil), image: $0.zoomView.imageView.image) }
        let screen = ShareScreenViewController(
            items: items, startIndex: currentIndex, selection: [item.id], session: session,
            origin: origin, placeholder: placeholder
        )
        page?.zoomView.alpha = 0
        screen.onClose = { [weak self, weak page] _ in
            UIView.animate(withDuration: 0.2) { page?.zoomView.alpha = 1 }
            self?.setNeedsStatusBarAppearanceUpdate()
        }
        present(screen, animated: false)
    }

    /// Copies the original file (full quality, with metadata) to the clipboard.
    private func copyCurrent() {
        guard let item = currentItem else { return }
        withOriginal(of: item) { [weak self] url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .image
            UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
            self?.banner.show(item.isVideo ? String(localized: "Video copied") : String(localized: "Photo copied"))
        }
    }

    private func showError(_ error: any Error) {
        let message = (error as? CloudError)?.message ?? (error as? MediaError)?.message ?? error.localizedDescription
        let alert = UIAlertController(title: String(localized: "Couldn’t Complete"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// One-tap AirPlay: the current photo goes to the TV (videos play there from their page).
    private func sendCurrentToAirPlay() {
        // A connected TV (Screen Mirroring / cable) shows the current photo or video full screen.
        if let item = currentItem {
            if item.isVideo, let player = currentPage?.video?.player {
                ExternalDisplay.shared.show(player: player)
            } else {
                ExternalDisplay.shared.show(image: currentPage?.zoomView.imageView.image)
            }
        }
        guard airPlayPhotos.isRouteActive, let item = currentItem else { return }
        if item.isVideo {
            airPlayPhotos.yieldToVideo()
        } else if let image = currentPage?.zoomView.imageView.image {
            airPlayPhotos.show(image, key: item.id)
        }
    }

    /// Video pages swap the filmstrip for video controls (bound to the page's player).
    private func updateVideoControls() {
        let playback = currentItem?.isVideo == true ? currentPage?.video : nil
        videoControls.bind(playback)
        applyVideoControlsVisibility()
    }

    /// The single place that decides whether the video capsule shows: only on a video page
    /// that is fully presented, with the info panel closed and nothing being dismissed.
    /// (Progress updates arrive 30 times a second and must never bring it back.)
    private func applyVideoControlsVisibility() {
        let visible = currentItem?.isVideo == true && currentPage?.video != nil && !videoControlsSuppressed
            && infoStop == .hidden && transitionState == .idle
        if !visible {
            videoControls.alpha = 0
        } else {
            videoControls.alpha = videoControls.isScrubbing ? 1 : (chromeHidden ? 0 : 1)
        }
    }

    // MARK: Paging

    /// Moves straight to a page (filmstrip, undo).
    private func jump(to index: Int) {
        guard items.indices.contains(index) else { return }
        currentPage?.didResignCurrent()
        currentPage?.zoomView.transform = .identity
        currentIndex = index
        collectionView.layoutIfNeeded()
        collectionView.contentOffset = CGPoint(x: CGFloat(index) * collectionView.bounds.width, y: 0)
        collectionView.layoutIfNeeded()
        updateChrome()
        settleOnCurrentPage()
    }

    private func settleOnCurrentPage() {
        for cell in collectionView.visibleCells {
            guard let page = cell as? ViewerPageCell else { continue }
            if page.item?.id == currentItem?.id {
                page.didBecomeCurrent()
                updateVideoControls()
                sendCurrentToAirPlay()
                if let id = page.item?.id { SearchHistory.recordViewed(id) }
            } else {
                page.didResignCurrent()
                page.zoomView.transform = .identity
            }
        }
        applyPanelPosition()
        filmstrip.setCurrent(currentIndex, animated: true)
        if let item = currentItem, infoStop != .hidden {
            infoModel?.show(assetID: item.id, thumbnail: placeholder(item))
        }
    }

    // MARK: Info panel

    private var panelGeometry: InfoPanelGeometry {
        let fitted = fittedFrame(for: currentItem)
        return InfoPanelGeometry(height: view.bounds.height, photoTop: fitted.minY, photoHeight: fitted.height)
    }

    private func ensureInfoPanel() {
        guard infoPanel == nil, let item = currentItem else { return }
        let model = InfoModel(assetID: item.id, thumbnail: placeholder(item), session: session)
        let panel = InfoPanelView(model: model)
        addChild(panel.host)
        view.insertSubview(panel, belowSubview: topBar)
        panel.host.didMove(toParent: self)
        panel.scrollView.panGestureRecognizer.require(toFail: verticalPan)
        infoModel = model
        infoPanel = panel
        panelTop = view.bounds.height
        panel.frame = CGRect(x: 0, y: panelTop, width: view.bounds.width, height: view.bounds.height - panelGeometry.top(for: .full))
    }

    private func removeInfoPanel() {
        guard let panel = infoPanel else { return }
        panel.host.willMove(toParent: nil)
        panel.removeFromSuperview()
        panel.host.removeFromParent()
        infoPanel = nil
        infoModel = nil
        panelTop = .greatestFiniteMagnitude
    }

    private func setInfoStop(_ stop: InfoPanelGeometry.Stop, animated: Bool, velocity: CGFloat = 0) {
        videoControlsSuppressed = stop != .hidden
        if stop != .hidden {
            ensureInfoPanel()
            currentPage?.zoomView.resetZoom(animated: false)
            if chromeHidden {
                chromeHidden = false
                backgroundView.backgroundColor = .systemBackground
            }
        }
        guard infoPanel != nil else { return }
        infoStop = stop
        let target = panelGeometry.top(for: stop)
        let changes = {
            self.panelTop = target
            self.applyPanelPosition()
            self.setNeedsStatusBarAppearanceUpdate()
        }
        let finish = {
            guard self.infoStop == stop else { return }
            self.infoPanel?.scrollView.isScrollEnabled = stop == .full
            if stop == .hidden { self.removeInfoPanel() }
            self.updateChrome()
        }
        if animated {
            let distance = max(abs(target - panelTop), 1)
            UIView.animate(springDuration: 0.45, bounce: 0, initialSpringVelocity: abs(velocity) / distance, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: changes) { _ in finish() }
        } else {
            changes()
            finish()
        }
        bottomBar.setInfoShown(stop != .hidden)
    }

    /// Positions the panel and moves the current photo up with it.
    private func applyPanelPosition() {
        guard let panel = infoPanel else { return }
        panel.frame.origin.y = panelTop
        currentPage?.zoomView.transform = CGAffineTransform(translationX: 0, y: panelGeometry.photoTranslation(panelTop: panelTop))
        setChromeAlpha(chromeHidden ? 0 : 1)
    }

    // MARK: Vertical drags

    @objc private func verticalDrag(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        switch gesture.state {
        case .began:
            if infoStop == .hidden && velocity.y > 0 {
                verticalMode = .dismiss
                videoControlsSuppressed = true
            } else {
                verticalMode = .panel
                videoControlsSuppressed = true
                ensureInfoPanel()
                currentPage?.zoomView.resetZoom(animated: false)
                panelStartTop = infoStop == .hidden ? view.bounds.height : panelTop
            }
        case .changed:
            switch verticalMode {
            case .dismiss:
                guard let page = currentPage else { return }
                let progress = min(max(translation.y / 400, 0), 1)
                let scale = 1 - progress * 0.35
                page.zoomView.transform = CGAffineTransform(translationX: translation.x, y: translation.y).scaledBy(x: scale, y: scale)
                backgroundView.alpha = 1 - progress
                setChromeAlpha(chromeHidden ? 0 : max(0, 1 - progress * 3))
            case .panel:
                let full = panelGeometry.top(for: .full)
                var top = panelStartTop + translation.y
                if top < full { top = full - (full - top) * 0.25 } // resist past fully open
                panelTop = min(top, view.bounds.height)
                applyPanelPosition()
            case nil:
                break
            }
        case .ended, .cancelled:
            defer { verticalMode = nil }
            switch verticalMode {
            case .dismiss:
                let shouldDismiss = gesture.state == .ended && (translation.y > 110 || velocity.y > 900)
                if shouldDismiss {
                    dismiss(animated: true)
                } else {
                    videoControlsSuppressed = false
                    UIView.animate(springDuration: 0.35, bounce: 0.1) {
                        self.currentPage?.zoomView.transform = .identity
                        self.backgroundView.alpha = 1
                        self.setChromeAlpha(self.chromeHidden ? 0 : 1)
                    }
                }
            case .panel:
                var stop = panelGeometry.stop(releasedAt: panelTop, velocity: gesture.state == .ended ? velocity.y : 0)
                // A swipe up from hidden opens to half first.
                if panelStartTop >= view.bounds.height - 1, stop == .full { stop = .half }
                setInfoStop(stop, animated: true, velocity: velocity.y)
            case nil:
                break
            }
        default:
            break
        }
    }
}

extension ViewerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === verticalPan else { return true }
        guard transitionState == .idle, presentedViewController == nil, let page = currentPage else { return false }
        let velocity = verticalPan.velocity(in: view)
        // Clearly vertical; horizontal swipes go to paging.
        guard abs(velocity.y) > abs(velocity.x) * 1.3 else { return false }
        switch infoStop {
        case .hidden:
            return !page.zoomView.isZoomed
        case .half:
            return true
        case .full:
            // Fully open: the panel scrolls; pulling down at its top closes it.
            let atTop = (infoPanel?.scrollView.contentOffset.y ?? 0) <= 0.5
            return velocity.y > 0 && atTop
        }
    }
}

// MARK: - Pages

extension ViewerViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ViewerPageCell.reuseIdentifier, for: indexPath) as! ViewerPageCell
        let item = items[indexPath.item]
        cell.horizontalInset = pageGap / 2
        cell.configure(item: item, details: session.detailsNow(for: item.id), placeholder: placeholder(item), media: media)
        cell.zoomView.transform = .identity
        cell.onPlayTapped = nil
        cell.onVideoChange = { [weak self, weak cell] in
            guard let self, let cell, cell === self.currentPage else { return }
            self.updateVideoControls()
        }
        cell.onSingleTap = { [weak self] in
            guard let self else { return }
            if self.isSlideshowRunning {
                self.stopSlideshow()
            } else if self.infoStop != .hidden {
                self.setInfoStop(.hidden, animated: true)
            } else {
                self.toggleChrome()
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let pipeline = session.pipeline
        for indexPath in indexPaths where items.indices.contains(indexPath.item) {
            let item = items[indexPath.item]
            Task { await pipeline.prefetch(assetID: item.id, size: .preview, revision: item.thumbhash) }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        pageAnimator.stop()
        dragStartIndex = currentIndex
    }

    /// One page per swipe. The scroll view's own deceleration carries the slide to
    /// the target page, so both photos stay on screen the whole way.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === collectionView, collectionView.bounds.width > 0, !items.isEmpty else { return }
        // Rotating: the page stays as it is.
        if (collectionView.collectionViewLayout as? PagerLayout)?.pinnedPage != nil { return }
        let width = collectionView.bounds.width
        var target: Int
        if velocity.x > 0.2 {
            target = dragStartIndex + 1
        } else if velocity.x < -0.2 {
            target = dragStartIndex - 1
        } else {
            target = Int((scrollView.contentOffset.x / width).rounded())
        }
        target = min(max(target, 0), items.count - 1)
        targetContentOffset.pointee = CGPoint(x: CGFloat(target) * width, y: 0)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // A release with no speed doesn't decelerate at all: animate onto the nearest page.
        if scrollView === collectionView, !decelerate { snapToNearestPage() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        snapToNearestPage()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        settleOnCurrentPage()
    }

    /// Never leaves two photos half on screen: if scrolling stopped between pages
    /// (released slowly, or a tap stopped the slide), animate to the nearest one.
    private func snapToNearestPage() {
        guard collectionView.bounds.width > 0, !items.isEmpty else { return }
        let width = collectionView.bounds.width
        let nearest = min(max(Int((collectionView.contentOffset.x / width).rounded()), 0), items.count - 1)
        let target = CGFloat(nearest) * width
        if abs(collectionView.contentOffset.x - target) > 0.5 {
            pageAnimator.animate(collectionView, to: CGPoint(x: target, y: 0), duration: snapDuration) { [weak self] in
                self?.settleOnCurrentPage()
            }
        } else {
            settleOnCurrentPage()
        }
    }

    /// Called shortly after the last scroll movement; catches the cases UIKit sends no
    /// callback for (a touch that stops a slide and lifts without dragging).
    @objc private func ensureOnPage() {
        guard !pageAnimator.isAnimating, !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        snapToNearestPage()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, collectionView.bounds.width > 0, !items.isEmpty else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(ensureOnPage), object: nil)
        perform(#selector(ensureOnPage), with: nil, afterDelay: 0.2)
        let index = Int((scrollView.contentOffset.x / collectionView.bounds.width).rounded())
        let clamped = min(max(index, 0), items.count - 1)
        if clamped != currentIndex {
            currentIndex = clamped
            updateChrome()
            filmstrip.setCurrent(clamped, animated: true)
        }
    }
}

private extension TimelineItem {
    func withFavorite(_ value: Bool) -> TimelineItem {
        var copy = self
        copy.isFavorite = value
        return copy
    }
}

/// The viewer's horizontal pager. While the size changes (rotation), the pinned page stays
/// in view at every step, so UIKit animates that cell instead of swapping cells.
final class PagerLayout: UICollectionViewFlowLayout {
    var pinnedPage: Int?

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let pinnedPage, let collectionView else { return super.targetContentOffset(forProposedContentOffset: proposedContentOffset) }
        return CGPoint(x: CGFloat(pinnedPage) * collectionView.bounds.width, y: 0)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView.map { $0.bounds.size != newBounds.size } ?? true
    }
}
