import Foundation
import CloudCore
import Observation
import Persistence

/// Sections of Collections, in the default order.
enum CollectionSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case memories, pinned, albums, sharedAlbums, people, featured, trips, mediaTypes, utilities

    var id: Self { self }

    var title: String {
        switch self {
        case .memories: String(localized: "Memories")
        case .pinned: String(localized: "Pinned")
        case .albums: String(localized: "Albums")
        case .sharedAlbums: String(localized: "Shared Albums")
        case .people: String(localized: "People")
        case .featured: String(localized: "Featured Photos")
        case .trips: String(localized: "Trips")
        case .mediaTypes: String(localized: "Media Types")
        case .utilities: String(localized: "Utilities")
        }
    }
}

/// The ··· menu's three layouts.
enum CollectionsLayout: String, CaseIterable, Codable, Sendable {
    /// Rows of medium cards (the default).
    case standard
    /// Rows of small cards, more per screen.
    case compact
    /// Rows of large cards, two per screen.
    case large

    var cardSize: CGFloat {
        switch self {
        case .standard: 112
        case .compact: 82
        case .large: 168
        }
    }

    var symbol: String {
        switch self {
        case .standard: "rectangle.grid.1x2.fill"
        case .compact: "square.grid.3x3.fill"
        case .large: "square.grid.2x2.fill"
        }
    }

    var title: String {
        switch self {
        case .standard: String(localized: "Default")
        case .compact: String(localized: "Compact")
        case .large: String(localized: "Large")
        }
    }
}

/// Smart collections (Pinned, Media Types, Utilities).
enum SmartCollection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case favourites, recentlySaved, map, videos, screenshots, livePhotos, panoramas
    case hidden, recentlyDeleted, capturedByMe, archive

    var id: Self { self }

    var title: String {
        switch self {
        case .favourites: String(localized: "Favourites")
        case .recentlySaved: String(localized: "Recently Saved")
        case .map: String(localized: "Map")
        case .videos: String(localized: "Videos")
        case .screenshots: String(localized: "Screenshots")
        case .livePhotos: String(localized: "Live Photos")
        case .panoramas: String(localized: "Panoramas")
        case .hidden: String(localized: "Hidden")
        case .recentlyDeleted: String(localized: "Recently Deleted")
        case .capturedByMe: String(localized: "Captured by Me")
        case .archive: String(localized: "Archive")
        }
    }

    var symbol: String {
        switch self {
        case .favourites: "heart"
        case .recentlySaved: "clock"
        case .map: "map"
        case .videos: "video"
        case .screenshots: "camera.viewfinder"
        case .livePhotos: "livephoto"
        case .panoramas: "pano"
        case .hidden: "eye.slash"
        case .recentlyDeleted: "trash"
        case .capturedByMe: "person.fill.viewfinder"
        case .archive: "archivebox"
        }
    }

    /// Hidden and Recently Deleted need Face ID.
    var isLocked: Bool { self == .hidden || self == .recentlyDeleted }

    /// Collections answered from the Library timeline.
    func matches(_ item: TimelineItem, myUserID: String) -> Bool {
        switch self {
        case .favourites: item.isFavorite
        case .videos: item.isVideo
        case .screenshots: item.isScreenshot
        case .livePhotos: item.isLivePhoto
        case .panoramas: !item.isVideo && item.aspectRatio >= 2.2
        case .capturedByMe: item.ownerID == myUserID && item.hasCamera
        case .recentlySaved, .map, .hidden, .recentlyDeleted, .archive: true
        }
    }

    static let mediaTypes: [SmartCollection] = [.videos, .livePhotos, .screenshots, .panoramas]
    static let utilities: [SmartCollection] = [.hidden, .recentlyDeleted, .capturedByMe, .archive]
    static let pinnable: [SmartCollection] = [.favourites, .recentlySaved, .map, .videos, .screenshots, .livePhotos, .panoramas, .capturedByMe, .archive]
}

/// Collections' layout preferences (kept on this phone) and server data.
@MainActor
@Observable
final class CollectionsModel {
    var layout: CollectionsLayout { didSet { save() } }
    var order: [CollectionSection] { didSet { save() } }
    var hiddenSections: Set<CollectionSection> { didSet { save() } }
    var collapsed: Set<CollectionSection> { didSet { save() } }
    var pinned: [SmartCollection] { didSet { save() } }

    private(set) var albums: [CloudAlbum]?
    private(set) var sharedAlbums: [CloudAlbum]?
    private(set) var memories: [CloudMemory]?
    /// Recognised people (needs the server's face recognition).
    private(set) var people: [CloudPerson]?
    private(set) var loadError: String?
    @ObservationIgnored private var lastLoad: Date?

    private struct Stored: Codable {
        var layout: CollectionsLayout
        var order: [CollectionSection]
        var hiddenSections: Set<CollectionSection>
        var collapsed: Set<CollectionSection>
        var pinned: [SmartCollection]
    }

    private static let key = "collections.preferences"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        layout = stored?.layout ?? .standard
        // Sections added in later versions go to their default place.
        var order = stored?.order ?? CollectionSection.allCases
        for section in CollectionSection.allCases where !order.contains(section) { order.append(section) }
        self.order = order
        hiddenSections = stored?.hiddenSections ?? []
        collapsed = stored?.collapsed ?? []
        pinned = stored?.pinned ?? [.favourites, .recentlySaved, .map, .videos, .screenshots]
    }

    private func save() {
        let stored = Stored(layout: layout, order: order, hiddenSections: hiddenSections, collapsed: collapsed, pinned: pinned)
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }

    var visibleSections: [CollectionSection] { order.filter { !hiddenSections.contains($0) } }

    func toggleCollapsed(_ section: CollectionSection) {
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
    }

    func showAll() { collapsed = [] }
    func collapseAll() { collapsed = Set(CollectionSection.allCases) }

    /// Albums and memories from the server; at most once a minute unless forced.
    func load(from session: LibrarySession, force: Bool = false) async {
        if !force, let lastLoad, Date.now.timeIntervalSince(lastLoad) < 60 { return }
        guard session.connection != nil else { return }
        lastLoad = .now
        do {
            async let owned = session.albums(shared: false)
            async let shared = session.albums(shared: true)
            async let memories = session.memories()
            let (ownedAlbums, sharedAlbums) = try await (owned, shared)
            albums = ownedAlbums.filter { !$0.isShared }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            self.sharedAlbums = sharedAlbums.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            self.memories = (try? await memories) ?? []
            people = (try? await session.people()) ?? people ?? []
            loadError = nil
        } catch {
            lastLoad = nil
            loadError = (error as? CloudError)?.message ?? error.localizedDescription
        }
    }
}
