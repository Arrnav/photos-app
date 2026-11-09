import CloudCore
import MediaCache
import Persistence
import SwiftUI

/// The Library: grid (or Years / Months), the header over a dark band,
/// and, in select mode, the menus and sheets for the selection.
struct LibraryScreen: View {
    let model: AppModel
    let session: LibrarySession
    @Bindable var ui: LibraryUIState
    let bottomInset: CGFloat
    @AppStorage("library.columns") private var columns = 5
    @State private var filtered = FilteredTimeline()
    @State private var headerBottom: CGFloat = 120
    @State private var timeGroups = TimeGroupCache()

    var body: some View {
        let snapshot = filtered.snapshot(for: session.timeline, ui: ui, myUserID: session.account.userID)
        ZStack(alignment: .top) {
            content(snapshot)
            TopScrim(height: headerBottom + 44)
                .ignoresSafeArea(edges: .top)
            LibraryHeader(
                ui: ui,
                itemCount: snapshot.items.count,
                syncPaused: model.isSyncPaused,
                selectionMenu: { AnyView(SelectionMenu(model: model, session: session, ui: ui, items: snapshot.items)) }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY
            } action: { value in
                headerBottom = value
            }
            VStack {
                Spacer()
                StatusBanner(model: model, session: session)
                    .padding(.horizontal)
                    .padding(.bottom, bottomInset + 8)
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: TimelineSnapshot) -> some View {
        switch ui.timeScale {
        case .all:
            ZStack {
                PhotoGridView(
                    snapshot: snapshot, session: session, columns: $columns, ui: ui,
                    insets: UIEdgeInsets(top: headerBottom + 6, left: 0, bottom: bottomInset + 12, right: 0)
                )
                .ignoresSafeArea()
                .opacity(snapshot.items.isEmpty ? 0 : 1)
                if snapshot.isLoaded && snapshot.items.isEmpty {
                    if ui.isFiltered {
                        ContentUnavailableView("No Items", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Nothing matches the current filter."))
                    } else {
                        EmptyLibraryView(session: session, connection: model.connection)
                    }
                }
            }
        case .months, .years:
            TimeScaleView(
                scale: ui.timeScale,
                groups: timeGroups.groups(for: snapshot, scale: ui.timeScale),
                pipeline: session.pipeline,
                ui: ui,
                topInset: headerBottom + 6,
                bottomInset: bottomInset + 12
            )
            .ignoresSafeArea()
            .background(Color(.systemBackground))
        }
    }
}

/// Recomputes the filtered timeline only when the data or the filter changes.
@MainActor
final class FilteredTimeline {
    private struct Key: Equatable {
        let version: Int
        let sort: LibrarySort
        let filter: LibraryFilter
        let options: LibraryViewOptions
    }
    private var key: Key?
    private var cached = TimelineSnapshot()
    private var counter = 0

    func snapshot(for timeline: TimelineSnapshot, ui: LibraryUIState, myUserID: String) -> TimelineSnapshot {
        let key = Key(version: timeline.version, sort: ui.sort, filter: ui.filter, options: ui.options)
        if key == self.key { return cached }
        self.key = key
        counter += 1
        let unfiltered = ui.filter == .all && ui.sort == .captured && ui.options.showScreenshots && ui.options.showSharedWithYou
        let items = unfiltered ? timeline.items : ui.apply(to: timeline.items, myUserID: myUserID, albumAssetIDs: [])
        cached = TimelineSnapshot(items: items, version: counter, isLoaded: timeline.isLoaded)
        return cached
    }
}

/// Year and month groups, recomputed when the snapshot changes.
@MainActor
final class TimeGroupCache {
    private var version = -1
    private var scale = TimeScale.all
    private var cached: [TimeGroup] = []

    func groups(for snapshot: TimelineSnapshot, scale: TimeScale) -> [TimeGroup] {
        if snapshot.version != version || scale != self.scale {
            version = snapshot.version
            self.scale = scale
            cached = TimeGroup.make(snapshot.items, scale: scale)
        }
        return cached
    }
}

struct EmptyLibraryView: View {
    let session: LibrarySession
    let connection: ConnectionStatus

    var body: some View {
        switch session.syncStatus {
        case .syncing(let applied):
            ContentUnavailableView {
                Label("Loading Your Library", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text(applied > 0 ? "\(applied.formatted()) items received" : "Talking to the server…")
            }
        case .failed(let message, _):
            ContentUnavailableView {
                Label("Couldn’t Load Library", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.syncNow() }
            }
        default:
            if case .unreachable(let reasons) = connection {
                ContentUnavailableView("Server Not Reachable", systemImage: "wifi.exclamationmark", description: Text(reasons.joined(separator: "\n")))
            } else {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle", description: Text("Photos on your Cloud server appear here."))
            }
        }
    }
}

/// Small, dismissible status line over the grid: version warning or sync errors.
struct StatusBanner: View {
    let model: AppModel
    let session: LibrarySession
    @State private var dismissedWarning: String?

    var body: some View {
        if let warning = model.versionWarning, warning != dismissedWarning {
            banner(warning, systemImage: "exclamationmark.triangle.fill") { dismissedWarning = warning }
        } else if session.needsSignIn {
            banner("The server no longer accepts this sign-in. Open Settings to sign in again.", systemImage: "person.crop.circle.badge.exclamationmark", onClose: nil)
        } else if case .failed(let message, _) = session.syncStatus, !session.timeline.items.isEmpty {
            banner(message, systemImage: "exclamationmark.icloud") { session.syncNow() }
        }
    }

    private func banner(_ text: String, systemImage: String, onClose: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.yellow)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Bridges the UIKit grid into SwiftUI.
struct PhotoGridView: UIViewControllerRepresentable {
    let snapshot: TimelineSnapshot
    let session: LibrarySession
    var mode: ViewerViewController.Mode = .library
    /// Set when the grid is an album's (the viewer offers Remove from Album).
    var album: ViewerViewController.AlbumContext?
    @Binding var columns: Int
    var ui: LibraryUIState?
    var insets: UIEdgeInsets = .zero
    /// The Library's own grid: reports scrolling to the chrome and takes its commands
    /// (zoom, share, scroll). False for secondary grids such as Show Selected.
    var isPrimary = true
    /// Takes the screen's own commands (share the selection, zoom) without being the Library
    /// (Hidden, Recently Deleted). Defaults to `isPrimary`.
    var takesCommands: Bool?
    /// Text centred at the bottom of each tile (Recently Deleted's days left).
    var caption: ((TimelineItem) -> TileCaption?)?
    @AppStorage(PhotosSettings.showTileStatus) private var showsStatus = true

    func makeUIViewController(context: Context) -> PhotoGridViewController {
        let controller = PhotoGridViewController(pipeline: session.pipeline, columns: columns)
        controller.phoneImages = session.phoneImages
        controller.showsStatus = showsStatus && mode == .library
        controller.caption = caption
        controller.onColumnsChanged = { newValue in columns = newValue }
        let mode = mode
        let album = album
        controller.makeViewer = { [weak session] items, index, source, placeholder in
            guard let session else { return nil }
            let viewer = ViewerViewController(items: items, index: index, session: session, source: source, mode: mode, placeholder: placeholder)
            viewer.album = album
            return viewer
        }
        controller.makeShare = { [weak session, weak ui] items, index, selection, origin, placeholder in
            guard let session else { return nil }
            let screen = ShareScreenViewController(items: items, startIndex: index, selection: selection, session: session, origin: origin, placeholder: placeholder)
            screen.onClose = { _ in
                withAnimation(.snappy) { ui?.endSelecting() }
            }
            return screen
        }
        if let ui {
            if isPrimary {
                controller.onScrollInfo = { [weak ui] range, interacting, atBottom, userScrolled in
                    ui?.gridScrolled(range: range, interacting: interacting, atBottom: atBottom, userScrolled: userScrolled)
                }
            }
            controller.isSelected = { [weak ui] id in ui?.isSelected(id) ?? false }
            controller.onSelectionChange = { [weak ui] ids, selected in
                for id in ids { ui?.setSelected(id, selected) }
            }
        }
        controller.contentInsets = insets
        controller.apply(items: snapshot.items, version: snapshot.version)
        return controller
    }

    func updateUIViewController(_ controller: PhotoGridViewController, context: Context) {
        controller.apply(items: snapshot.items, version: snapshot.version)
        controller.contentInsets = insets
        controller.showsStatus = showsStatus && mode == .library
        if let caption { controller.caption = caption }
        guard let ui else { return }
        controller.aspectRatioGrid = ui.options.aspectRatioGrid
        controller.isSelecting = ui.isSelecting
        _ = ui.selection.count // re-run when the selection changes elsewhere (Deselect All)
        controller.refreshSelection()
        guard takesCommands ?? isPrimary else { return }
        if let command = ui.zoomCommand {
            DispatchQueue.main.async {
                controller.stepZoom(in: command == .zoomIn)
                ui.zoomCommand = nil
            }
        }
        if ui.shareRequested {
            let selection = ui.selection
            DispatchQueue.main.async {
                ui.shareRequested = false
                controller.presentShare(selection: selection)
            }
        }
        if let target = ui.scrollTarget {
            DispatchQueue.main.async {
                controller.scroll(to: target)
                ui.scrollTarget = nil
            }
        }
    }
}
