import CloudCore
import Persistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sheets and confirmations started from select mode.
enum SelectionSheet: Identifiable {
    case showSelected
    case addToAlbum(shared: Bool)
    case newAlbum(shared: Bool)
    case adjustDate
    case adjustLocation

    var id: String {
        switch self {
        case .showSelected: "selected"
        case .addToAlbum(let shared): "add-\(shared)"
        case .newAlbum(let shared): "new-\(shared)"
        case .adjustDate: "date"
        case .adjustLocation: "location"
        }
    }
}

enum SelectionConfirmation: Identifiable {
    case delete, hide
    var id: Self { self }
}

extension LibraryUIState {
    func selectedItems(in items: [TimelineItem]) -> [TimelineItem] {
        let ids = selectionSet
        return items.filter { ids.contains($0.id) }
    }
}

/// The ··· menu in select mode (multiple items).
struct SelectionMenu: View {
    let model: AppModel
    let session: LibrarySession
    @Bindable var ui: LibraryUIState
    let items: [TimelineItem]

    var body: some View {
        Menu {
            ControlGroup {
                Button { run(String(localized: "Copied")) { try await copyOriginals() } } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button { run(String(localized: "Duplicated")) { for id in ui.selection { try await session.duplicate(assetID: id) } } } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button { ui.pendingConfirmation = .hide } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
            }
            Section {
                Button { run(String(localized: "Added to Favourites")) { try await session.setFavorite(true, assetIDs: ui.selection) } } label: {
                    Label("Favourite", systemImage: "heart")
                }
                Button { run(String(localized: "Archived"), endSelecting: true) { try await session.setArchived(true, assetIDs: ui.selection) } } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            Section {
                Menu {
                    Button { ui.pendingSheet = .addToAlbum(shared: false) } label: { Label("Album", systemImage: "rectangle.stack") }
                    Button { ui.pendingSheet = .addToAlbum(shared: true) } label: { Label("Shared Album", systemImage: "rectangle.stack.badge.person.crop") }
                    Divider()
                    Button { ui.pendingSheet = .newAlbum(shared: false) } label: { Label("New Album", systemImage: "rectangle.stack") }
                    Button { ui.pendingSheet = .newAlbum(shared: true) } label: { Label("New Shared Album", systemImage: "rectangle.stack.badge.person.crop") }
                } label: {
                    Label("Add To", systemImage: "photo.on.rectangle.angled")
                }
                Menu {
                    Button { ui.pendingSheet = .adjustDate } label: { Label("Adjust Date & Time", systemImage: "calendar.badge.clock") }
                    Button { ui.pendingSheet = .adjustLocation } label: { Label("Adjust Location", systemImage: "mappin.and.ellipse") }
                } label: {
                    Label("Adjust Info", systemImage: "info.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .disabled(ui.selection.isEmpty)
        .accessibilityLabel("More")
    }

    private func run(_ success: String, endSelecting: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                ui.showToast(success)
                if endSelecting { withAnimation(.snappy) { ui.endSelecting() } }
            } catch {
                ui.showToast((error as? CloudError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Copies the original files (full quality) to the clipboard.
    private func copyOriginals() async throws {
        var providers: [[String: Any]] = []
        for id in ui.selection {
            guard let details = session.detailsNow(for: id) else { continue }
            let url = try await session.originals.file(assetID: id, fileName: details.asset.originalFileName)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let type = UTType(filenameExtension: url.pathExtension) ?? .image
            providers.append([type.identifier: data])
        }
        UIPasteboard.general.items = providers
    }
}

/// Select mode's bottom bar: Share · "Select Items" / "Show Selected (N)" · Delete.
struct SelectionFooter: View {
    @Bindable var ui: LibraryUIState
    let onShare: () -> Void

    var body: some View {
        let count = ui.selection.count
        HStack {
            // Greyed but still tappable (the glass reacts) with nothing selected.
            Button { if count > 0 { onShare() } } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .glassSurface(Circle())
            .foregroundStyle(count == 0 ? .tertiary : .primary)
            .accessibilityLabel("Share")
            Spacer()
            Button {
                if count > 0 { ui.pendingSheet = .showSelected }
            } label: {
                Text(count == 0 ? String(localized: "Select Items") : String(localized: "Show Selected (\(count))"))
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 26)
                    .frame(height: 54)
            }
            .buttonStyle(.plain)
            .glassSurface(Capsule())
            .contentTransition(.numericText())
            Spacer()
            Button {
                if count > 0 { ui.pendingConfirmation = .delete }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .glassSurface(Circle())
            .foregroundStyle(count == 0 ? .tertiary : .primary)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background {
            Color(.systemBackground)
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(.snappy, value: count)
    }
}

/// "Show Selected": only the selected items, which can still be toggled, with Deselect All and ✓.
struct ShowSelectedSheet: View {
    let session: LibrarySession
    @Bindable var ui: LibraryUIState
    /// The items selected when the sheet opened (so deselected ones stay to be reselected).
    let items: [TimelineItem]
    @Environment(\.dismiss) private var dismiss
    @State private var columns = 3

    var body: some View {
        NavigationStack {
            // The Library's grid, so tap and drag-to-select (with auto-scroll) work here too.
            PhotoGridView(
                snapshot: snapshot, session: session, columns: $columns, ui: ui,
                insets: UIEdgeInsets(top: 0, left: 0, bottom: 90, right: 0), isPrimary: false
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { columns = columns == 3 ? 5 : 3 } label: {
                        Image(systemName: columns == 3 ? "square.grid.3x3" : "square.grid.2x2")
                    }
                    .accessibilityLabel("Change Layout")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .accessibilityLabel("Done")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Deselect All") { ui.clearSelection() }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 26)
                    .frame(height: 54)
                    .glassSurface(Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private var snapshot: TimelineSnapshot {
        TimelineSnapshot(items: items, version: 1, isLoaded: true)
    }

    private var title: String {
        let selected = items.filter { ui.isSelected($0.id) }
        let videos = selected.filter(\.isVideo).count
        let photos = selected.count - videos
        switch (photos, videos) {
        case (0, 0): return String(localized: "None Selected")
        case (_, 0): return photos == 1 ? String(localized: "1 Photo Selected") : String(localized: "\(photos) Photos Selected")
        case (0, _): return videos == 1 ? String(localized: "1 Video Selected") : String(localized: "\(videos) Videos Selected")
        default: return String(localized: "\(selected.count) Items Selected")
        }
    }
}

/// A short message near the bottom (e.g. "Archived").
struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassSurface(Capsule(), interactive: false)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
    }
}
