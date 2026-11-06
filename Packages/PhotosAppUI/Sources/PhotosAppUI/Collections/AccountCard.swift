import Core
import CloudCore
import Persistence
import PhotosUI
import SwiftUI

/// Settings keys shared with the viewer.
enum PhotosSettings {
    static let fullHDR = "viewer.fullHDR"
    static let zoomToFill = "viewer.zoomToFill"
    static let autoPlayMotion = "viewer.autoPlayMotion"
    static let loopVideos = "viewer.loopVideos"
    static let sharedAlbumActivity = "notifications.sharedAlbumActivity"
    static let syncImmediately = "sync.immediately"
    static let showRatings = "viewer.showRatings"
    static let showFeatured = "collections.showFeatured"
    static let showHolidays = "collections.showHolidays"
    static let showTileStatus = "grid.showTileStatus"

    /// Defaults: on, except ratings and Sync Immediately.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            fullHDR: true, zoomToFill: true, autoPlayMotion: true, loopVideos: true,
            sharedAlbumActivity: true, syncImmediately: false, showRatings: false,
            showFeatured: true, showHolidays: true, showTileStatus: true,
        ])
    }
}

/// The account card (Collections › profile picture): the
/// picture and name, library counts, the Cloud status card, Shared with You, the
/// library options, then this app's own settings at the bottom.
struct AccountCard: View {
    let model: AppModel
    let session: LibrarySession
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @AppStorage(PhotosSettings.sharedAlbumActivity) private var sharedAlbumActivity = true
    @AppStorage(PhotosSettings.syncImmediately) private var syncImmediately = false
    @AppStorage(PhotosSettings.autoPlayMotion) private var autoPlayMotion = true
    @AppStorage(PhotosSettings.loopVideos) private var loopVideos = true
    @AppStorage(PhotosSettings.fullHDR) private var fullHDR = true
    @AppStorage(PhotosSettings.zoomToFill) private var zoomToFill = true
    @AppStorage(PhotosSettings.showRatings) private var showRatings = false
    @AppStorage(PhotosSettings.showFeatured) private var showFeatured = true
    @AppStorage(PhotosSettings.showHolidays) private var showHolidays = true
    @State private var resetDone: String?
    @State private var choosingPhoto = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            List {
                profile
                statusCard
                sharedWithYou

                Section("In-App Notifications") {
                    Toggle("Shared Album Activity", isOn: $sharedAlbumActivity)
                }
                Section("Cloud") {
                    NavigationLink {
                        BackupView(session: session)
                    } label: {
                        LabeledContent("Back Up This iPhone", value: session.backupSettings.isEnabled ? String(localized: "On") : String(localized: "Off"))
                    }
                    NavigationLink {
                        SyncImmediatelyView(isOn: $syncImmediately)
                    } label: {
                        LabeledContent("Sync Immediately", value: syncImmediately ? String(localized: "On") : String(localized: "Off"))
                    }
                }
                Section("View Options") {
                    Toggle("Auto-Play Motion", isOn: $autoPlayMotion)
                    Toggle("Loop Videos", isOn: $loopVideos)
                }
                Section {
                    Toggle("View Full HDR", isOn: $fullHDR)
                } footer: {
                    Text("Automatically adjust the display to show the complete dynamic range (HDR) of photos.")
                }
                Section {
                    Toggle("Zoom to Fill Screen", isOn: $zoomToFill)
                } footer: {
                    Text("When viewing a photo, zoom slightly to fit the screen size.")
                }
                Section {
                    NavigationLink {
                        SharedLibraryView(session: session)
                    } label: {
                        LabeledContent("Shared Library", value: String(localized: "Set Up"))
                    }
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("Share photos and videos from moments spent together with family and close friends in one library. Uses partner sharing on your Cloud server.")
                }
                Section {
                    NavigationLink("Manage Keywords") { KeywordsView() }
                }
                Section {
                    Toggle("Show Ratings Controls", isOn: $showRatings)
                }
                Section {
                    Toggle("Show Featured Content", isOn: $showFeatured)
                } header: {
                    Text("Featured")
                } footer: {
                    Text("Allow Featured Photos and Memories to automatically appear on this device.")
                }
                Section {
                    Toggle("Show Holiday Events", isOn: $showHolidays)
                } footer: {
                    Text("Allow recent holiday events for your home country or region to automatically appear on this device.")
                }
                Section {
                    Button("Reset Suggested Memories") { resetDone = String(localized: "Suggested memories were reset.") }
                    Button("Reset People & Pets Suggestions") { resetDone = String(localized: "People & Pets suggestions were reset.") }
                } footer: {
                    Text("You can choose to reset previously blocked Memories or People and Pets in order for them to appear in new Memories and Featured Photos.")
                }

                Section {
                    NavigationLink("Cloud Server Settings") { CloudServerSettingsView(model: model) }
                } footer: {
                    Text("Server addresses, accounts, sync, storage and diagnostics for your Cloud server.")
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .alert(resetDone ?? "", isPresented: Binding(get: { resetDone != nil }, set: { if !$0 { resetDone = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
        .task(id: session.profileImageVersion) {
            await session.refreshBackupStatus()
            image = await session.profileImage()
            if let fresh = await session.profileImage(refresh: true) { image = fresh }
        }
    }

    /// Shows the new picture at once and sets it as the Cloud profile picture.
    private func useProfileImage(_ picked: UIImage) {
        image = picked
        Task {
            do {
                try await session.setProfileImage(picked)
            } catch {
                resetDone = String(localized: "The picture is shown on this iPhone, but couldn't be saved to Cloud: \(CloudError.message(for: error))")
            }
        }
    }

    // MARK: Top

    private var profile: some View {
        Section {
            VStack(spacing: 6) {
                Menu {
                    Button { ContactPhotoPicker.present { picked in if let picked { useProfileImage(picked) } } } label: {
                        Label("Use My Contact Photo", systemImage: "person.crop.circle")
                    }
                    Button { choosingPhoto = true } label: {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    ProfileImageView(image: image, name: session.account.name, size: 84)
                        .overlay(alignment: .bottomTrailing) {
                            if image == nil {
                                Image(systemName: "plus.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .blue)
                                    .font(.title3)
                            }
                        }
                }
                .accessibilityLabel("Account Picture")
                .padding(.bottom, 8)
                .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self), let picked = UIImage(data: data) {
                            useProfileImage(picked)
                        }
                    }
                }
                Text(session.account.name)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(countsText)
                    .font(.headline)
                    .padding(.top, 10)
                Text(statusLine)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
        }
    }

    private var countsText: String {
        let items = session.timeline.items
        let videos = items.filter(\.isVideo).count
        let photos = items.count - videos
        return String(localized: "\(photos.formatted()) Photos, \(videos.formatted()) Videos")
    }

    private var statusLine: String {
        if model.isSyncPaused { return String(localized: "Syncing with Cloud Paused") }
        let backup = session.backupStatus
        if session.backupSettings.isEnabled, backup.counts.remaining > 0 {
            return backup.activity == .working
                ? String(localized: "Backing Up \(backup.counts.remaining.formatted()) Items to Cloud")
                : String(localized: "\(backup.counts.remaining.formatted()) Items Not Backed Up to Cloud")
        }
        switch session.syncStatus {
        case .syncing: return String(localized: "Syncing with Cloud…")
        case .upToDate(let date): return String(localized: "Synced with Cloud \(date.formatted(.relative(presentation: .named)))")
        case .failed: return String(localized: "Couldn't Sync with Cloud")
        case .idle: return String(localized: "Connecting to Cloud…")
        }
    }

    /// The storage card; here it reports the server connection.
    private var statusCard: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(LinearGradient(colors: [Color(red: 0.45, green: 0.75, blue: 1), Color(red: 0.2, green: 0.55, blue: 0.95)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 52, height: 52)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if hasProblem {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.red, in: Circle())
                            .offset(x: 6, y: 6)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(cardTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(cardMessage)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(cardAction) {
                        if session.needsSignIn { dismiss() } else if model.isSyncPaused { model.reconnect() } else { session.syncNow() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var hasProblem: Bool { model.isSyncPaused || session.needsSignIn }

    private var cardTitle: String {
        if session.needsSignIn { return String(localized: "SIGN IN REQUIRED") }
        if model.isSyncPaused { return String(localized: "CLOUD NOT REACHABLE") }
        if case .connected(let server) = model.connection {
            return server.route == .local ? String(localized: "CLOUD · HOME NETWORK") : String(localized: "CLOUD · AWAY (TAILSCALE)")
        }
        return String(localized: "CLOUD")
    }

    private var cardMessage: String {
        if session.needsSignIn { return String(localized: "Your server no longer accepts this sign-in. Sign in again below to resume syncing.") }
        if model.isSyncPaused { return String(localized: "Your Cloud server can't be reached. New or changed photos will sync when it's back.") }
        return String(localized: "Your library is kept in sync with your Cloud server.")
    }

    private var cardAction: String {
        if session.needsSignIn { return String(localized: "Sign In Again") }
        if model.isSyncPaused { return String(localized: "Check Connection") }
        return String(localized: "Sync Now")
    }

    @ViewBuilder
    private var sharedWithYou: some View {
        let shared = Array(session.timeline.items.filter { $0.ownerID != session.account.userID }.suffix(2).reversed())
        Section {
            if shared.isEmpty {
                Text("Photos your partner shares with you appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    ForEach(shared) { item in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { PipelineImage(item: item, pipeline: session.pipeline, pixelSize: 500) }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.vertical, 6)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Shared with You")
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
        }
    }
}

/// Cloud › Sync Immediately.
private struct SyncImmediatelyView: View {
    @Binding var isOn: Bool

    var body: some View {
        List {
            Section {
                Toggle("Sync Immediately", isOn: $isOn)
            } footer: {
                Text("Sync with your Cloud server right away, even in Low Power Mode or on mobile data. When off, syncing waits for Wi-Fi and enough battery.")
            }
        }
        .navigationTitle("Sync Immediately")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Sharing › Shared Library: Immich partner sharing.
private struct SharedLibraryView: View {
    let session: LibrarySession

    var body: some View {
        List {
            Section {
                let users = session.otherUsers()
                if users.isEmpty {
                    Text("No other people on this server yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(users, id: \.id) { user in
                        VStack(alignment: .leading) {
                            Text(user.name)
                            Text(user.email).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("People on Your Cloud Server")
            } footer: {
                Text("A shared library uses partner sharing on your Cloud: each person's photos stay in their own account and show up in the other's Library. Turning it on here comes in a later version; until then use the Cloud web app (Account Settings › Partner Sharing).")
            }
        }
        .navigationTitle("Shared Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Manage Keywords (Immich tags).
private struct KeywordsView: View {
    var body: some View {
        ContentUnavailableView("No Keywords", systemImage: "tag", description: Text("Keywords are Cloud tags. Adding them to photos comes in a later version."))
            .navigationTitle("Manage Keywords")
            .navigationBarTitleDisplayMode(.inline)
    }
}
