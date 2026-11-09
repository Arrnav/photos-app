import Core
import MediaCache
import CloudCore
import Persistence
import SwiftUI

/// Where a collection card leads.
enum CollectionRoute: Hashable {
    case smart(SmartCollection)
    case album(CloudAlbum)
    case memory(CloudMemory)
    case allAlbums(shared: Bool)
    case allMemories
    /// Specific photos (a place on the Map).
    case items(title: String, assetIDs: [String])
    /// Everyone recognised (face recognition), and one person's photos.
    case people
    case person(CloudPerson)
}

/// Collections: a large title with the ··· layout menu
/// and the account button, then collapsible sections of cards.
struct CollectionsScreen: View {
    let model: AppModel
    let session: LibrarySession
    @Bindable var ui: LibraryUIState
    let bottomInset: CGFloat
    @State private var collections = CollectionsModel()
    @State private var path = NavigationPath()
    @State private var showsAccount = false
    @State private var showsReorder = false
    @State private var showsPinnedEditor = false
    @State private var showsPausedAlert = false
    @Environment(\.scenePhase) private var scenePhase

    private var myUserID: String { session.account.userID }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach(collections.visibleSections) { section in
                        sectionView(section)
                    }
                    Divider().padding(.horizontal, 22)
                    Button("Reorder") { showsReorder = true }
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.top, -14)
                }
                .padding(.top, 14)
                .padding(.bottom, bottomInset + 20)
            }
            .scrollIndicators(.automatic)
            .refreshable { await collections.load(from: session, force: true) }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CollectionRoute.self) { route in
                CollectionDestinationView(route: route, session: session, collections: collections, myUserID: myUserID, bottomInset: bottomInset, shellUI: ui)
            }
        }
        // Also once the server is reachable: at launch the first load ran before the connection
        // was ready, failed, and nothing loaded again, so Memories and People stayed empty.
        .task(id: "\(model.isSyncPaused) \(session.connection != nil)") {
            await collections.load(from: session, force: session.connection != nil && !model.isSyncPaused)
        }
        // Albums, memories and people change on the server (face recognition finds people
        // over hours), so they're fetched again on coming back here (at most once a minute).
        .onChange(of: ui.section) { _, section in
            if section == .collections { Task { await collections.load(from: session) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, ui.section == .collections { Task { await collections.load(from: session) } }
        }
        .sheet(isPresented: $showsAccount) {
            AccountCard(model: model, session: session)
        }
        .sheet(isPresented: $showsReorder) {
            ReorderSectionsSheet(collections: collections)
        }
        .sheet(isPresented: $showsPinnedEditor) {
            PinnedEditorSheet(collections: collections)
        }
        .alert("Syncing with Cloud Paused", isPresented: $showsPausedAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collections")
                    .font(.system(size: 34, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if model.isSyncPaused {
                    Button {
                        showsPausedAlert = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "icloud.slash")
                            Text("Syncing Paused")
                            Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
                        }
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    layoutMenu
                    AccountButton(session: session, showsBadge: model.isSyncPaused || session.needsSignIn) {
                        showsAccount = true
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background {
            LightScrim()
                .ignoresSafeArea(edges: .top)
        }
    }

    private var layoutMenu: some View {
        Menu {
            ControlGroup {
                ForEach(CollectionsLayout.allCases, id: \.self) { layout in
                    Button {
                        withAnimation(.smooth) { collections.layout = layout }
                    } label: {
                        Label(layout.title, systemImage: layout.symbol)
                    }
                    .accessibilityAddTraits(collections.layout == layout ? .isSelected : [])
                }
            }
            .controlGroupStyle(.compactMenu)
            Button("Show All") { withAnimation(.smooth) { collections.showAll() } }
            Button("Collapse All") { withAnimation(.smooth) { collections.collapseAll() } }
            Divider()
            Button("Reorder") { showsReorder = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .glassSurface(Circle())
        .accessibilityLabel("Layout Options")
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: CollectionSection) -> some View {
        let isCollapsed = collections.collapsed.contains(section)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: section.title,
                route: route(for: section),
                showsEdit: section == .pinned && !isCollapsed,
                isCollapsed: isCollapsed,
                onEdit: { showsPinnedEditor = true },
                onToggle: { withAnimation(.smooth(duration: 0.3)) { collections.toggleCollapsed(section) } }
            )
            if !isCollapsed {
                sectionContent(section)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func route(for section: CollectionSection) -> CollectionRoute? {
        switch section {
        case .albums: .allAlbums(shared: false)
        case .sharedAlbums: .allAlbums(shared: true)
        case .memories: (collections.memories?.isEmpty ?? true) ? nil : .allMemories
        case .people: .people
        default: nil
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: CollectionSection) -> some View {
        let size = collections.layout.cardSize
        switch section {
        case .memories:
            if let memories = collections.memories, !memories.isEmpty {
                CardRow {
                    ForEach(memories) { memory in
                        NavigationLink(value: CollectionRoute.memory(memory)) {
                            MemoryCard(memory: memory, pipeline: session.pipeline, width: size * 2 + 12, height: size * 1.4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                EmptyCollectionCard(
                    symbol: "memories",
                    title: String(localized: "No Memories Available"),
                    message: String(localized: "Memories will appear here when more photos and videos are added to the library, or synced with Cloud.")
                )
            }
        case .pinned:
            CardRow {
                ForEach(collections.pinned) { smart in
                    NavigationLink(value: CollectionRoute.smart(smart)) {
                        SmartCard(smart: smart, keyItem: keyItem(for: smart), pipeline: session.pipeline, size: size)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .albums, .sharedAlbums:
            let albums = section == .albums ? collections.albums : collections.sharedAlbums
            if let albums, !albums.isEmpty {
                CardRow {
                    ForEach(albums) { album in
                        NavigationLink(value: CollectionRoute.album(album)) {
                            AlbumCard(album: album, pipeline: session.pipeline, size: size, thumbhash: thumbhash(for: album.thumbnailAssetID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if albums == nil {
                EmptyCollectionCard(
                    symbol: "rectangle.stack",
                    title: collections.loadError == nil ? String(localized: "Loading Albums…") : String(localized: "Albums Unavailable"),
                    message: collections.loadError ?? String(localized: "Albums load from your Cloud server.")
                )
            } else {
                EmptyCollectionCard(
                    symbol: section == .albums ? "rectangle.stack" : "rectangle.stack.badge.person.crop",
                    title: section == .albums ? String(localized: "No Albums") : String(localized: "No Shared Albums"),
                    message: section == .albums
                        ? String(localized: "Albums you create appear here.")
                        : String(localized: "Albums you share, or that others share with you, appear here.")
                )
            }
        case .people:
            if let people = collections.people, !people.isEmpty {
                PeopleRow(people: people, session: session)
            } else {
                EmptyCollectionCard(
                    symbol: "person.2.crop.square.stack",
                    title: collections.people == nil ? String(localized: "Loading People…") : String(localized: "No People Available"),
                    message: String(localized: "People will appear here when face recognition is turned on for your Cloud server.")
                )
            }
        case .featured:
            EmptyCollectionCard(
                symbol: "sparkles.rectangle.stack",
                title: String(localized: "No Featured Photos Available"),
                message: String(localized: "Featured photos will appear here when more photos and videos are added to the library, or synced with Cloud.")
            )
        case .trips:
            EmptyCollectionCard(
                symbol: "suitcase",
                title: String(localized: "No Trips Available"),
                message: String(localized: "Trips will appear here when more photos and videos are added to the library, or synced with Cloud.")
            )
        case .mediaTypes:
            let present = SmartCollection.mediaTypes.filter { smart in session.timeline.items.contains { smart.matches($0, myUserID: myUserID) } }
            PillGrid(items: present.isEmpty ? [.videos] : present)
        case .utilities:
            PillGrid(items: SmartCollection.utilities)
        }
    }

    /// The newest matching photo, as the card's cover.
    private func keyItem(for smart: SmartCollection) -> TimelineItem? {
        let items = session.timeline.items
        switch smart {
        case .recentlySaved:
            return items.max { ($0.uploadedAt ?? $0.date) < ($1.uploadedAt ?? $1.date) }
        case .map, .hidden, .recentlyDeleted, .archive:
            return nil
        default:
            return items.last { smart.matches($0, myUserID: myUserID) }
        }
    }

    private func thumbhash(for assetID: String?) -> String? {
        guard let assetID else { return nil }
        return session.timeline.items.last { $0.id == assetID }?.thumbhash
    }
}

// MARK: - Pieces

/// Title (with › when it opens a list), Pinned's Edit, and the collapse chevron.
private struct SectionHeader: View {
    let title: String
    let route: CollectionRoute?
    let showsEdit: Bool
    let isCollapsed: Bool
    let onEdit: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let route {
                NavigationLink(value: route) { titleLabel(chevron: true) }
                    .buttonStyle(.plain)
            } else {
                titleLabel(chevron: false)
            }
            Spacer()
            if showsEdit {
                Button("Edit", action: onEdit)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Color(.secondarySystemFill), in: Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
        }
        .padding(.horizontal, 22)
    }

    private func titleLabel(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.primary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A horizontally scrolling row of cards, inset like the titles.
private struct CardRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) { content }
                .padding(.horizontal, 22)
        }
        .scrollIndicators(.hidden)
    }
}

/// The grey card for an empty section.
private struct EmptyCollectionCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 34)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 22)
        .accessibilityElement(children: .combine)
    }
}

/// A square card with a cover photo and its name at the bottom left.
private struct CoverCard<Cover: View>: View {
    let title: String
    let size: CGFloat
    var badge: String?
    @ViewBuilder let cover: Cover

    var body: some View {
        cover
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.system(size: size < 100 ? 13 : 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(size < 100 ? 8 : 10)
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }
}

private struct SmartCard: View {
    let smart: SmartCollection
    let keyItem: TimelineItem?
    let pipeline: RemoteImagePipeline
    let size: CGFloat

    var body: some View {
        CoverCard(title: smart.title, size: size, badge: smart == .favourites ? "heart.fill" : nil) {
            if smart == .map {
                MapCover()
            } else if let keyItem {
                PipelineImage(item: keyItem, pipeline: pipeline, pixelSize: 500)
            } else {
                LinearGradient(colors: [Color(.systemGray4), Color(.systemGray2)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

private struct AlbumCard: View {
    let album: CloudAlbum
    let pipeline: RemoteImagePipeline
    let size: CGFloat
    let thumbhash: String?

    var body: some View {
        CoverCard(title: album.name, size: size) {
            if let cover = album.thumbnailAssetID {
                PipelineImage(assetID: cover, thumbhash: thumbhash, pipeline: pipeline, pixelSize: 500)
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: size * 0.22))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct MemoryCard: View {
    let memory: CloudMemory
    let pipeline: RemoteImagePipeline
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let key = memory.assets.first
        ZStack(alignment: .bottomLeading) {
            if let key {
                PipelineImage(assetID: key.id, thumbhash: key.thumbhash, pipeline: pipeline, pixelSize: 900)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.title).font(.system(size: 20, weight: .bold))
                Text(memory.subtitle).font(.system(size: 14, weight: .semibold)).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

extension CloudMemory {
    var title: String {
        let years = Calendar.current.component(.year, from: .now) - year
        return years == 1 ? String(localized: "1 Year Ago") : String(localized: "\(years) Years Ago")
    }

    var subtitle: String {
        memoryAt.formatted(.dateTime.day().month(.wide)) + " " + String(year)
    }
}

/// A map tile for Pinned › Map.
private struct MapCover: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.82, green: 0.9, blue: 0.78), Color(red: 0.72, green: 0.84, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "map.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Media Types and Utilities: two columns of grey pills, scrolling sideways.
private struct PillGrid: View {
    let items: [SmartCollection]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(44), spacing: 8), count: min(3, max(1, (items.count + 1) / 2))), spacing: 12) {
                ForEach(items) { smart in
                    NavigationLink(value: CollectionRoute.smart(smart)) {
                        HStack(spacing: 12) {
                            Image(systemName: smart.symbol)
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            Text(smart.title)
                                .font(.system(size: 17))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if smart.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 236, height: 44)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollIndicators(.hidden)
    }
}

/// The round profile button (top right), with a red badge when syncing needs attention.
struct AccountButton: View {
    let session: LibrarySession
    let showsBadge: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ProfileImageView(image: image, name: session.account.name, size: 44)
                .padding(2)
                .overlay(alignment: .topTrailing) {
                    if showsBadge {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.red, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .glassSurface(Circle())
        .accessibilityLabel("Account and Settings")
        .task(id: session.profileImageVersion) { image = await session.profileImage() }
    }
}

/// The user's picture, or their initials on a tinted circle.
struct ProfileImageView: View {
    let image: UIImage?
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(.systemGray3), Color(.systemGray)], startPoint: .top, endPoint: .bottom)
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A light, blurred band behind the Collections title, fading out downwards.
struct LightScrim: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.6),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .padding(.bottom, -24)
            .allowsHitTesting(false)
    }
}
