import CloudCore
import Library
import Persistence
import SwiftUI

/// Account › Cloud › Free Up Space: choose what may go (taken before a date, photos and/or
/// videos, favourites and some albums kept), review what's safely in the Cloud, then remove
/// it from this iPhone. iOS asks to confirm the deletion itself.
struct FreeUpSpaceView: View {
    let session: LibrarySession
    @AppStorage("freeUp.cutoffDays") private var cutoffDays = 30
    @AppStorage("freeUp.keepFavourites") private var keepFavourites = true
    @AppStorage("freeUp.media") private var media = FreeUpOptions.Media.all.rawValue
    @AppStorage("freeUp.keepAlbums") private var keepAlbumsText = ""
    @AppStorage("freeUp.keepAlbumsChosen") private var keepAlbumsChosen = false
    @State private var cutoff = Date.now
    @State private var albums: [PhoneAlbum]?
    @State private var checking = false
    @State private var review: FreeUpReview?
    @State private var error: String?
    @State private var usesICloud = false

    private var keepAlbumIDs: [String] {
        keepAlbumsText.split(separator: "\n").map(String.init)
    }

    var body: some View {
        List {
            Section {
                DatePicker("Taken On or Before", selection: $cutoff, in: ...Date.now, displayedComponents: .date)
                Picker("Include", selection: $media) {
                    Text("Photos and Videos").tag(FreeUpOptions.Media.all.rawValue)
                    Text("Photos Only").tag(FreeUpOptions.Media.photos.rawValue)
                    Text("Videos Only").tag(FreeUpOptions.Media.videos.rawValue)
                }
                Toggle("Keep Favourites", isOn: $keepFavourites)
                NavigationLink {
                    KeepAlbumsView(albums: albums, selected: Binding(
                        get: { Set(keepAlbumIDs) },
                        set: { keepAlbumsText = $0.sorted().joined(separator: "\n"); keepAlbumsChosen = true }
                    ))
                } label: {
                    LabeledContent("Keep Albums", value: keepAlbumIDs.isEmpty ? String(localized: "None") : keepAlbumIDs.count.formatted())
                }
            } footer: {
                Text("Removes photos and videos from this iPhone that are safely backed up to Cloud. They stay in your Library and open from Cloud. Only items in your own Cloud library and not in its Recently Deleted are removed, and each one is checked with the server first.")
            }

            Section {
                Button {
                    startReview()
                } label: {
                    HStack {
                        Text(checking ? "Checking with Cloud…" : "Review Items to Remove")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking || session.connection == nil)
            } footer: {
                if session.connection == nil {
                    Text("Cloud must be reachable to check that each item is backed up.")
                }
            }

            Section {
                Label {
                    Text(usesICloud
                         ? "iCloud Photos is on for this iPhone: removing items here also removes them from iCloud and your other devices. They're still in Cloud."
                         : "If iCloud Photos is on, removing items here also removes them from iCloud and your other devices. They're still in Cloud.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.subheadline)
            }
        }
        .navigationTitle("Free Up Space")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            cutoff = Calendar.current.date(byAdding: .day, value: -cutoffDays, to: .now) ?? .now
            usesICloud = (try? await session.database.reader.read { db in try FreeUpSpace.phoneUsesICloud(in: db) }) ?? false
            let loaded = await session.phoneAlbumsForKeeping()
            albums = loaded
            if !keepAlbumsChosen {
                keepAlbumsText = loaded.filter { FreeUpPhone.isMessagingAlbum($0.title) }.map(\.id).sorted().joined(separator: "\n")
            }
        }
        .onChange(of: cutoff) { _, date in
            cutoffDays = max(0, Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0)
        }
        .navigationDestination(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review { FreeUpReviewView(session: session, review: review, usesICloud: usesICloud) }
        }
        .alert("Free Up Space", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func startReview() {
        checking = true
        // Through the end of the chosen day.
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: cutoff)) ?? cutoff
        let options = FreeUpOptions(cutoff: end, keepFavourites: keepFavourites, media: FreeUpOptions.Media(rawValue: media) ?? .all)
        Task {
            defer { checking = false }
            do {
                review = try await session.reviewFreeUpSpace(options: options, keepAlbumIDs: keepAlbumIDs)
            } catch {
                self.error = CloudError.wrap(error, operation: "Free Up Space").message
            }
        }
    }
}

private struct KeepAlbumsView: View {
    let albums: [PhoneAlbum]?
    @Binding var selected: Set<String>

    var body: some View {
        List {
            if let albums {
                if albums.isEmpty {
                    Text("No albums on this iPhone.").foregroundStyle(.secondary)
                }
                Section {
                    ForEach(albums) { album in
                        Button {
                            if selected.contains(album.id) { selected.remove(album.id) } else { selected.insert(album.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(album.title).foregroundStyle(.primary)
                                    Text(album.count == 1 ? String(localized: "1 item") : String(localized: "\(album.count.formatted()) items"))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected.contains(album.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                        }
                        .accessibilityAddTraits(selected.contains(album.id) ? .isSelected : [])
                    }
                } footer: {
                    Text("Photos in these albums always stay on this iPhone. Messaging apps' albums are kept unless you change it.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Keep Albums")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What would be removed: the count and size, the items, and the button that asks iOS to delete them.
private struct FreeUpReviewView: View {
    let session: LibrarySession
    let review: FreeUpReview
    let usesICloud: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var removed: Int?
    @State private var error: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(review.items.count == 1 ? String(localized: "1 Item") : String(localized: "\(review.items.count.formatted()) Items"))
                        .font(.title2.bold())
                    Text(ByteCountFormatter.string(fromByteCount: review.bytes, countStyle: .file))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if review.notConfirmed > 0 || review.inKeptAlbums > 0 {
                        Text(keptText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal)
                .accessibilityElement(children: .combine)

                if review.items.isEmpty {
                    ContentUnavailableView("Nothing to Remove", systemImage: "checkmark.circle",
                                           description: Text("No items match, or none are confirmed in Cloud yet."))
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(review.items) { item in
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    PipelineImage(assetID: item.remoteID, thumbhash: item.thumbhash, pipeline: session.pipeline, pixelSize: 200, size: .thumbnail)
                                }
                                .clipped()
                                .accessibilityLabel(item.isVideo ? "Video" : "Photo")
                        }
                    }
                }
            }
            .padding(.bottom, 120)
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !review.items.isEmpty {
                VStack(spacing: 8) {
                    Button(role: .destructive) {
                        remove()
                    } label: {
                        Group {
                            if deleting { ProgressView() } else { Text("Remove from This iPhone") }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(deleting)
                    Text(usesICloud ? "Also removes them from iCloud and your other devices." : "iOS keeps them in its Recently Deleted album for 30 days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.bar)
            }
        }
        .alert(removedTitle, isPresented: Binding(get: { removed != nil }, set: { if !$0 { removed = nil; dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("They're still in your Library from Cloud. To free the space straight away, empty Recently Deleted in the iPhone's photo library.")
        }
        .alert("Free Up Space", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var keptText: String {
        var parts: [String] = []
        if review.inKeptAlbums > 0 { parts.append(String(localized: "\(review.inKeptAlbums.formatted()) kept in your chosen albums")) }
        if review.notConfirmed > 0 { parts.append(String(localized: "\(review.notConfirmed.formatted()) kept because Cloud couldn't confirm them yet")) }
        return parts.joined(separator: "\n")
    }

    private var removedTitle: String {
        removed == 1 ? String(localized: "Removed 1 Item") : String(localized: "Removed \((removed ?? 0).formatted()) Items")
    }

    private func remove() {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                removed = try await session.freeUpSpace(review)
            } catch is CancellationError {
                // Declined in iOS's prompt: nothing was deleted.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
