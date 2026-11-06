import Core
import CloudCore
import MapKit
import Persistence
import SwiftUI

/// What a Collections card opens.
struct CollectionDestinationView: View {
    let route: CollectionRoute
    let session: LibrarySession
    let collections: CollectionsModel
    let myUserID: String
    let bottomInset: CGFloat
    /// The app's bar state (Recently Deleted hides the floating bar while selecting).
    let shellUI: LibraryUIState

    var body: some View {
        switch route {
        case .smart(.hidden):
            HiddenAlbumScreen(session: session, shellUI: shellUI, bottomInset: bottomInset)
        case .smart(.recentlyDeleted):
            RecentlyDeletedScreen(session: session, shellUI: shellUI, bottomInset: bottomInset)
        case .smart(.archive):
            ScopedGridScreen(title: SmartCollection.archive.title, scope: .visibility(.archive), session: session, bottomInset: bottomInset)
        case .smart(.map):
            LibraryMapScreen(session: session)
        case .smart(let smart):
            CollectionGridScreen(title: smart.title, items: items(for: smart), session: session, bottomInset: bottomInset)
        case .album(let album):
            AlbumScreen(album: album, session: session, bottomInset: bottomInset)
        case .memory(let memory):
            CollectionGridScreen(title: memory.title, subtitle: memory.subtitle, items: memory.assets.map(TimelineItem.init).reversed(), session: session, bottomInset: bottomInset)
        case .allAlbums(let shared):
            AllAlbumsScreen(title: shared ? String(localized: "Shared Albums") : String(localized: "Albums"), albums: (shared ? collections.sharedAlbums : collections.albums) ?? [], session: session, bottomInset: bottomInset)
        case .items(let title, let assetIDs):
            let ids = Set(assetIDs)
            CollectionGridScreen(title: title, items: session.timeline.items.filter { ids.contains($0.id) }, session: session, bottomInset: bottomInset)
        case .allMemories:
            AllMemoriesScreen(memories: collections.memories ?? [], session: session, bottomInset: bottomInset)
        case .people:
            PeopleScreen(session: session, initial: collections.people, bottomInset: bottomInset)
        case .person(let person):
            PersonScreen(person: person, session: session, bottomInset: bottomInset)
        }
    }

    private func items(for smart: SmartCollection) -> [TimelineItem] {
        let all = session.timeline.items
        if smart == .recentlySaved {
            // Uploaded in the last 30 days, in the order they were saved.
            let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
            return all.filter { ($0.uploadedAt ?? .distantPast) >= cutoff }
                .sorted { ($0.uploadedAt ?? $0.date) < ($1.uploadedAt ?? $1.date) }
        }
        return all.filter { smart.matches($0, myUserID: myUserID) }
    }
}

/// A grid of photos under a large white title over a dark band, like an album.
/// Recently Deleted (`mode: .trash`) and Hidden (`.hidden`) are plain: a dark title on white,
/// a "🗑 N Items ⓘ" line, and the Library's five columns.
struct CollectionGridScreen: View {
    let title: String
    var subtitle: String?
    let items: [TimelineItem]
    let session: LibrarySession
    let bottomInset: CGFloat
    var isLoading = false
    var emptyMessage: String?
    /// Select mode (Recently Deleted); nil for plain collections.
    var ui: LibraryUIState?
    var caption: ((TimelineItem) -> TileCaption?)?
    /// How the viewer opens (Recently Deleted: Delete and Recover only).
    var mode: ViewerViewController.Mode = .library
    /// Shown by the ⓘ after the count (Recently Deleted).
    var infoTip: String?
    @AppStorage("collection.columns") private var collectionColumns = 3
    @AppStorage("trash.columns") private var trashColumns = 5
    @AppStorage("hidden.columns") private var hiddenColumns = 5
    @State private var headerBottom: CGFloat = 160
    @State private var version = 0
    @State private var showsTip = false

    private var isPlain: Bool { mode != .library }

    private var columns: Binding<Int> {
        switch mode {
        case .trash: $trashColumns
        case .hidden: $hiddenColumns
        case .library: $collectionColumns
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if items.isEmpty {
                Color(.systemBackground).ignoresSafeArea()
                VStack {
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(String(localized: "No Photos or Videos"), systemImage: "photo.on.rectangle", description: emptyMessage.map(Text.init))
                    }
                    Spacer()
                }
            } else {
                PhotoGridView(
                    snapshot: TimelineSnapshot(items: items, version: version, isLoaded: true),
                    session: session, mode: mode, columns: columns, ui: ui,
                    insets: UIEdgeInsets(top: headerBottom + (isPlain ? 2 : 6), left: 0, bottom: bottomInset + 12, right: 0),
                    isPrimary: false, takesCommands: ui != nil && isPlain, caption: caption
                )
                .ignoresSafeArea()
                if isPlain {
                    // The grid scrolls under a plain band.
                    Color(.systemBackground)
                        .frame(height: headerBottom + 2)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                } else {
                    TopScrim(height: headerBottom + 44)
                        .ignoresSafeArea(edges: .top)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                subtitleLine
            }
            .foregroundStyle(items.isEmpty || isPlain ? Color.primary : Color.white)
            .shadow(color: .black.opacity(items.isEmpty || isPlain ? 0 : 0.25), radius: 6, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: items) { version += 1 }
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if isPlain {
            HStack(spacing: 6) {
                Image(systemName: mode == .hidden ? "eye.slash" : "trash")
                    .font(.system(size: 15, weight: .semibold))
                Text(items.count == 1 ? String(localized: "1 Item") : String(localized: "\(items.count.formatted()) Items"))
                    .font(.headline)
                    .contentTransition(.numericText())
                if let infoTip {
                    Button { showsTip = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.tint)
                            .padding(.leading, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Recently Deleted")
                    .popover(isPresented: $showsTip, arrowEdge: .top) {
                        Text(infoTip)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 270, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
        } else {
            Text(subtitle ?? countText)
                .font(.headline)
        }
    }

    private var countText: String {
        let videos = items.filter(\.isVideo).count
        let photos = items.count - videos
        switch (photos, videos) {
        case (_, 0): return photos == 1 ? String(localized: "1 Photo") : String(localized: "\(photos.formatted()) Photos")
        case (0, _): return videos == 1 ? String(localized: "1 Video") : String(localized: "\(videos.formatted()) Videos")
        default: return String(localized: "\(photos.formatted()) Photos, \(videos.formatted()) Videos")
        }
    }
}

/// Archive (and other database scopes), kept live as sync changes them.
private struct ScopedGridScreen: View {
    let title: String
    let scope: TimelineScope
    let session: LibrarySession
    let bottomInset: CGFloat
    @State private var items: [TimelineItem]?

    var body: some View {
        CollectionGridScreen(title: title, items: items ?? [], session: session, bottomInset: bottomInset, isLoading: items == nil)
            .task {
                do {
                    for try await value in session.observe(scope) { items = value }
                } catch {}
            }
    }
}

/// Recently Deleted: Face ID first; then the trash, each photo showing the
/// days left before it's removed for good. Select picks items to recover or delete
/// (with Show Selected, like the Library); the menu has Recover All and Delete All.
private struct RecentlyDeletedScreen: View {
    let session: LibrarySession
    let shellUI: LibraryUIState
    let bottomInset: CGFloat
    @State private var unlocked = false
    /// Hidden items deleted show here too when the Hidden album could be unlocked with the same Face ID.
    @State private var includesHidden = false
    @State private var items: [TimelineItem]?
    @State private var deletedAt: [String: Date] = [:]
    @State private var ui = LibraryUIState()
    @State private var confirm: Confirmation?
    @State private var error: String?

    private enum Confirmation: Identifiable {
        case deleteAll, recoverAll, deleteSelected, recoverSelected
        var id: Self { self }
        var deletes: Bool { self == .deleteAll || self == .deleteSelected }
    }

    var body: some View {
        Group {
            if unlocked {
                CollectionGridScreen(
                    title: SmartCollection.recentlyDeleted.title, items: items ?? [], session: session,
                    bottomInset: ui.isSelecting ? 96 : bottomInset,
                    isLoading: items == nil,
                    emptyMessage: String(localized: "Deleted items stay here for \(session.trashRetentionDays) days, then they're removed from Cloud for good."),
                    ui: ui, caption: daysLeft, mode: .trash,
                    infoTip: String(localized: "Photos and videos show the days remaining before deletion. After that time, items will be permanently deleted. This may take up to \(session.trashRetentionDays + 1) days.")
                )
                .toolbar { toolbar }
                .overlay(alignment: .bottom) {
                    if ui.isSelecting {
                        footer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: ui.isSelecting)
                .task(id: includesHidden) {
                    do {
                        for try await value in session.observe(includesHidden ? .trashIncludingHidden : .trash) {
                            deletedAt = await session.trashDates()
                            items = value
                        }
                    } catch {}
                }
                .task { await session.refreshTrashRetentionDays() }
            } else {
                LockedCollectionView(title: SmartCollection.recentlyDeleted.title) { await unlock() }
            }
        }
        .task { if !unlocked { await unlock() } }
        .onChange(of: ui.isSelecting) { _, selecting in shellUI.hidesFloatingBar = selecting }
        .onDisappear {
            shellUI.hidesFloatingBar = false
            ui.endSelecting()
            if includesHidden { Task { await session.hiddenVault.lock() } }
        }
        .sheet(item: $ui.pendingSheet) { sheet in
            if case .showSelected = sheet {
                ShowSelectedSheet(session: session, ui: ui, items: (items ?? []).filter { ui.isSelected($0.id) })
            }
        }
        .confirmationDialog("", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .hidden) {
            switch confirm {
            case .deleteAll:
                Button(deleteTitle(items?.map(\.id) ?? []), role: .destructive) { delete(items?.map(\.id) ?? []) }
            case .recoverAll:
                Button(recoverTitle(items?.map(\.id) ?? [])) { recover(items?.map(\.id) ?? []) }
            case .deleteSelected:
                Button(deleteTitle(ui.selection), role: .destructive) { delete(ui.selection) }
            case .recoverSelected:
                Button(recoverTitle(ui.selection)) { recover(ui.selection) }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if confirm?.deletes == true {
                Text(deleteMessage(confirm == .deleteAll ? items?.map(\.id) ?? [] : ui.selection))
            }
        }
        .alert("Couldn't Finish", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let items, !items.isEmpty {
            if ui.isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy) { ui.endSelecting() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { confirm = .recoverAll } label: { Label("Recover All", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { confirm = .deleteAll } label: { Label("Delete All", systemImage: "trash") }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("More")
                }
                // Separate glass for the filter circle and the Select capsule
                // (iOS 26 otherwise joins neighbouring toolbar items into one piece).
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { withAnimation(.snappy) { ui.isSelecting = true } }
                }
            }
        }
    }

    /// Delete · "Select Items" / "Show Selected (N)" · Recover.
    private var footer: some View {
        let count = ui.selection.count
        return HStack(spacing: 10) {
            footerButton(String(localized: "Delete"), color: count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.red)) {
                if count > 0 { confirm = .deleteSelected }
            }
            Spacer(minLength: 0)
            footerButton(count == 0 ? String(localized: "Select Items") : String(localized: "Show Selected (\(count))"), color: AnyShapeStyle(.primary)) {
                if count > 0 { ui.pendingSheet = .showSelected }
            }
            .contentTransition(.numericText())
            Spacer(minLength: 0)
            footerButton(String(localized: "Recover"), color: count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint)) {
                if count > 0 { confirm = .recoverSelected }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .background { Color(.systemBackground).ignoresSafeArea(edges: .bottom) }
        .animation(.snappy, value: count)
    }

    private func footerButton(_ title: String, color: AnyShapeStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(color)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(Capsule())
    }

    /// "Photos", "Videos" or "Items", for the buttons.
    private func noun(_ ids: [String]) -> (one: String, many: String) {
        let byID = Set(ids)
        let chosen = (items ?? []).filter { byID.contains($0.id) }
        if chosen.allSatisfy(\.isVideo) { return (String(localized: "Video"), String(localized: "Videos")) }
        if !chosen.contains(where: \.isVideo) { return (String(localized: "Photo"), String(localized: "Photos")) }
        return (String(localized: "Item"), String(localized: "Items"))
    }

    private func deleteTitle(_ ids: [String]) -> String {
        let noun = noun(ids)
        return ids.count == 1 ? String(localized: "Delete \(noun.one)") : String(localized: "Delete \(ids.count.formatted()) \(noun.many)")
    }

    private func recoverTitle(_ ids: [String]) -> String {
        let noun = noun(ids)
        return ids.count == 1 ? String(localized: "Recover \(noun.one)") : String(localized: "Recover \(ids.count.formatted()) \(noun.many)")
    }

    private func deleteMessage(_ ids: [String]) -> String {
        let noun = noun(ids)
        return ids.count == 1
            ? String(localized: "This \(noun.one.lowercased()) will be deleted from Cloud. This action can't be undone.")
            : String(localized: "These \(noun.many.lowercased()) will be deleted from Cloud. This action can't be undone.")
    }

    /// "15 days", "1 day", or "< 1 day" in red.
    private func daysLeft(_ item: TimelineItem) -> TileCaption? {
        guard let deleted = deletedAt[item.id] else { return nil }
        let remaining = deleted.addingTimeInterval(Double(session.trashRetentionDays) * 86_400).timeIntervalSinceNow
        if remaining < 86_400 { return TileCaption(text: String(localized: "< 1 day"), isUrgent: true) }
        let days = Int(remaining / 86_400)
        return TileCaption(text: days == 1 ? String(localized: "1 day") : String(localized: "\(days) days"))
    }

    /// One Face ID: through the Hidden album's PIN when there is one (so deleted hidden items
    /// can be shown), otherwise a plain check.
    private func unlock() async {
        let vault = session.hiddenVault
        var vaultOpen = vault.state == .unlocked
        if !vaultOpen, vault.hasStoredPin { vaultOpen = await vault.unlock() }
        if vaultOpen {
            includesHidden = true
            unlocked = true
            return
        }
        // Declined at Face ID: stay locked. Any other failure: unlock without hidden items.
        if vault.hasStoredPin, vault.errorMessage == nil, vault.state == .locked { return }
        unlocked = await ProtectedSecretStore.authenticate(reason: String(localized: "Unlock Recently Deleted"))
    }

    private func recover(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await session.restoreFromTrash(assetIDs: ids)
                withAnimation(.snappy) { ui.endSelecting() }
                shellUI.showToast(ids.count == 1 ? String(localized: "Recovered 1 item") : String(localized: "Recovered \(ids.count.formatted()) items"))
            } catch { self.error = (error as? CloudError)?.message ?? error.localizedDescription }
        }
    }

    private func delete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await session.deletePermanently(assetIDs: ids)
                withAnimation(.snappy) { ui.endSelecting() }
            } catch { self.error = (error as? CloudError)?.message ?? error.localizedDescription }
        }
    }
}

/// The locked state of Hidden / Recently Deleted (the "View Album" screen).
struct LockedCollectionView: View {
    let title: String
    let unlock: () async -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("\(title) is Locked")
                .font(.title3.weight(.semibold))
            Text("Use Face ID to view this album.")
                .foregroundStyle(.secondary)
            Button("View Album") { Task { await unlock() } }
                .font(.headline)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An album's photos, loaded from the server.
private struct AlbumScreen: View {
    let album: CloudAlbum
    let session: LibrarySession
    let bottomInset: CGFloat
    @State private var items: [TimelineItem]?
    @State private var error: String?

    var body: some View {
        CollectionGridScreen(title: album.name, items: items ?? [], session: session, bottomInset: bottomInset,
                             isLoading: items == nil && error == nil, emptyMessage: error)
            .task {
                do {
                    items = try await session.albumItems(album.id)
                } catch {
                    self.error = (error as? CloudError)?.message ?? error.localizedDescription
                    items = []
                }
            }
    }
}

/// Albums › : every album as a two-column grid of covers.
private struct AllAlbumsScreen: View {
    let title: String
    let albums: [CloudAlbum]
    let session: LibrarySession
    let bottomInset: CGFloat

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink(value: CollectionRoute.album(album)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    if let cover = album.thumbnailAssetID {
                                        PipelineImage(assetID: cover, thumbhash: nil, pipeline: session.pipeline, pixelSize: 600)
                                    } else {
                                        Color(.secondarySystemBackground)
                                            .overlay { Image(systemName: "photo.on.rectangle").font(.title).foregroundStyle(.tertiary) }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(album.assetCount.formatted()).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomInset + 20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct AllMemoriesScreen: View {
    let memories: [CloudMemory]
    let session: LibrarySession
    let bottomInset: CGFloat

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(memories) { memory in
                    NavigationLink(value: CollectionRoute.memory(memory)) {
                        ZStack(alignment: .bottomLeading) {
                            Color.clear.frame(height: 260)
                                .overlay {
                                    if let key = memory.assets.first {
                                        PipelineImage(assetID: key.id, thumbhash: key.thumbhash, pipeline: session.pipeline, pixelSize: 1200)
                                    }
                                }
                            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memory.title).font(.title2.bold())
                                Text(memory.subtitle).font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(18)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomInset + 20)
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Pinned › Map: photo thumbnails on a map, grouped by area; tap a group to see its photos.
private struct LibraryMapScreen: View {
    let session: LibrarySession
    @State private var clusters: [MapCluster] = []
    @State private var position = MapCameraPosition.automatic
    @State private var span: Double = 20
    @State private var locations: [AssetLocation] = []

    var body: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    NavigationLink(value: CollectionRoute.items(title: String(localized: "\(cluster.assetIDs.count) Items"), assetIDs: cluster.assetIDs)) {
                        PipelineImage(assetID: cluster.keyAssetID, thumbhash: thumbhash(cluster.keyAssetID), pipeline: session.pipeline, pixelSize: 200, size: .thumbnail)
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 2.5))
                            .overlay(alignment: .topTrailing) {
                                if cluster.assetIDs.count > 1 {
                                    Text(cluster.assetIDs.count.formatted())
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue, in: Capsule())
                                        .offset(x: 8, y: -8)
                                }
                            }
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .onMapCameraChange(frequency: .onEnd) { context in
            span = max(context.region.span.latitudeDelta, 0.0005)
            recluster()
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            locations = await session.locations()
            recluster()
        }
    }

    /// Groups photos into cells about 1/8 of the visible height, so pins don't overlap.
    private func recluster() {
        let cell = span / 8
        var groups: [String: [AssetLocation]] = [:]
        for location in locations {
            let key = "\(Int((location.latitude / cell).rounded(.down)))_\(Int((location.longitude / cell).rounded(.down)))"
            groups[key, default: []].append(location)
        }
        clusters = groups.map { key, members in
            MapCluster(id: key, assetIDs: members.map(\.assetID),
                       coordinate: CLLocationCoordinate2D(latitude: members.map(\.latitude).reduce(0, +) / Double(members.count),
                                                          longitude: members.map(\.longitude).reduce(0, +) / Double(members.count)))
        }
        .sorted { $0.assetIDs.count > $1.assetIDs.count }
        .prefix(150)
        .map { $0 }
    }

    private func thumbhash(_ id: String) -> String? {
        session.timeline.items.last { $0.id == id }?.thumbhash
    }
}

private struct MapCluster: Identifiable {
    let id: String
    let assetIDs: [String]
    let coordinate: CLLocationCoordinate2D
    var keyAssetID: String { assetIDs[0] }
}
