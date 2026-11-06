import Core
import CloudCore
import MediaCache
import Persistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share screen: a card with the selection header (thumbnail, "1 Photo
/// Selected", Location Included, Options, ✕), a carousel of photos (swipe, tap to
/// select several), and the system share options underneath.
///
/// Opening animates in one go (~0.7 s): the photo shrinks from where it was into the
/// carousel, its neighbours slide in from the sides, and the share options rise from
/// the bottom. The share options are the system share sheet (people, apps, actions,
/// Edit Actions); they can't be embedded or restyled, only placed (PLAN.md M2b).
final class ShareScreenViewController: UIViewController {
    private let items: [TimelineItem]
    private let startIndex: Int
    private let session: LibrarySession
    private let placeholder: (TimelineItem) -> UIImage?
    /// Where the photo starts (window coordinates) and its image, for the opening animation.
    private let origin: (frame: CGRect, image: UIImage?)?
    private var selection: [String]

    private let dimView = UIView()
    private let card = UIView()
    private let header = ShareHeaderView()
    /// Frosted band behind the header; the photos slide under it when the options are pulled up.
    private let headerBand = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let layout = ShareCarouselLayout()
    private lazy var carousel = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let shareItems: ShareItems
    /// The bottom area the system share options are shown in (see `ShareOptionsArea`).
    private let optionsArea = ShareOptionsArea()
    private var optionsHost: ShareOptionsHost?
    private var prepareTask: Task<Void, Never>?
    /// "Preparing…" progress while the files are fetched; nil when ready.
    private var preparingProgress: Double?
    private var currentIndex: Int
    private var didAnimateIn = false
    private var isClosing = false

    /// Height of the system share options at the bottom, home indicator included (the reference
    /// puts them right under the carousel).
    private var optionsHeight: CGFloat { (view.bounds.height * 0.415).rounded() }
    /// Pulled up, the share options reach up to the (compact) header and hide the photos,
    /// (screenshots 16–17); pulled back down, the photos return.
    private var optionsExpanded = false
    /// How far the options are being dragged from where they rest (negative is up).
    private var optionsDrag: CGFloat = 0
    private var collapsedOptionsTop: CGFloat { view.bounds.height - optionsHeight }
    /// Where the photos rest; pulled up, the options reach here (screenshots 2–3).
    private var expandedOptionsTop: CGFloat { card.frame.minY + header.frame.maxY + 18 }

    /// Called after closing, with the item showing in the carousel.
    var onClose: ((TimelineItem?) -> Void)?

    init(
        items: [TimelineItem],
        startIndex: Int,
        selection: [String],
        session: LibrarySession,
        origin: (frame: CGRect, image: UIImage?)?,
        placeholder: @escaping (TimelineItem) -> UIImage?
    ) {
        self.items = items
        self.startIndex = min(max(startIndex, 0), max(items.count - 1, 0))
        currentIndex = self.startIndex
        self.selection = selection
        self.session = session
        self.origin = origin
        self.placeholder = placeholder
        shareItems = ShareItems(fileSource: session.shareFileSource)
        super.init(nibName: nil, bundle: nil)
        shareItems.onItemFailure = { [weak self] message in
            Task { @MainActor in self?.showMessage(message) }
        }
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    override func loadView() {
        let root = ShareRootView()
        // iOS puts the share options in a container as big as this screen; taps that land on
        // its empty part go to the photos underneath instead of being swallowed.
        root.passthrough = { [weak self] point, event in
            guard let self, let container = self.optionsHost?.presentationController?.containerView else { return nil }
            return (container, self.card.hitTest(self.card.convert(point, from: self.view), with: event) ?? self.dimView)
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 38
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        view.addSubview(card)

        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)
        header.closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        header.optionsButton.addTarget(self, action: #selector(showOptions), for: .touchUpInside)

        carousel.backgroundColor = .clear
        carousel.showsHorizontalScrollIndicator = false
        carousel.decelerationRate = .fast
        carousel.register(ShareCarouselCell.self, forCellWithReuseIdentifier: ShareCarouselCell.reuseIdentifier)
        carousel.dataSource = self
        carousel.delegate = self
        carousel.contentInsetAdjustmentBehavior = .never
        card.addSubview(carousel)
        headerBand.alpha = 0
        headerBand.isUserInteractionEnabled = false
        card.insertSubview(headerBand, aboveSubview: carousel)
        card.bringSubviewToFront(header)
        layout.aspectRatios = items.map(\.aspectRatio)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        addChild(optionsArea)
        view.addSubview(optionsArea.view)
        optionsArea.didMove(toParent: self)
        addOptionsDrag(to: header)
        addOptionsDrag(to: carousel)
        syncSelection()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 8
        card.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
        card.layoutIfNeeded()
        let carouselTop = header.frame.maxY + 18
        layoutOptions()
        // The photos end above the share options (at rest); nothing covers them.
        let carouselBottom = collapsedOptionsTop - card.frame.minY - 6
        headerBand.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: carouselTop)
        let frame = CGRect(x: 0, y: carouselTop, width: card.bounds.width, height: max(carouselBottom - carouselTop, 120))
        if carousel.bounds.size != frame.size || carousel.center != CGPoint(x: frame.midX, y: frame.midY) {
            carousel.bounds = CGRect(origin: carousel.bounds.origin, size: frame.size)
            carousel.center = CGPoint(x: frame.midX, y: frame.midY)
            layout.invalidateLayout()
            carousel.layoutIfNeeded()
            scrollCarousel(to: currentIndex, animated: false)
        }
    }

    private var wentToBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Coming back from another app (an action that opened it): the share options are rebuilt
    /// so they're never left greyed out and untouchable.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground = true }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wentToBackground else { return }
                self.wentToBackground = false
                self.resetShareOptions(reason: "back from another app")
            }
        })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
    }

    /// Replaces the share options with fresh ones, in place (no animation), unless a
    /// destination is still open over them. Logs what was on screen, for diagnosis.
    private func resetShareOptions(reason: String) {
        guard !isClosing, view.window != nil else { return }
        ShareLog.write("reset options (\(reason)); on screen: \(screenSummary())")
        if let host = optionsHost {
            guard host.activity.presentedViewController == nil else {
                ShareLog.write("kept: \(type(of: host.activity.presentedViewController!)) still open")
                return
            }
            optionsHost = nil
            host.dismiss(animated: false) { [weak self] in self?.presentShareOptions(animated: false) }
        } else if optionsArea.presentedViewController == nil {
            presentShareOptions(animated: false)
        }
    }

    /// The presented screens above this one and the window's top views, in one line.
    private func screenSummary() -> String {
        var chain: [String] = []
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            chain.append("\(type(of: presented))\(presented.isBeingDismissed ? "(dismissing)" : "")")
            top = presented
        }
        let windowViews = view.window?.subviews.map { "\(type(of: $0)) a\(String(format: "%.1f", $0.alpha))" } ?? []
        let hostState = optionsHost.map { "host in window \($0.view.window != nil) frame \($0.view.frame.integral) activity view \($0.activity.view.frame.integral)" } ?? "no host"
        return "presented [\(chain.joined(separator: " > "))] window [\(windowViews.joined(separator: ", "))] \(hostState)"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        if ScreenCapture.isEnabled { runSelfTest() }
        observeAppLifecycle()
        prepareFiles()
        animateIn()
        presentShareOptions()
    }

    /// `-ShareScreenSelfTest`: records opening, resting and closing as frames, and logs the layout.
    private func runSelfTest() {
        let window = view.window
        ScreenCapture.log("share screen appeared")
        ScreenCapture.record("1open", in: window, count: 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            ScreenCapture.record("2rest", in: window, count: 1)
            ScreenCapture.log("carousel \(self.carousel.convert(self.carousel.bounds, to: nil).integral) card \(self.card.frame.integral) options \(self.optionsArea.view.frame.integral) host \(self.optionsHost.map { String(describing: $0.view.convert($0.view.bounds, to: nil).integral) } ?? "none")")
            if let window {
                // What a tap would reach: a photo in the carousel, and the share options.
                for point in [CGPoint(x: window.bounds.midX, y: self.carousel.convert(self.carousel.bounds, to: nil).midY),
                              CGPoint(x: window.bounds.midX, y: self.optionsArea.view.frame.midY)] {
                    var chain: [String] = []
                    var hit = window.hitTest(point, with: nil)
                    while let current = hit, chain.count < 6 { chain.append("\(type(of: current))"); hit = current.superview }
                    ScreenCapture.log("tap at \(point): " + chain.joined(separator: " < "))
                }
                ScreenCapture.dump(window, maxDepth: 7)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            ScreenCapture.record("3expand", in: window, count: 15)
            self.setOptionsExpanded(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            ScreenCapture.log("expanded: options \(self.optionsArea.view.frame.integral) host \(self.optionsHost.map { String(describing: $0.view.convert($0.view.bounds, to: nil).integral) } ?? "none") carousel \(self.carousel.convert(self.carousel.bounds, to: nil).integral) band \(self.headerBand.alpha)")
            ScreenCapture.record("4collapse", in: window, count: 15)
            self.setOptionsExpanded(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            ScreenCapture.log("collapsed: options \(self.optionsArea.view.frame.integral) carousel alpha \(self.carousel.alpha)")
            ScreenCapture.record("5close", in: window, count: 24)
            self.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            ScreenCapture.record("6after", in: window, count: 1)
            ScreenCapture.log("done")
        }
    }

    // MARK: Opening and closing

    /// Shrinks the photo into the carousel while the neighbours slide in and the share
    /// options rise, all together (~0.7 s).
    private func animateIn() {
        view.layoutIfNeeded()
        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.3 : 0.7
        let width = view.bounds.width

        // Start state.
        dimView.alpha = 0
        card.backgroundColor = card.backgroundColor?.withAlphaComponent(1)
        card.transform = CGAffineTransform(translationX: 0, y: 60)
        card.alpha = 0
        let center = carousel.cellForItem(at: IndexPath(item: currentIndex, section: 0))
        var flying: UIImageView?
        if let origin, let center {
            let image = UIImageView(image: origin.image ?? placeholder(items[currentIndex]))
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.layer.cornerCurve = .continuous
            image.frame = view.convert(origin.frame, from: nil)
            view.addSubview(image)
            flying = image
            center.alpha = 0
        }
        for cell in carousel.visibleCells {
            guard let path = carousel.indexPath(for: cell), path.item != currentIndex else { continue }
            cell.transform = CGAffineTransform(translationX: path.item < currentIndex ? -width : width, y: 0)
        }

        UIView.animate(springDuration: duration, bounce: 0) {
            self.dimView.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
            for cell in self.carousel.visibleCells where cell !== center {
                cell.transform = .identity
            }
            if let flying, let center {
                flying.frame = center.convert(center.bounds, to: self.view)
                flying.layer.cornerRadius = ShareCarouselCell.cornerRadius
            }
        } completion: { _ in
            center?.alpha = 1
            flying?.removeFromSuperview()
        }
    }

    /// The system share options (people, apps, actions), shown in our bottom area and slid
    /// up from the bottom edge with the card. (Presented as iOS's own sheet,
    /// they pop out of the centre and take half the screen whatever height is asked for.)
    private func presentShareOptions(animated: Bool = true) {
        // The card's own colour: presented views are "elevated" and would draw a lighter grey.
        let host = ShareOptionsHost(activity: makeActivity(), background: card.backgroundColor?.resolvedColor(with: traitCollection) ?? .secondarySystemBackground)
        host.onDismiss = { [weak self, weak host] in
            if let self, self.optionsHost === host { self.optionsHost = nil }
        }
        host.setPreparing(preparingProgress)
        optionsHost = host
        optionsArea.present(host, animated: false)
        layoutOptions()
        addOptionsDrag(to: host.dragHandle)
        guard animated else { return }
        host.view.transform = CGAffineTransform(translationX: 0, y: optionsHeight)
        UIView.animate(springDuration: UIAccessibility.isReduceMotionEnabled ? 0.3 : 0.6, bounce: 0) {
            host.view.transform = .identity
        }
    }

    /// Places the share options: at rest, pulled up, or following a drag. They're always as
    /// tall as when pulled up (the rest is below the screen), so dragging only moves them
    /// and the system share UI doesn't have to redraw at every step.
    private func layoutOptions() {
        let resting = optionsExpanded ? expandedOptionsTop : collapsedOptionsTop
        var top = resting + optionsDrag
        if top < expandedOptionsTop {
            // Resists being pulled past the top.
            let over = expandedOptionsTop - top
            top = expandedOptionsTop - over / (1 + over / 60)
        }
        let height = view.bounds.height - expandedOptionsTop
        let frame = CGRect(x: 0, y: top, width: view.bounds.width, height: height)
        optionsArea.view.frame = frame
        if let hostView = optionsHost?.view, let container = hostView.superview {
            // Bounds and centre, so the slide-in transform is left alone.
            hostView.bounds = CGRect(origin: .zero, size: frame.size)
            hostView.center = container.convert(CGPoint(x: frame.midX, y: frame.midY), from: view)
        }
        // The photos and the options move as one page; the photos slide under the frosted header.
        carousel.transform = CGAffineTransform(translationX: 0, y: min(top - collapsedOptionsTop, 0))
        let progress = (collapsedOptionsTop - top) / max(collapsedOptionsTop - expandedOptionsTop, 1)
        headerBand.alpha = min(max(progress * 2, 0), 1)
    }

    @objc private func dragOptions(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).y
        switch pan.state {
        case .began, .changed:
            optionsDrag = translation
            layoutOptions()
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: view).y
            let resting = optionsExpanded ? expandedOptionsTop : collapsedOptionsTop
            let projected = resting + translation + velocity * 0.2
            if !optionsExpanded, translation > 0, projected > collapsedOptionsTop + optionsHeight * 0.35 {
                // Pulled down from rest: close, like the sheet's swipe down.
                close()
                return
            }
            setOptionsExpanded(projected < (collapsedOptionsTop + expandedOptionsTop) / 2, velocity: velocity)
        default:
            break
        }
    }

    private func setOptionsExpanded(_ expanded: Bool, velocity: CGFloat = 0) {
        let start = optionsArea.view.frame.minY
        optionsExpanded = expanded
        optionsDrag = 0
        let distance = (expanded ? expandedOptionsTop : collapsedOptionsTop) - start
        let springVelocity = abs(distance) > 1 ? velocity / distance : 0
        UIView.animate(springDuration: 0.45, bounce: 0, initialSpringVelocity: springVelocity, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.layoutOptions()
        }
    }

    /// Lets the options be dragged (vertical drags only) from their grabber strip, the header
    /// or the photos. The system share UI can't be used for this: its touches go to its own
    /// process, and iOS 27 only shows it as a floating popover, never as a draggable sheet.
    private func addOptionsDrag(to view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragOptions(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        // Sideways swipes through the photos start once a vertical drag is ruled out.
        if let scrollView = view as? UIScrollView { scrollView.panGestureRecognizer.require(toFail: pan) }
    }

    private func makeActivity() -> UIActivityViewController {
        let activity = UIActivityViewController(activityItems: shareItems.activityItems(), applicationActivities: customActivities())
        activity.completionWithItemsHandler = { [weak self, weak activity] type, completed, returned, error in
            ShareLog.write("finished: \(type?.rawValue ?? "none") completed \(completed) returned \(returned?.count ?? 0) error \(error.map { "\($0)" } ?? "none") current \(self?.optionsHost?.activity === activity)")
            guard let self, let activity, self.optionsHost?.activity === activity else { return }
            if completed {
                SearchHistory.recordShared(self.selection)
                self.close()
            } else if type == nil {
                // Its own close button.
                self.close()
            } else if !(type?.rawValue.hasPrefix("com.ethwood.photos.") ?? false) {
                // Back from an action that didn't finish (Quick Note, an app's extension):
                // the system share UI can be left greyed out, so it's replaced with a fresh one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.resetShareOptions(reason: "action \(type?.rawValue ?? "?") ended") }
            }
        }
        return activity
    }

    private var refreshTask: Task<Void, Never>?

    /// The share options take their items when they open, so after the selection changes
    /// they're replaced in place (the new ones load under the old, so nothing flashes).
    private func refreshShareOptionsSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, !self.isClosing else { return }
            if let host = self.optionsHost {
                // Never while a destination (WhatsApp, Mail…) is open from the current options.
                guard host.presentedViewController == nil, host.activity.presentedViewController == nil else { return }
                host.replace(with: self.makeActivity())
            } else {
                self.presentShareOptions()
            }
        }
    }

    /// Fetches the selected files before they can be shared, with "Preparing…" on the share
    /// options if it takes a moment (Cloud originals).
    private func prepareFiles() {
        prepareTask?.cancel()
        let shareItems = shareItems
        prepareTask = Task { @MainActor [weak self] in
            // Held while preparing; closing cancels this.
            guard let screen = self else { return }
            let reveal = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                screen.preparingProgress = screen.preparingProgress ?? 0
                screen.optionsHost?.setPreparing(screen.preparingProgress)
            }
            let error = await shareItems.prepareAll { value in
                Task { @MainActor in
                    guard screen.preparingProgress != nil else { return }
                    screen.preparingProgress = value
                    screen.optionsHost?.setPreparing(value)
                }
            }
            reveal.cancel()
            guard !Task.isCancelled else { return }
            screen.preparingProgress = nil
            screen.optionsHost?.setPreparing(nil)
            if let error, !(error is CancellationError) {
                screen.showMessage((error as? CloudError)?.message ?? (error as? MediaError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// The share options slide down while the card fades away, together (~0.3 s).
    @objc private func close() {
        guard !isClosing else { return }
        isClosing = true
        ShareLog.write("share screen closed")
        refreshTask?.cancel()
        prepareTask?.cancel()
        shareItems.cancel()
        let item = items.indices.contains(currentIndex) ? items[currentIndex] : nil
        let host = optionsHost
        UIView.animate(springDuration: 0.32, bounce: 0) {
            self.dimView.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(translationX: 0, y: 60)
            host?.view.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height - self.optionsArea.view.frame.minY)
        } completion: { _ in
            // Dismisses this screen and anything still above it (the options, a picker).
            guard let presenter = self.presentingViewController else {
                self.onClose?(item)
                return
            }
            presenter.dismiss(animated: false) { self.onClose?(item) }
        }
    }

    // MARK: Selection

    private func toggle(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let id = items[index].id
        if let position = selection.firstIndex(of: id) {
            selection.remove(at: position)
        } else {
            selection.append(id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        syncSelection()
        prepareFiles()
        refreshShareOptionsSoon()
        for case let cell as ShareCarouselCell in carousel.visibleCells {
            guard let path = carousel.indexPath(for: cell) else { continue }
            cell.setSelected(selection.contains(items[path.item].id))
        }
    }

    /// Keeps the share items and the header in step with the selection.
    private func syncSelection() {
        let selected = selection.compactMap { id in items.first { $0.id == id } }
        shareItems.entries = selected.map { item in
            ShareItems.Entry(
                assetID: item.id,
                fileName: session.detailsNow(for: item.id)?.asset.originalFileName ?? "\(item.id).jpg",
                isVideo: item.isVideo,
                localID: item.localID,
                thumbnail: placeholder(item)
            )
        }
        let hasLocation = selected.contains { session.detailsNow(for: $0.id)?.exif?.latitude != nil }
        let videos = selected.filter(\.isVideo).count
        header.update(
            photos: selected.count - videos, videos: videos,
            includesLocation: shareItems.options.includeLocation, hasLocation: hasLocation,
            thumbnail: (selected.last ?? items[safe: currentIndex]).flatMap(placeholder)
        )
    }

    @objc private func showOptions() {
        let options = UIHostingController(rootView: ShareOptionsView(options: shareItems.options) { [weak self] new in
            guard let self else { return }
            self.shareItems.options = new
            self.syncSelection()
            self.prepareFiles()
            self.refreshShareOptionsSoon()
        })
        options.sheetPresentationController?.detents = [.medium(), .large()]
        topPresenter.present(options, animated: true)
    }

    // MARK: Extra actions in the share options

    private func customActivities() -> [UIActivity] {
        let selectedIDs: () -> [String] = { [weak self] in self?.selection ?? [] }
        return [
            ClosureActivity(type: "add-to-shared-album", title: String(localized: "Add to Shared Album"), symbol: "rectangle.stack.badge.person.crop") { [weak self] in
                self?.presentSheet { session, done in AlbumPickerView(session: session, shared: true, assetIDs: selectedIDs(), onDone: done) }
            },
            ClosureActivity(type: "add-to-album", title: String(localized: "Add to Album"), symbol: "rectangle.stack.badge.plus") { [weak self] in
                self?.presentSheet { session, done in AlbumPickerView(session: session, shared: false, assetIDs: selectedIDs(), onDone: done) }
            },
            ClosureActivity(type: "shared-link", title: String(localized: "Create Shared Album Link"), symbol: "link.icloud") { [weak self] in
                self?.createSharedLink()
            },
            ClosureActivity(type: "export-originals", title: String(localized: "Export Unmodified Originals"), symbol: "folder") { [weak self] in
                self?.exportOriginals()
            },
        ]
    }

    /// Sheets started from the share options close the share screen when they finish
    /// (or are swiped away).
    private func presentSheet<Content: View>(_ make: (LibrarySession, @escaping (String) -> Void) -> Content) {
        let sheet = UIHostingController(rootView: make(session) { [weak self] _ in
            self?.close()
        })
        sheet.presentationController?.delegate = self
        topPresenter.present(sheet, animated: true)
    }

    private var topPresenter: UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// Immich shared link for the selection; the link is copied and offered to share.
    private func createSharedLink() {
        let ids = selection
        Task {
            do {
                let url = try await session.createSharedLink(assetIDs: ids)
                UIPasteboard.general.url = url
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.completionWithItemsHandler = { [weak self] _, _, _, _ in self?.close() }
                topPresenter.present(share, animated: true)
            } catch {
                showMessage((error as? CloudError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Saves the original files, untouched, to Files.
    private func exportOriginals() {
        let selected = selection.compactMap { id in items.first { $0.id == id } }
        Task {
            do {
                var urls: [URL] = []
                for item in selected {
                    let name = session.detailsNow(for: item.id)?.asset.originalFileName ?? "\(item.id).jpg"
                    urls.append(try await session.originals.file(assetID: item.id, fileName: name))
                }
                let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                picker.delegate = self
                topPresenter.present(picker, animated: true)
            } catch {
                showMessage((error as? CloudError)?.message ?? (error as? MediaError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        topPresenter.present(alert, animated: true)
    }

    // MARK: Carousel paging

    private func scrollCarousel(to index: Int, animated: Bool) {
        guard items.indices.contains(index), carousel.bounds.width > 0 else { return }
        let x = layout.frame(of: index).midX - carousel.bounds.width / 2
        carousel.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }
}

extension ShareScreenViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, !isClosing else { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return true
    }
}

extension ShareScreenViewController: UIAdaptivePresentationControllerDelegate, UIDocumentPickerDelegate {
    /// The share options (or a sheet started from them) were swiped away: close the whole screen.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        close()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        close()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        close()
    }
}

extension ShareScreenViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShareCarouselCell.reuseIdentifier, for: indexPath) as! ShareCarouselCell
        let item = items[indexPath.item]
        cell.configure(item: item, placeholder: placeholder(item), pipeline: session.pipeline, selected: selection.contains(item.id))
        cell.onToggle = { [weak self] in self?.toggle(indexPath.item) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item == currentIndex {
            toggle(indexPath.item)
        } else {
            currentIndex = indexPath.item
            scrollCarousel(to: indexPath.item, animated: true)
        }
    }

    /// One card per swipe, snapping to the card's centre.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let center = scrollView.contentOffset.x + scrollView.bounds.width / 2
        var index = layout.index(nearestX: center)
        if velocity.x > 0.2 { index = min(max(index, currentIndex + 1), items.count - 1) }
        if velocity.x < -0.2 { index = max(min(index, currentIndex - 1), 0) }
        currentIndex = index
        targetContentOffset.pointee = CGPoint(x: layout.frame(of: index).midX - scrollView.bounds.width / 2, y: 0)
    }
}

/// Carousel cards: one height, width by aspect ratio (clamped), centred with gaps.
final class ShareCarouselLayout: UICollectionViewLayout {
    var aspectRatios: [Double] = []
    let spacing: CGFloat = 10
    /// The least space kept between the photo and each side of the screen.
    let sideMargin: CGFloat = 36

    private var height: CGFloat { collectionView?.bounds.height ?? 300 }
    private var offsets: [CGFloat] = []
    private var widths: [CGFloat] = []

    override func prepare() {
        super.prepare()
        let h = height
        // Wide photos are cropped (aspect fill) to keep a margin from the screen's sides, in
        // either orientation; tall ones are capped too.
        let maxWidth = max((collectionView?.bounds.width ?? 0) - 2 * sideMargin, h * 0.56)
        widths = aspectRatios.map { min(CGFloat(max($0, 0.56)) * h, maxWidth) }
        offsets = []
        offsets.reserveCapacity(widths.count)
        var x = (collectionView?.bounds.width ?? 0) / 2 - (widths.first ?? 0) / 2
        for width in widths {
            offsets.append(x)
            x += width + spacing
        }
    }

    func frame(of index: Int) -> CGRect {
        guard offsets.indices.contains(index) else { return .zero }
        return CGRect(x: offsets[index], y: 0, width: widths[index], height: height)
    }

    func index(nearestX x: CGFloat) -> Int {
        guard !offsets.isEmpty else { return 0 }
        var low = 0, high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= x { low = mid } else { high = mid - 1 }
        }
        let candidates = [low - 1, low, low + 1].filter { offsets.indices.contains($0) }
        return candidates.min { abs(frame(of: $0).midX - x) < abs(frame(of: $1).midX - x) } ?? 0
    }

    override var collectionViewContentSize: CGSize {
        guard let last = offsets.indices.last else { return .zero }
        let width = (collectionView?.bounds.width ?? 0)
        return CGSize(width: frame(of: last).maxX + width / 2 - widths[last] / 2, height: height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !offsets.isEmpty else { return [] }
        let first = max(0, index(nearestX: rect.minX) - 1)
        let last = min(offsets.count - 1, index(nearestX: rect.maxX) + 1)
        return (first...last).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard offsets.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame(of: indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != (collectionView?.bounds.size ?? .zero)
    }
}

/// A rounded photo card with the selection circle in its corner.
final class ShareCarouselCell: UICollectionViewCell {
    static let reuseIdentifier = "ShareCarouselCell"
    static let cornerRadius: CGFloat = 22

    private let imageView = UIImageView()
    private let circle = UIButton(type: .custom)
    private var task: Task<Void, Never>?
    private var id: String?
    var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = Self.cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = .systemGray5
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        circle.layer.shadowColor = UIColor.black.cgColor
        circle.layer.shadowOpacity = 0.3
        circle.layer.shadowRadius = 3
        circle.layer.shadowOffset = .zero
        circle.addTarget(self, action: #selector(toggled), for: .touchUpInside)
        contentView.addSubview(circle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGFloat = 44
        circle.frame = CGRect(x: contentView.bounds.maxX - size - 2, y: contentView.bounds.maxY - size - 2, width: size, height: size)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        id = nil
        imageView.image = nil
        transform = .identity
        alpha = 1
    }

    func configure(item: TimelineItem, placeholder: UIImage?, pipeline: RemoteImagePipeline, selected: Bool) {
        id = item.id
        setSelected(selected)
        isAccessibilityElement = true
        accessibilityLabel = Formatting.accessibilityLabel(for: item)
        let pixels = 1000
        if let cached = pipeline.cachedImage(assetID: item.id, size: .preview, maxPixelSize: pixels) {
            imageView.image = UIImage(cgImage: cached)
            return
        }
        imageView.image = placeholder
        let id = item.id
        task = Task { [weak self] in
            guard let image = try? await pipeline.image(assetID: id, size: .preview, maxPixelSize: pixels, revision: item.thumbhash),
                  let self, self.id == id
            else { return }
            UIView.transition(with: self.imageView, duration: 0.15, options: .transitionCrossDissolve) {
                self.imageView.image = UIImage(cgImage: image)
            }
        }
    }

    func setSelected(_ selected: Bool) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        let image = selected
            ? UIImage(systemName: "checkmark.circle.fill", withConfiguration: configuration)?.applyingSymbolConfiguration(.init(paletteColors: [.white, .systemBlue]))
            : UIImage(systemName: "circle", withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal)
        circle.setImage(image, for: .normal)
        accessibilityTraits = selected ? [.image, .button, .selected] : [.image, .button]
    }

    @objc private func toggled() {
        onToggle?()
    }
}

/// A share-sheet action that runs a closure (Add to Album, Export Unmodified Originals, ...).
private final class ShareRootView: UIView {
    /// The share options' container, and what should get taps that land on its empty part.
    var passthrough: ((CGPoint, UIEvent?) -> (container: UIView, target: UIView)?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let hit, let route = passthrough?(point, event), hit === route.container {
            return route.target
        }
        return hit
    }
}

/// The bottom area of the share screen. The share options are presented over it, and only
/// over it, so the photos above stay visible and tappable, and the panel's place, size and
/// slide are ours rather than iOS's sheet's.
private final class ShareOptionsArea: UIViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        definesPresentationContext = true
    }
}

/// Hosts the system share options as a child, with "Preparing…" over them while the files
/// are fetched. When the share options close themselves, this closes with them.
private final class ShareOptionsHost: UIViewController {
    private(set) var activity: UIActivityViewController
    private let background: UIColor
    var onDismiss: (() -> Void)?
    /// A strip of our own above the system share UI, with a grabber. Touches on the system
    /// UI go straight to its own process, so the options can only be dragged from here (and
    /// from the header above).
    let dragHandle = UIView()
    static let handleHeight: CGFloat = 26
    private let cover = UIView()
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)

    init(activity: UIActivityViewController, background: UIColor) {
        self.activity = activity
        self.background = background
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        dragHandle.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: Self.handleHeight)
        dragHandle.autoresizingMask = [.flexibleWidth]
        let grabber = UIView(frame: CGRect(x: 0, y: 8, width: 36, height: 5))
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.center.x = dragHandle.bounds.midX
        grabber.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        dragHandle.addSubview(grabber)
        view.addSubview(dragHandle)
        embed(activity, below: nil)

        cover.backgroundColor = background.withAlphaComponent(0.88)
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.alpha = 0
        cover.isUserInteractionEnabled = true
        label.text = String(localized: "Preparing…")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        bar.trackTintColor = .tertiarySystemFill
        for subview in [label, bar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cover.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            label.topAnchor.constraint(equalTo: cover.topAnchor, constant: 44),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            bar.widthAnchor.constraint(equalToConstant: 180),
        ])
        view.addSubview(cover)
    }

    private func embed(_ child: UIActivityViewController, below other: UIView?) {
        addChild(child)
        child.view.frame = view.bounds.inset(by: UIEdgeInsets(top: Self.handleHeight, left: 0, bottom: 0, right: 0))
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let other { view.insertSubview(child.view, belowSubview: other) } else { view.addSubview(child.view) }
        child.didMove(toParent: self)
    }

    /// New share options (after the selection changed). They load under the current ones,
    /// which go once the new ones have had time to draw.
    func replace(with new: UIActivityViewController) {
        let old = activity
        ShareLog.write("options replaced (selection changed)\(old.presentedViewController != nil ? " while showing \(type(of: old.presentedViewController!))" : "")")
        activity = new
        embed(new, below: old.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Kept while it still shows a destination it opened.
            guard old.presentedViewController == nil else { return }
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
    }

    /// Shows "Preparing…" with progress (0…1), or hides it (nil).
    func setPreparing(_ progress: Double?) {
        loadViewIfNeeded()
        view.bringSubviewToFront(cover)
        if let progress { bar.setProgress(Float(progress), animated: cover.alpha > 0) }
        let alpha: CGFloat = progress == nil ? 0 : 1
        guard cover.alpha != alpha else { return }
        UIView.animate(withDuration: 0.2) { self.cover.alpha = alpha }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            ShareLog.write("options dismissed themselves")
            onDismiss?()
        }
    }
}

final class ClosureActivity: UIActivity {
    private let type: String
    private let title: String
    private let symbol: String
    private let action: @MainActor @Sendable () -> Void

    init(type: String, title: String, symbol: String, action: @escaping @MainActor @Sendable () -> Void) {
        self.type = type
        self.title = title
        self.symbol = symbol
        self.action = action
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("com.ethwood.photos.\(type)") }
    override var activityTitle: String? { title }
    override var activityImage: UIImage? { UIImage(systemName: symbol) }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        activityDidFinish(false)
        // After the share options step aside, so the next sheet can present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [action] in action() }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
