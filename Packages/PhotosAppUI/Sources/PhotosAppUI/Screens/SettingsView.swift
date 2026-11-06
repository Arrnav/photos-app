import Core
import CloudCore
import SwiftUI

/// Account card › Cloud Server Settings: everything that isn't on the account card itself
/// (accounts, server, sync, storage, troubleshooting).
struct CloudServerSettingsView: View {
    let model: AppModel

    var body: some View {
        List {
            AppSettingsSections(model: model)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cloud Server Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The sections of Cloud Server Settings.
struct AppSettingsSections: View {
    let model: AppModel
    @State private var addingAccount = false
    @State private var confirmSignOut: Account?

    var body: some View {
        Group {
            accountsSection
            connectionSection
            ServerAddressSection(model: model)
            if let session = model.session {
                PhoneLibrarySection(session: session)
                BackupServerSection(session: session)
                syncSection(session)
                storageSection(session)
                HiddenSettingsSection(vault: session.hiddenVault)
                TroubleshootingSection(session: session)
            }
        }
        .sheet(isPresented: $addingAccount) {
            NavigationStack {
                SignInView(model: model, initialEmail: model.session?.needsSignIn == true ? model.accounts.activeAccount?.email ?? "" : "") {
                    addingAccount = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { addingAccount = false }
                    }
                }
            }
        }
        .confirmationDialog(
            "Sign out of \(confirmSignOut?.email ?? "")?",
            isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                if let account = confirmSignOut {
                    Task { await model.signOut(account) }
                }
            }
        } message: {
            Text("Cached thumbnails and the synced library index for this account are removed from this iPhone. Nothing is deleted on the server.")
        }
    }

    private var accountsSection: some View {
        Section("Accounts") {
            ForEach(model.accounts.accounts) { account in
                Button {
                    model.switchTo(account)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name).foregroundStyle(.primary)
                            Text(account.email).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account == model.accounts.activeAccount {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                .accessibilityLabel("Active")
                        }
                    }
                }
                .swipeActions {
                    Button("Sign Out", role: .destructive) { confirmSignOut = account }
                }
            }
            Button(model.session?.needsSignIn == true ? "Sign In Again" : "Add Account") {
                addingAccount = true
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            switch model.connection {
            case .unknown, .checking:
                LabeledContent("Status") { ProgressView() }
            case .connected(let server):
                LabeledContent("Status", value: server.route == .local ? "Home (local network)" : "Away (Tailscale)")
                LabeledContent("Address", value: server.url.absoluteString)
            case .unreachable(let reasons):
                LabeledContent("Status", value: "Not reachable")
                ForEach(reasons, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
            }
            if let info = model.serverInfo {
                LabeledContent("Cloud Version", value: info.version)
            }
            if let warning = model.versionWarning {
                Text(warning).font(.footnote).foregroundStyle(.orange)
            }
            Button("Check Again") { model.reconnect() }
        }
    }

    private func syncSection(_ session: LibrarySession) -> some View {
        Section("Library Sync") {
            switch session.syncStatus {
            case .idle:
                LabeledContent("Status", value: "Waiting for the server")
            case .syncing(let applied):
                LabeledContent("Status") {
                    HStack {
                        Text("Syncing \(applied.formatted())")
                        ProgressView()
                    }
                }
            case .upToDate(let date):
                LabeledContent("Last synced", value: date.formatted(date: .abbreviated, time: .shortened))
            case .failed(let message, let date):
                LabeledContent("Failed", value: date.formatted(date: .omitted, time: .shortened))
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            LabeledContent("Photos and videos", value: session.timeline.items.count.formatted())
            Button("Sync Now") { session.syncNow() }
        }
    }

    private func storageSection(_ session: LibrarySession) -> some View {
        CacheSettingsSection(session: session)
    }
}

/// Resync, and crash reports to share if the app ever closes unexpectedly.
struct TroubleshootingSection: View {
    let session: LibrarySession

    var body: some View {
        Section {
            let reports = CrashReports.shared.reports()
            ForEach(reports.prefix(5), id: \.self) { url in
                ShareLink(item: url) {
                    Text(CrashReports.shared.summary(of: url)).font(.footnote)
                }
            }
            Button("Resync from Scratch", role: .destructive) {
                session.resyncFromScratch()
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Resync from Scratch downloads the library list from Cloud again. Nothing is deleted, and cached thumbnails are kept.")
        }
    }
}

/// Hidden uses Immich's Locked Folder; its PIN lives behind Face ID on this phone.
struct HiddenSettingsSection: View {
    let vault: HiddenVault
    @State private var revealed: String?

    var body: some View {
        Section {
            if let revealed {
                LabeledContent("Cloud PIN", value: revealed)
                    .font(.body.monospacedDigit())
            } else {
                Button("Show Cloud PIN") {
                    Task { revealed = await vault.revealPin() }
                }
                .disabled(!vault.hasStoredPin)
            }
        } header: {
            Text("Hidden Album")
        } footer: {
            Text("Hidden is stored in your Cloud’s Locked Folder. Face ID unlocks it here; the Cloud web app asks for this PIN instead.")
        }
    }
}

/// How much space cached thumbnails and downloaded originals may use.
struct CacheSettingsSection: View {
    let session: LibrarySession
    @State private var thumbnailLimit = LibrarySession.thumbnailCacheLimitBytes
    @State private var originalsLimit = LibrarySession.originalsCacheLimitBytes
    @State private var thumbnailSize: Int?
    @State private var originalsSize: Int?

    private static let gigabyte = 1024 * 1024 * 1024
    private static let choices = [256 * 1024 * 1024, 512 * 1024 * 1024, gigabyte, 2 * gigabyte, 5 * gigabyte, 10 * gigabyte, 20 * gigabyte, 50 * gigabyte]

    var body: some View {
        Section {
            Picker("Thumbnails", selection: $thumbnailLimit) {
                ForEach(Self.choices, id: \.self) { Text(Formatting.bytes($0)).tag($0) }
            }
            LabeledContent("Used", value: thumbnailSize.map(Formatting.bytes) ?? "…")
            Button("Clear Thumbnails", role: .destructive) {
                Task {
                    await session.clearThumbnailCache()
                    await measure()
                }
            }
        } header: {
            Text("Thumbnail Cache")
        } footer: {
            Text("Thumbnails and previews from Cloud are kept so the server is asked for each one only once, and so the grid works offline. Photos on this iPhone don't use this space.")
        }
        .onChange(of: thumbnailLimit) { _, new in
            Task {
                await session.setCacheLimits(thumbnails: new)
                await measure()
            }
        }
        .task { await measure() }

        Section {
            Picker("Originals", selection: $originalsLimit) {
                ForEach(Self.choices, id: \.self) { Text(Formatting.bytes($0)).tag($0) }
            }
            LabeledContent("Used", value: originalsSize.map(Formatting.bytes) ?? "…")
            Button("Clear Downloaded Originals", role: .destructive) {
                Task {
                    await session.clearOriginalsCache()
                    await measure()
                }
            }
        } header: {
            Text("Downloaded Originals")
        } footer: {
            Text("Full-quality files from Cloud, kept after zooming in, sharing, Live Photos and video downloads. The oldest are removed first when the limit is reached.")
        }
        .onChange(of: originalsLimit) { _, new in
            Task {
                await session.setCacheLimits(originals: new)
                await measure()
            }
        }
    }

    private func measure() async {
        thumbnailSize = await session.thumbnailCacheSize()
        originalsSize = await session.originalsCacheSize()
    }
}

/// Cloud Server Settings › Backup: what to back up, and Sync Albums.
struct BackupServerSection: View {
    let session: LibrarySession

    var body: some View {
        Section {
            NavigationLink {
                BackupView(session: session)
            } label: {
                LabeledContent("Backup", value: session.backupSettings.isEnabled ? String(localized: "On") : String(localized: "Off"))
            }
            Toggle("Sync Albums", isOn: Binding(
                get: { session.backupSettings.syncsAlbums },
                set: { on in
                    session.backupSettings.syncsAlbums = on
                    if on { session.syncAlbumsIfEnabled() }
                }
            ))
            Toggle("Back Up Hidden Photos", isOn: Binding(
                get: { session.backupSettings.backsUpHidden },
                set: { session.backupSettings.backsUpHidden = $0 }
            ))
        } header: {
            Text("Backup")
        } footer: {
            Text("Sync Albums creates a Cloud album for each album you back up, with the same photos.\n\nBack Up Hidden Photos puts the iPhone's Hidden album in Hidden in Cloud.")
        }
    }
}
