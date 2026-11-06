import CloudCore
import Persistence
import SwiftUI

/// The Hidden album (Immich Locked Folder). Face ID first; then the same plain grid as
/// Recently Deleted, with select mode: Share · Select Items / Show Selected · Delete, and
/// Unhide in the ··· menu.
struct HiddenAlbumScreen: View {
    let session: LibrarySession
    let shellUI: LibraryUIState
    let bottomInset: CGFloat
    @State private var model: HiddenAlbumModel?
    @State private var pin = ""
    @State private var ui = LibraryUIState()
    @State private var error: String?

    private var vault: HiddenVault { session.hiddenVault }

    var body: some View {
        content
            .navigationTitle(vault.state == .unlocked ? "" : String(localized: "Hidden"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if vault.state != .unlocked { await vault.unlock() }
            }
            .onChange(of: vault.state) { _, state in
                if state == .unlocked, model == nil { model = HiddenAlbumModel(session: session) }
                if state != .unlocked { model = nil }
            }
            .onAppear {
                if vault.state == .unlocked, model == nil { model = HiddenAlbumModel(session: session) }
            }
            .onChange(of: ui.isSelecting) { _, selecting in shellUI.hidesFloatingBar = selecting }
            .onDisappear {
                shellUI.hidesFloatingBar = false
                ui.endSelecting()
                Task { await vault.lock() }
            }
            .sheet(item: $ui.pendingSheet) { sheet in
                if case .showSelected = sheet {
                    ShowSelectedSheet(session: session, ui: ui, items: (model?.snapshot.items ?? []).filter { ui.isSelected($0.id) })
                }
            }
            .confirmationDialog("", isPresented: Binding(get: { ui.pendingConfirmation == .delete }, set: { if !$0 { ui.pendingConfirmation = nil } }), titleVisibility: .hidden) {
                let ids = ui.selection
                Button(ids.count == 1 ? String(localized: "Delete Item") : String(localized: "Delete \(ids.count.formatted()) Items"), role: .destructive) {
                    act { try await session.moveToTrash(assetIDs: ids) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These items will be deleted from Cloud, and from this iPhone where they are on it. You can recover them from Recently Deleted for \(session.trashRetentionDays) days.")
            }
            .alert("Couldn't Finish", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch vault.state {
        case .unlocked:
            if let model {
                CollectionGridScreen(
                    title: String(localized: "Hidden"), items: model.snapshot.items, session: session,
                    bottomInset: ui.isSelecting ? 96 : bottomInset, isLoading: !model.snapshot.isLoaded,
                    emptyMessage: String(localized: "Photos and videos you hide appear here. Hide them from the ••• menu in a photo."),
                    ui: ui, mode: .hidden
                )
                .toolbar { toolbar }
                .overlay(alignment: .bottom) {
                    if ui.isSelecting {
                        SelectionFooter(ui: ui) { ui.shareRequested = true }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: ui.isSelecting)
            } else {
                ProgressView()
            }
        case .needsExistingPin:
            existingPinForm
        case .needsNewPin:
            newPinForm
        case .locked, .unlocking:
            lockedView
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let items = model?.snapshot.items, !items.isEmpty {
            if ui.isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            let ids = ui.selection
                            act { try await session.unhide(assetIDs: ids) }
                        } label: {
                            Label("Unhide", systemImage: "eye")
                        }
                        .disabled(ui.selection.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
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
                    Button("Select") { withAnimation(.snappy) { ui.isSelecting = true } }
                }
            }
        }
    }

    private func act(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                withAnimation(.snappy) { ui.endSelecting() }
            } catch is CancellationError {
            } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Hidden Album Is Locked")
                .font(.title2.weight(.semibold))
            Text("Use Face ID to view this album.")
                .foregroundStyle(.secondary)
            if let error = vault.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button("View Album") {
                Task { await vault.unlock() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vault.state == .unlocking)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var newPin = ""
    @State private var confirmPin = ""

    private var newPinForm: some View {
        Form {
            Section {
                SecureField("New PIN", text: $newPin)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
                SecureField("Confirm PIN", text: $confirmPin)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
                Button("Set Up Hidden") {
                    Task {
                        if await vault.createPin(newPin) {
                            newPin = ""
                            confirmPin = ""
                        }
                    }
                }
                .disabled(!HiddenVault.isValidPin(newPin) || newPin != confirmPin)
            } header: {
                Text("Choose Your PIN")
            } footer: {
                Text("Hidden uses your Cloud’s Locked Folder, which needs a 6-digit PIN. You can use the same digits as your iPhone passcode — iOS never shares the passcode itself with apps. You enter it once; after that, Face ID unlocks Hidden here. The Cloud web app asks for this PIN.")
            }
            if let error = vault.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private var existingPinForm: some View {
        Form {
            Section {
                SecureField("Cloud PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Continue") {
                    Task {
                        if await vault.submitExistingPin(pin) { pin = "" }
                    }
                }
                .disabled(pin.count < 4)
            } header: {
                Text("Enter Your Cloud PIN Once")
            } footer: {
                Text("Hidden uses your Cloud’s Locked Folder, and your Cloud account already has a PIN for it. Enter it once here; after that, Face ID unlocks Hidden on this iPhone.")
            }
            if let error = vault.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
    }
}

/// Keeps the Hidden grid in step with the database while unlocked.
@MainActor
@Observable
final class HiddenAlbumModel {
    private(set) var snapshot = TimelineSnapshot()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: LibrarySession) {
        let observation = session.observeHidden()
        task = Task { [weak self] in
            do {
                for try await items in observation {
                    guard let self else { return }
                    self.snapshot = TimelineSnapshot(items: items, version: self.snapshot.version + 1, isLoaded: true)
                }
            } catch {}
        }
    }

    deinit {
        task?.cancel()
    }
}
