import CloudCore
import SwiftUI

/// The top of the Library: large white "Library" over a dark blurred
/// band, a subtitle (visible dates, "N Items", or "Syncing Paused ›"), and the
/// filter menu and Select button (in select mode: filter + ··· and ✕).
struct LibraryHeader: View {
    @Bindable var ui: LibraryUIState
    let itemCount: Int
    /// The server can't be reached (shown like iCloud's "Syncing Paused").
    let syncPaused: Bool
    let selectionMenu: () -> AnyView
    @State private var showsPausedAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 12) {
                Text("Library")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailingControls
            }
            subtitle
                .frame(height: 24, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .alert("Syncing with Cloud Paused", isPresented: $showsPausedAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Subtitle

    private enum Subtitle: Equatable {
        case range(String)
        case count(Int)
        case paused
    }

    private var subtitleKind: Subtitle {
        if syncPaused, ui.isIdleLongEnough, !ui.isInteracting { return .paused }
        // At the very end of the library the header shows the item count (screenshots 3, 15).
        if ui.isAtBottom, !ui.isInteracting { return .count(itemCount) }
        if let range = ui.visibleRange { return .range(Formatting.dateRange(range)) }
        return .count(itemCount)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch subtitleKind {
        case .paused:
            Button {
                showsPausedAlert = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "icloud.slash")
                    Text("Syncing Paused")
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
                }
                .font(.headline)
                .foregroundStyle(.white)
            }
            .accessibilityHint("Shows why syncing is paused")
            .transition(.opacity)
        case .count(let count):
            Text(count == 1 ? "1 Item" : "\(count.formatted()) Items")
                .font(.headline)
                .foregroundStyle(.white)
                .transition(.opacity)
        case .range(let text):
            Text(text)
                .font(.headline)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
    }

    // MARK: Top-right controls

    @ViewBuilder
    private var trailingControls: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if ui.isSelecting {
                    HStack(spacing: 0) {
                        filterMenu.frame(width: 50, height: 48)
                        selectionMenu().frame(width: 50, height: 48)
                    }
                    .glassSurface(Capsule(), style: .dark)
                    Button {
                        withAnimation(.snappy) { ui.endSelecting() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Circle(), style: .dark)
                    .accessibilityLabel("Done Selecting")
                } else {
                    filterMenu
                        .frame(width: 48, height: 48)
                        .glassSurface(Circle(), style: .dark)
                    Button {
                        withAnimation(.snappy) { ui.isSelecting = true }
                    } label: {
                        Text("Select")
                            .font(.system(size: 17, weight: .semibold))
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Capsule(), style: .dark)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var filterMenu: some View {
        Menu {
            LibraryFilterMenuContent(ui: ui)
        } label: {
            Image(systemName: ui.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Filter and Sort")
    }
}

/// Added / Captured, Filter:, Media Types ▸ and View Options ▸ (the filter menu).
struct LibraryFilterMenuContent: View {
    @Bindable var ui: LibraryUIState

    var body: some View {
        ControlGroup {
            Button {
                ui.sort = .added
            } label: {
                Label("Added", systemImage: ui.sort == .added ? "clock.fill" : "clock")
            }
            Button {
                ui.sort = .captured
            } label: {
                Label("Captured", systemImage: ui.sort == .captured ? "camera.fill" : "camera")
            }
        }

        Section("Filter:") {
            Picker("Filter", selection: $ui.filter) {
                Label("All Items", systemImage: "square.grid.3x3").tag(LibraryFilter.all)
                Label("Favourites", systemImage: "heart").tag(LibraryFilter.favourites)
                Label("Edited", systemImage: "slider.horizontal.3").tag(LibraryFilter.edited)
                Label("Shared with You", systemImage: "shared.with.you").tag(LibraryFilter.sharedWithYou)
                Label("Captured by Me", systemImage: "person.fill.viewfinder").tag(LibraryFilter.capturedByMe)
                Label("Not in an Album", systemImage: "rectangle.stack.slash").tag(LibraryFilter.notInAlbum)
            }
            .pickerStyle(.inline)

            Menu {
                Picker("Media Types", selection: $ui.filter) {
                    Label("Photos", systemImage: "photo").tag(LibraryFilter.photos)
                    Label("Videos", systemImage: "video").tag(LibraryFilter.videos)
                    Label("Screenshots", systemImage: "camera.viewfinder").tag(LibraryFilter.screenshots)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Media Types", systemImage: "photo.stack")
            }
        }

        Menu("View Options") {
            Button {
                ui.zoomCommand = .zoomIn
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            Button {
                ui.zoomCommand = .zoomOut
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            Toggle(isOn: $ui.options.aspectRatioGrid) {
                Label("Aspect Ratio Grid", systemImage: "rectangle.expand.vertical")
            }
            Section("Show:") {
                Toggle(isOn: $ui.options.showScreenshots) {
                    Label("Screenshots", systemImage: "camera.viewfinder")
                }
                Toggle(isOn: $ui.options.showSharedWithYou) {
                    Label("Shared with You", systemImage: "shared.with.you")
                }
            }
        }
    }
}
