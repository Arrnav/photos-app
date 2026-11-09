import Backup
import Library
import Persistence
import SwiftUI

/// Account › Back Up This iPhone: status (total, backed up, remaining, current item,
/// last backup, problems in plain words) and the settings.
struct BackupView: View {
    let session: LibrarySession
    @State private var albums: [PhoneAlbum] = []
    @State private var selection: [String: Bool] = [:]

    private var status: BackupStatus { session.backupStatus }

    var body: some View {
        List {
            Section {
                summary
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                Toggle("Back Up This iPhone", isOn: Binding(get: { session.backupSettings.isEnabled }, set: { session.backupSettings.isEnabled = $0 }))
                    .disabled(!LocalLibrary.canRead)
                if session.backupSettings.isEnabled {
                    Toggle("Pause", isOn: Binding(get: { session.backupSettings.isPaused }, set: { session.backupSettings.isPaused = $0 }))
                }
            } footer: {
                Text(LocalLibrary.canRead
                     ? "Photos and videos on this iPhone are uploaded to Cloud in their original quality. Nothing is uploaded twice. Uploads continue in the background."
                     : "Allow Photos access (Settings › This iPhone) to back up.")
            }

            Section {
                NavigationLink {
                    BackupAlbumsView(session: session, albums: $albums, selection: $selection)
                } label: {
                    LabeledContent("Back Up From", value: scopeSummary)
                }
            }

            Section {
                Toggle("Use Mobile Data", isOn: Binding(get: { session.backupSettings.allowsMobileData }, set: { session.backupSettings.allowsMobileData = $0 }))
                Toggle("Only While Charging", isOn: Binding(get: { session.backupSettings.onlyWhileCharging }, set: { session.backupSettings.onlyWhileCharging = $0 }))
            } header: {
                Text("Network and Power")
            }

            Section {
                Toggle("Download Originals from iCloud", isOn: Binding(get: { session.backupSettings.downloadsFromICloud }, set: { session.backupSettings.downloadsFromICloud = $0 }))
                if session.backupSettings.downloadsFromICloud {
                    Toggle("Only on Wi-Fi", isOn: Binding(get: { session.backupSettings.iCloudDownloadsOnWiFiOnly }, set: { session.backupSettings.iCloudDownloadsOnWiFiOnly = $0 }))
                }
            } header: {
                Text("iCloud Photos")
            } footer: {
                Text("With Optimise iPhone Storage, some originals are only in iCloud. They're downloaded just to be uploaded, then the copy is deleted. Turn this off to skip them.")
            }

            Section {
                Stepper(value: Binding(
                    get: { session.backupSettings.tempBudgetBytes / (1024 * 1024 * 1024) },
                    set: { session.backupSettings.tempBudgetBytes = $0 * 1024 * 1024 * 1024 }
                ), in: 1...20) {
                    LabeledContent("Temporary Space", value: "\(session.backupSettings.tempBudgetBytes / (1024 * 1024 * 1024)) GB")
                }
            } footer: {
                Text("Each upload is prepared as a file first. At most this much space is used at once; each file is deleted as soon as its upload finishes.")
            }

            if !status.problems.isEmpty {
                Section {
                    ForEach(status.problems.prefix(20), id: \.self) { problem in
                        Text(problem).font(.footnote)
                    }
                    Button("Try Again Now") { session.retryFailedBackups() }
                } header: {
                    Text("Problems")
                }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await session.refreshBackupStatus()
            selection = await session.backupAlbumSelection()
            albums = await Task.detached { LocalLibrary.albums() }.value
        }
        .refreshable { await session.refreshBackupStatus() }
    }

    private var scopeSummary: String {
        let included = selection.filter(\.value).count
        let excluded = selection.filter { !$0.value }.count
        switch (included, excluded) {
        case (0, 0): return String(localized: "All Photos")
        case (0, _): return String(localized: "All Photos, \(excluded) Excluded")
        default: return included == 1 ? String(localized: "1 Album") : String(localized: "\(included) Albums")
        }
    }

    private var summary: some View {
        let counts = status.counts
        let fraction = counts.fraction
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: activitySymbol)
                    .foregroundStyle(activityColor)
                Text(activityTitle).font(.headline)
            }
            ProgressView(value: fraction)
                .tint(activityColor)
            Text("\(counts.backedUp.formatted()) of \(counts.total.formatted()) backed up · \(counts.remaining.formatted()) remaining")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if counts.halfDone > 0 {
                Text("\(counts.halfDone.formatted()) Live Photos halfway (video uploaded)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let name = status.currentFileName, status.activity == .working {
                HStack {
                    Text(name).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let progress = status.currentProgress {
                        Text(progress, format: .percent.precision(.fractionLength(0))).font(.footnote.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
            }
            if let last = counts.lastSuccess {
                Text("Last upload \(last.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var activityTitle: String {
        switch status.activity {
        case .off: String(localized: "Backup Is Off")
        case .paused: String(localized: "Paused")
        case .idle: status.counts.remaining == 0 ? String(localized: "Backed Up") : String(localized: "Waiting to Back Up")
        case .working: String(localized: "Backing Up \(status.counts.remaining.formatted()) Items")
        case .waitingForWiFi: String(localized: "Waiting for Wi-Fi")
        case .waitingForPower: String(localized: "Waiting for Power")
        case .offline: String(localized: "Cloud Not Reachable")
        case .needsSignIn: String(localized: "Sign In Again to Back Up")
        }
    }

    private var activitySymbol: String {
        switch status.activity {
        case .off, .paused: "pause.circle"
        case .idle: status.counts.remaining == 0 ? "checkmark.icloud" : "icloud"
        case .working: "arrow.up.circle"
        case .waitingForWiFi: "wifi"
        case .waitingForPower: "bolt"
        case .offline: "icloud.slash"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        }
    }

    private var activityColor: Color {
        switch status.activity {
        case .offline, .needsSignIn: .orange
        case .off, .paused: .secondary
        default: .accentColor
        }
    }
}

/// Which albums to back up: everything (default), chosen albums, and albums to skip (e.g. WhatsApp).
private struct BackupAlbumsView: View {
    let session: LibrarySession
    @Binding var albums: [PhoneAlbum]
    @Binding var selection: [String: Bool]

    var body: some View {
        List {
            Section {
                ForEach(albums) { album in
                    Menu {
                        Button { set(album, nil) } label: { Label("Default", systemImage: selection[album.id] == nil ? "checkmark" : "") }
                        Button { set(album, "include") } label: { Label("Back Up", systemImage: selection[album.id] == true ? "checkmark" : "") }
                        Button(role: .destructive) { set(album, "exclude") } label: { Label("Don't Back Up", systemImage: selection[album.id] == false ? "checkmark" : "") }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(album.title).foregroundStyle(.primary)
                                Text(album.count.formatted()).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            switch selection[album.id] {
                            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            case false?: Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            case nil: EmptyView()
                            }
                        }
                    }
                }
            } footer: {
                Text("By default everything on this iPhone is backed up. Choose albums to back up only those, or mark albums not to back up (they win if a photo is in both).")
            }
        }
        .navigationTitle("Back Up From")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ album: PhoneAlbum, _ mode: String?) {
        switch mode {
        case "include": selection[album.id] = true
        case "exclude": selection[album.id] = false
        default: selection[album.id] = nil
        }
        Task { await session.setBackupAlbum(album, mode: mode) }
    }
}
