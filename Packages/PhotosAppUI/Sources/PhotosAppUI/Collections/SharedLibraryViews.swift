import CloudCore
import Persistence
import SwiftUI

/// Account › Sharing › Partner Sharing (the Cloud server's whole-library sharing; shared
/// albums are the way to share chosen photos).
/// Libraries others share with you, each with "Show in Library", and the people you share
/// your own library with.
struct SharedLibraryView: View {
    let session: LibrarySession
    @State private var libraries: LibrarySession.SharedLibraries = ([], [])
    @State private var choosingPerson = false
    @State private var stopping: LibraryRecipient?
    @State private var busy: Set<String> = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if libraries.sharedWithMe.isEmpty {
                    Text("No one shares their library with you.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraries.sharedWithMe) { library in
                        NavigationLink {
                            SharedLibraryScreen(library: library, session: session)
                        } label: {
                            PersonRow(name: library.name, detail: Self.count(library.itemCount))
                        }
                        Toggle("Show in Library", isOn: Binding(
                            get: { library.inTimeline },
                            set: { shown in setShown(shown, library) }
                        ))
                        .disabled(busy.contains(library.id))
                    }
                }
            } header: {
                Text("Shared with You")
            } footer: {
                Text("A partner's whole library, shared with you. It only shows in your Library if you turn on Show in Library. Their photos stay in their account: you can view, share and save them, but only they can change or delete them.")
            }

            Section {
                ForEach(libraries.recipients) { person in
                    PersonRow(name: person.name, detail: person.email)
                    Button("Stop Sharing with \(Self.displayName(person.name, person.email))", role: .destructive) { stopping = person }
                }
                Button {
                    choosingPerson = true
                } label: {
                    Label("Share My Whole Library…", systemImage: "person.crop.circle.badge.plus")
                }
            } header: {
                Text("Your Library Is Shared With")
            } footer: {
                Text("Partner sharing shares your whole library: everyone listed sees all your photos and videos, except those in Hidden, Archive and Recently Deleted. To share only some photos, use a shared album instead (··· › Add To › Shared Album).")
            }
        }
        .navigationTitle("Partner Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            libraries = session.sharedLibrariesNow()
            do {
                for try await value in session.observeSharedLibraries() { libraries = value }
            } catch {}
        }
        .refreshable { session.syncNow() }
        .sheet(isPresented: $choosingPerson) {
            SharePersonPicker(session: session, excluded: Set(libraries.recipients.map(\.id))) { message in
                error = message
            }
        }
        .confirmationDialog(
            stopping.map { String(localized: "Stop sharing your library with \(Self.displayName($0.name, $0.email))?") } ?? "",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { person in
            Button("Stop Sharing", role: .destructive) { stop(person) }
        } message: { _ in
            Text("Your photos will no longer appear on their devices.")
        }
        .alert("Partner Sharing", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func setShown(_ shown: Bool, _ library: SharedLibrary) {
        busy.insert(library.id)
        Task {
            defer { busy.remove(library.id) }
            do {
                try await session.showSharedLibraryInLibrary(shown, partnerID: library.id)
            } catch {
                self.error = CloudError.wrap(error, operation: "Partner Sharing").message
            }
        }
    }

    private func stop(_ person: LibraryRecipient) {
        Task {
            do {
                try await session.stopSharingLibrary(with: person.id)
            } catch {
                self.error = CloudError.wrap(error, operation: "Stop sharing").message
            }
        }
    }

    static func count(_ n: Int) -> String {
        n == 1 ? String(localized: "1 Item") : String(localized: "\(n.formatted()) Items")
    }

    static func displayName(_ name: String, _ email: String) -> String {
        name.isEmpty ? email : name
    }
}

/// A name with a round initial, and one line under it.
private struct PersonRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.gray.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? detail : name)
                if !name.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Share My Whole Library: pick someone on the server, then confirm.
private struct SharePersonPicker: View {
    let session: LibrarySession
    let excluded: Set<String>
    let onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [CloudUser]?
    @State private var chosen: CloudUser?
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            Group {
                if let people {
                    let available = people.filter { !excluded.contains($0.id) }
                    if available.isEmpty {
                        ContentUnavailableView(
                            "No One to Add",
                            systemImage: "person.2",
                            description: Text(people.isEmpty ? "There's no one else on your Cloud server yet." : "Your library is already shared with everyone on your Cloud server.")
                        )
                    } else {
                        List(available) { person in
                            Button {
                                chosen = person
                            } label: {
                                PersonRow(name: person.name, detail: person.email)
                            }
                            .tint(.primary)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Share My Whole Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(sharing)
            .overlay { if sharing { ProgressView() } }
            .task { people = await session.peopleOnServer() }
            .confirmationDialog(
                chosen.map { String(localized: "Share your whole library with \(SharedLibraryView.displayName($0.name, $0.email))?") } ?? "",
                isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                titleVisibility: .visible,
                presenting: chosen
            ) { person in
                Button("Share Whole Library") { share(with: person) }
            } message: { _ in
                Text("They'll see your whole library: all your photos and videos, except those in Hidden, Archive and Recently Deleted.")
            }
        }
    }

    private func share(with person: CloudUser) {
        sharing = true
        Task {
            defer { sharing = false }
            do {
                try await session.shareLibrary(with: person.id)
                dismiss()
            } catch {
                dismiss()
                onError(CloudError.wrap(error, operation: "Share library").message)
            }
        }
    }
}

/// A library someone shares with you, as an album-style grid.
struct SharedLibraryScreen: View {
    let library: SharedLibrary
    let session: LibrarySession
    var bottomInset: CGFloat = 0
    @State private var items: [TimelineItem]?

    var body: some View {
        CollectionGridScreen(
            title: SharedLibraryView.displayName(library.name, library.email),
            subtitle: SharedLibraryView.count(items?.count ?? library.itemCount),
            items: items ?? [],
            session: session,
            bottomInset: bottomInset,
            isLoading: items == nil,
            emptyMessage: String(localized: "Nothing shared yet. Photos appear here after the next sync.")
        )
        .task {
            do {
                for try await value in session.observeSharedLibrary(of: library.id) { items = value }
            } catch {}
        }
    }
}
