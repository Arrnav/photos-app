import Foundation
import Observation
import Persistence

/// The Library filter menu.
enum LibrarySort: String, CaseIterable, Sendable {
    /// Upload order (Immich "created at").
    case added
    /// Capture date (default).
    case captured
}

enum LibraryFilter: String, CaseIterable, Sendable {
    case all, favourites, edited, sharedWithYou, capturedByMe, notInAlbum
    case photos, videos, screenshots
}

struct LibraryViewOptions: Equatable, Sendable {
    var aspectRatioGrid = false
    var showScreenshots = true
    var showSharedWithYou = true
}

enum TimeScale: String, CaseIterable, Sendable {
    case years, months, all
}

/// Bottom bar: Library | Collections (+ Search), or after scrolling, the time scale.
enum BarMode: Sendable {
    case tabs
    case timeScale
}

enum AppSection: Sendable {
    case library
    case collections
}

/// State shared by the Library's SwiftUI chrome (header, bottom bar, menus) and the
/// UIKit grid. The grid reports scrolling; the chrome reflects it.
@MainActor
@Observable
final class LibraryUIState {
    var section = AppSection.library
    var barMode = BarMode.tabs
    var timeScale = TimeScale.all
    var sort = LibrarySort.captured
    var filter = LibraryFilter.all
    var options = LibraryViewOptions()
    var showsSearch = false
    /// A screen with its own select footer (Recently Deleted) hides the floating bar.
    var hidesFloatingBar = false
    var pendingSheet: SelectionSheet?
    /// Set by the footer's Share button; the grid opens the share screen and clears it.
    var shareRequested = false
    var pendingConfirmation: SelectionConfirmation?
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // Selection mode
    var isSelecting = false
    private(set) var selection: [String] = []
    private(set) var selectionSet: Set<String> = []

    // Reported by the grid.
    private(set) var visibleRange: ClosedRange<Date>?
    private(set) var isInteracting = false
    private(set) var isAtBottom = true
    /// After 5 s without touching the grid (and at launch) the subtitle may show the sync state.
    private(set) var isIdleLongEnough = true
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    /// One-shot commands to the grid; the grid clears them.
    /// Where Years/Months should open (e.g. the year just tapped).
    var timeScaleAnchor: String?
    var zoomCommand: ZoomCommand?
    var scrollTarget: Date?

    enum ZoomCommand: Equatable { case zoomIn, zoomOut }

    // MARK: Scrolling reports

    func gridScrolled(range: ClosedRange<Date>?, interacting: Bool, atBottom: Bool, userScrolled: Bool) {
        if range != visibleRange { visibleRange = range }
        let wasAtBottom = isAtBottom
        if atBottom != isAtBottom { isAtBottom = atBottom }
        // Years | Months | All while browsing, back to Library | Collections at the end.
        if !isSelecting {
            if atBottom, !wasAtBottom {
                if barMode != .tabs { barMode = .tabs }
            } else if !atBottom, barMode == .tabs, userScrolled || (wasAtBottom && interacting) {
                barMode = .timeScale
            }
        }
        guard interacting != isInteracting else { return }
        isInteracting = interacting
        idleTask?.cancel()
        if interacting {
            isIdleLongEnough = false
        } else {
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.isIdleLongEnough = true
            }
        }
    }

    /// Shows a short message near the bottom for a couple of seconds.
    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Selection

    func isSelected(_ id: String) -> Bool { selectionSet.contains(id) }

    func setSelected(_ id: String, _ selected: Bool) {
        if selected, !selectionSet.contains(id) {
            selection.append(id)
            selectionSet.insert(id)
        } else if !selected, selectionSet.contains(id) {
            selection.removeAll { $0 == id }
            selectionSet.remove(id)
        }
    }

    func clearSelection() {
        selection = []
        selectionSet = []
    }

    func endSelecting() {
        isSelecting = false
        clearSelection()
    }

    // MARK: Filtering

    /// Applies the filter menu to the timeline. `albumAssetIDs` is empty until album
    /// membership is synced, in which case "Not in an Album" shows everything.
    func apply(to items: [TimelineItem], myUserID: String, albumAssetIDs: Set<String>) -> [TimelineItem] {
        var result = items.filter { item in
            if !options.showScreenshots && item.isScreenshot { return false }
            if !options.showSharedWithYou && item.ownerID != myUserID { return false }
            switch filter {
            case .all: return true
            case .favourites: return item.isFavorite
            case .edited: return item.isEdited
            case .sharedWithYou: return item.ownerID != myUserID
            case .capturedByMe: return item.ownerID == myUserID && item.hasCamera
            case .notInAlbum: return !albumAssetIDs.contains(item.id)
            case .photos: return !item.isVideo
            case .videos: return item.isVideo
            case .screenshots: return item.isScreenshot
            }
        }
        if sort == .added {
            result.sort { ($0.uploadedAt ?? $0.date) < ($1.uploadedAt ?? $1.date) }
        }
        return result
    }

    var isFiltered: Bool { filter != .all || !options.showScreenshots || !options.showSharedWithYou }
}
