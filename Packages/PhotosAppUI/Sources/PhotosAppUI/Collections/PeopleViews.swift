import CloudCore
import Contacts
import Persistence
import SwiftUI

/// A recognised person's face in a circle (from the server's face recognition).
struct PersonFaceView: View {
    let personID: String
    let session: LibrarySession
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(Circle())
            .task(id: personID) { image = await session.personFace(personID) }
            .accessibilityHidden(true)
    }
}

extension CloudPerson {
    /// The name, or "Add Name" for someone not named yet.
    var displayName: String { name.isEmpty ? String(localized: "Add Name") : name }
}

/// Named people first (alphabetically), then the rest in the server's order.
func orderedPeople(_ people: [CloudPerson]) -> [CloudPerson] {
    people.filter { !$0.name.isEmpty }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        + people.filter(\.name.isEmpty)
}

/// Collections › People: a row of faces.
struct PeopleRow: View {
    let people: [CloudPerson]
    let session: LibrarySession

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(orderedPeople(people).prefix(30)) { person in
                    NavigationLink(value: CollectionRoute.person(person)) {
                        VStack(spacing: 6) {
                            PersonFaceView(personID: person.id, session: session, size: 84)
                            Text(person.displayName)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 88)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollIndicators(.hidden)
    }
}

/// People › : everyone, three to a row.
struct PeopleScreen: View {
    let session: LibrarySession
    let initial: [CloudPerson]?
    let bottomInset: CGFloat
    @State private var people: [CloudPerson]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let people, !people.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 20) {
                    ForEach(orderedPeople(people)) { person in
                        NavigationLink(value: CollectionRoute.person(person)) {
                            VStack(spacing: 6) {
                                PersonFaceView(personID: person.id, session: session, size: 100)
                                Text(person.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset + 20)
            } else if people == nil, error == nil {
                ProgressView().padding(.top, 80)
            } else {
                ContentUnavailableView("No People", systemImage: "person.2.crop.square.stack",
                                       description: Text(error ?? String(localized: "People appear here when face recognition is turned on for your Cloud server.")))
                    .padding(.top, 60)
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if people == nil { people = initial }
            do { people = try await session.people() } catch { if people == nil { self.error = (error as? CloudError)?.message ?? error.localizedDescription } }
        }
    }
}

/// One person's photos, with naming (typed, or from a contact).
struct PersonScreen: View {
    @State var person: CloudPerson
    let session: LibrarySession
    let bottomInset: CGFloat
    @State private var items: [TimelineItem]?
    @State private var error: String?
    @State private var naming = false
    @State private var draftName = ""

    var body: some View {
        CollectionGridScreen(title: person.displayName, items: items ?? [], session: session, bottomInset: bottomInset,
                             isLoading: items == nil && error == nil, emptyMessage: error)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            draftName = person.name
                            naming = true
                        } label: { Label(person.name.isEmpty ? "Add Name" : "Rename", systemImage: "pencil") }
                        Button { nameFromContact() } label: { Label("Name from Contacts", systemImage: "person.crop.circle") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            .alert(person.name.isEmpty ? "Add Name" : "Rename", isPresented: $naming) {
                TextField("Name", text: $draftName)
                    .textContentType(.name)
                Button("Cancel", role: .cancel) {}
                Button("Done") { rename(to: draftName, birthDate: nil) }
            }
            .task {
                do { items = try await session.personItems(person.id) } catch {
                    self.error = (error as? CloudError)?.message ?? error.localizedDescription
                    items = []
                }
            }
    }

    private func rename(to name: String, birthDate: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do { person = try await session.updatePerson(id: person.id, name: trimmed, birthDate: birthDate) } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }

    /// The contact's name, and birthday when it has one with a year, go to the server; the
    /// link to the contact is remembered on this iPhone.
    private func nameFromContact() {
        let personID = person.id
        ContactPicker.present { contact in
            guard let contact else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            var birthDate: String?
            if contact.isKeyAvailable(CNContactBirthdayKey), let birthday = contact.birthday,
               let year = birthday.year, let month = birthday.month, let day = birthday.day {
                birthDate = String(format: "%04d-%02d-%02d", year, month, day)
            }
            PersonContacts.link(personID: personID, contactID: contact.identifier)
            rename(to: name, birthDate: birthDate)
        }
    }
}

/// Which contact each recognised person was named from (kept on this iPhone only; the
/// server has no field for it).
enum PersonContacts {
    private static let key = "people.contacts"

    static func link(personID: String, contactID: String) {
        var links = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        links[personID] = contactID
        UserDefaults.standard.set(links, forKey: key)
    }

    static func contactID(for personID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[personID]
    }
}
