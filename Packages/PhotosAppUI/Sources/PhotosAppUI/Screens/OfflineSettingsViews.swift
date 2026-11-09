import CloudCore
import SwiftUI

/// Cloud Server Settings › Offline: every thumbnail, and the originals of favourites and
/// chosen albums, kept on this iPhone so the Library and those photos work without a connection.
struct OfflineSettingsSection: View {
    let session: LibrarySession
    @State private var allThumbnails = OfflineSettings.downloadsAllThumbnails
    @State private var favourites = OfflineSettings.keepsFavourites
    @State private var albumIDs = OfflineSettings.albumIDs
    @State private var usage: (bytes: Int, items: Int)?

    private var work: OfflineWork { session.offlineWork }

    var body: some View {
        Section {
            Toggle("Download All Thumbnails", isOn: $allThumbnails)
            if allThumbnails, let count = work.thumbnails, count.total > 0 {
                progressRow(count, done: String(localized: "All \(count.total.formatted()) on this iPhone"))
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("Fetches the thumbnail of every photo and video in Cloud, so the whole Library can be browsed without a connection. Thumbnails, once on this iPhone, stay. Runs on Wi-Fi, and in the background while charging.")
        }
        .onChange(of: allThumbnails) { _, on in
            OfflineSettings.downloadsAllThumbnails = on
            session.restartOfflineWork()
        }

        Section {
            Toggle("Favourites", isOn: $favourites)
            NavigationLink {
                KeepOfflineAlbumsView(session: session, selected: $albumIDs)
            } label: {
                LabeledContent("Albums", value: albumIDs.isEmpty ? String(localized: "None") : albumIDs.count.formatted())
            }
            if let count = work.originals, count.total > 0 {
                progressRow(count, done: String(localized: "All \(count.total.formatted()) kept"))
            }
            if let usage, usage.items > 0 {
                LabeledContent("Kept on This iPhone", value: "\(usage.items.formatted()) · \(Formatting.bytes(usage.bytes))")
            }
            if let reason = work.waitingReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Keep Offline")
        } footer: {
            Text("The full-quality originals of these photos and videos stay on this iPhone, so they open, play and share without a connection. Items already on this iPhone aren't downloaded again. Downloads run on Wi-Fi.")
        }
        .onChange(of: favourites) { _, on in
            OfflineSettings.keepsFavourites = on
            session.restartOfflineWork()
        }
        .onChange(of: albumIDs) { _, ids in
            OfflineSettings.albumIDs = ids
            session.restartOfflineWork()
        }
        .task {
            session.runOfflineWork()
            while !Task.isCancelled {
                usage = await session.offlineUsage()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func progressRow(_ count: OfflineWork.Count, done: String) -> some View {
        if count.done >= count.total {
            Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(count.done.formatted()) of \(count.total.formatted())").font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(count.done), total: Double(max(count.total, 1)))
            }
        }
    }
}

/// The Cloud albums whose originals stay on this iPhone.
private struct KeepOfflineAlbumsView: View {
    let session: LibrarySession
    @Binding var selected: [String]
    @State private var albums: [CloudAlbum]?

    var body: some View {
        List {
            if let albums {
                if albums.isEmpty {
                    Text(session.connection == nil ? "Connect to Cloud to choose albums." : "No albums yet.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(albums) { album in
                        let isOn = selected.contains(album.id)
                        Button {
                            if isOn { selected.removeAll { $0 == album.id } } else { selected.append(album.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(album.name).foregroundStyle(.primary)
                                    Text(album.assetCount == 1 ? String(localized: "1 item") : String(localized: "\(album.assetCount.formatted()) items"))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isOn { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                            }
                        }
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                } footer: {
                    Text("Shared albums count too. Videos can be large: check the album sizes before choosing.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Keep Albums Offline")
        .navigationBarTitleDisplayMode(.inline)
        .task { albums = await session.albumsForOffline() }
    }
}
