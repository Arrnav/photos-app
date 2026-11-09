import CloudCore
import Persistence
import SwiftUI

/// The signed-in app: Library and Collections with a
/// floating glass bar (Library | Collections, Search), Search over everything, and
/// select mode's footer in place of the bar.
struct PhotosShell: View {
    let model: AppModel
    @State private var ui = LibraryUIState()

    /// Room for the floating bar at the bottom of the screens.
    private let barSpace: CGFloat = 100

    init(model: AppModel) {
        self.model = model
        PhotosSettings.registerDefaults()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let session = model.session {
                LibraryScreen(model: model, session: session, ui: ui, bottomInset: barSpace)
                    .opacity(ui.section == .library ? 1 : 0)
                    .allowsHitTesting(ui.section == .library)
                    .accessibilityHidden(ui.section != .library)
                CollectionsScreen(model: model, session: session, ui: ui, bottomInset: barSpace)
                    .opacity(ui.section == .collections ? 1 : 0)
                    .allowsHitTesting(ui.section == .collections)
                    .accessibilityHidden(ui.section != .collections)
            } else if let error = model.sessionError {
                ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 12) {
                if let toast = ui.toast {
                    ToastView(message: toast)
                }
                if ui.isSelecting && ui.section == .library {
                    SelectionFooter(ui: ui) { ui.shareRequested = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !ui.hidesFloatingBar {
                    FloatingBar(ui: ui)
                        .padding(.bottom, 26)
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: ui.isSelecting)
            .animation(.snappy, value: ui.hidesFloatingBar)
            .animation(.snappy, value: ui.toast)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.phoneImages, model.session?.phoneImages)
        .task(id: model.session?.account.userID) {
            // First launch with the phone library: ask for Photos access (iOS shows its prompt once).
            if let session = model.session, session.photoAccess == .notDetermined {
                await session.requestPhotoAccess()
            }
        }
        .fullScreenCover(isPresented: $ui.showsSearch) {
            if let session = model.session {
                SearchScreen(session: session, ui: ui)
            }
        }
        .sheet(item: $ui.pendingSheet) { sheet in
            if let session = model.session {
                selectionSheet(sheet, session: session)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
            if let session = model.session {
                confirmationActions(session: session)
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: Select mode sheets and confirmations

    @ViewBuilder
    private func selectionSheet(_ sheet: SelectionSheet, session: LibrarySession) -> some View {
        let ids = ui.selection
        let done: (String) -> Void = { message in
            ui.showToast(message)
            withAnimation(.snappy) { ui.endSelecting() }
        }
        switch sheet {
        case .showSelected:
            ShowSelectedSheet(session: session, ui: ui, items: session.timeline.items.filter { ui.isSelected($0.id) })
        case .addToAlbum(let shared):
            AlbumPickerView(session: session, shared: shared, assetIDs: ids, onDone: done)
        case .newAlbum(let shared):
            NewAlbumView(session: session, shared: shared, assetIDs: ids, onDone: done)
        case .adjustDate:
            if let first = ids.first, let details = session.detailsNow(for: first) {
                AdjustDateView(session: session, details: details, assetIDs: ids, onDone: done)
            }
        case .adjustLocation:
            if let first = ids.first, let details = session.detailsNow(for: first) {
                AdjustLocationView(session: session, details: details, assetIDs: ids, onDone: done)
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { ui.pendingConfirmation != nil }, set: { if !$0 { ui.pendingConfirmation = nil } })
    }

    private var confirmationTitle: String {
        let count = ui.selection.count
        switch ui.pendingConfirmation {
        case .delete: return count == 1 ? String(localized: "Delete 1 Item?") : String(localized: "Delete \(count) Items?")
        case .hide: return count == 1 ? String(localized: "Hide 1 Item?") : String(localized: "Hide \(count) Items?")
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch ui.pendingConfirmation {
        case .delete: model.session.map { String(localized: "These items will be deleted from Cloud, and from this iPhone where they are on it. You can recover them from Recently Deleted for \($0.trashRetentionDays) days.") } ?? ""
        case .hide: String(localized: "These items will be hidden, but can be found in the Hidden album in Collections › Utilities.")
        case nil: ""
        }
    }

    @ViewBuilder
    private func confirmationActions(session: LibrarySession) -> some View {
        let ids = ui.selection
        switch ui.pendingConfirmation {
        case .delete:
            Button(ids.count == 1 ? "Delete Item" : "Delete \(ids.count) Items", role: .destructive) {
                act(String(localized: "Moved to Recently Deleted")) { try await session.moveToTrash(assetIDs: ids) }
            }
        case .hide:
            Button(ids.count == 1 ? "Hide Item" : "Hide \(ids.count) Items") {
                act(String(localized: "Hidden")) { try await session.hide(assetIDs: ids) }
            }
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) {}
    }

    private func act(_ success: String, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                ui.showToast(success)
                withAnimation(.snappy) { ui.endSelecting() }
            } catch is CancellationError {
                // Declined in iOS's own prompt: nothing changed.
            } catch {
                ui.showToast((error as? CloudError)?.message ?? error.localizedDescription)
            }
        }
    }
}
