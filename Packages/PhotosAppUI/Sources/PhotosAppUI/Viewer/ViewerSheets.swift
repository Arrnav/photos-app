import CloudCore
import MapKit
import Persistence
import SwiftUI

/// Add To › Album / Shared Album: pick an existing album.
struct AlbumPickerView: View {
    let session: LibrarySession
    let shared: Bool
    let assetIDs: [String]
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [CloudAlbum]?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Group {
                if let albums, albums.isEmpty {
                    ContentUnavailableView(shared ? "No Shared Albums" : "No Albums", systemImage: "rectangle.stack",
                                           description: Text("Use New \(shared ? "Shared " : "")Album in the menu to create one."))
                } else if let albums {
                    List(albums) { album in
                        Button {
                            add(to: album)
                        } label: {
                            HStack {
                                Label(album.name, systemImage: album.isShared ? "person.2.fill" : "rectangle.stack")
                                Spacer()
                                Text(album.assetCount.formatted()).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(working)
                    }
                } else if let error {
                    ContentUnavailableView("Couldn’t Load Albums", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(shared ? "Add to Shared Album" : "Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            let all = try await session.albums(shared: shared)
            albums = all.filter { $0.isShared == shared }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            self.error = (error as? CloudError)?.message ?? error.localizedDescription
        }
    }

    private func add(to album: CloudAlbum) {
        working = true
        Task {
            do {
                try await session.add(assetIDs: assetIDs, toAlbum: album)
                dismiss()
                onDone(String(localized: "Added to “\(album.name)”"))
            } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
                working = false
            }
        }
    }
}

/// Add To › New Album / New Shared Album.
struct NewAlbumView: View {
    let session: LibrarySession
    let shared: Bool
    let assetIDs: [String]
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var people: [UserRecord] = []
    @State private var selected: Set<String> = []
    @State private var error: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                }
                if shared {
                    Section {
                        if people.isEmpty {
                            Text("No one else uses this Cloud server yet.").foregroundStyle(.secondary)
                        }
                        ForEach(people, id: \.id) { person in
                            Button {
                                if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(person.name).foregroundStyle(.primary)
                                        Text(person.email).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected.contains(person.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
                        }
                    } header: {
                        Text("Share With")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(shared ? "New Shared Album" : "New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(shared ? "Create" : "Save") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working || (shared && selected.isEmpty))
                }
            }
            .onAppear {
                people = session.otherUsers()
                nameFocused = true
            }
        }
    }

    private func create() {
        working = true
        let title = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await session.createAlbum(named: title, assetIDs: assetIDs, sharedWith: shared ? Array(selected) : [])
                dismiss()
                onDone(String(localized: "Added to “\(title)”"))
            } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
                working = false
            }
        }
    }
}

/// Adjust Info › Adjust Date & Time, in the photo's own time zone.
struct AdjustDateView: View {
    let session: LibrarySession
    /// The first item: its current date or place is shown.
    let details: AssetDetails
    /// Every item to change (select mode); just `details` when nil.
    var assetIDs: [String]? = nil
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var error: String?
    @State private var working = false

    private var timeZone: TimeZone {
        details.exif?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// The capture time as an instant in `timeZone` (Immich stores wall-clock time as UTC).
    private var originalInstant: Date {
        let wallClock = details.asset.localDateTime ?? details.asset.fileCreatedAt ?? .now
        let components = Formatting.wallClock.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wallClock)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components) ?? wallClock
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Original", value: originalInstant.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)))
                    LabeledContent("Adjusted", value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)))
                        .foregroundStyle(.tint)
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, timeZone)
                    LabeledContent("Time Zone", value: timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Adjust Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adjust") { save() }.disabled(working)
                }
            }
            .onAppear { date = originalInstant }
        }
    }

    private func save() {
        working = true
        Task {
            do {
                try await session.setDate(date, timeZone: timeZone, assetIDs: assetIDs ?? [details.asset.id])
                dismiss()
                onDone(String(localized: "Date adjusted"))
            } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
                working = false
            }
        }
    }
}

/// Adjust Info › Adjust Location: search for a place.
struct AdjustLocationView: View {
    let session: LibrarySession
    /// The first item: its current date or place is shown.
    let details: AssetDetails
    /// Every item to change (select mode); just `details` when nil.
    var assetIDs: [String]? = nil
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = LocationSearch()
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                if let exif = details.exif, let latitude = exif.latitude, let longitude = exif.longitude {
                    Section("Current") {
                        Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude), latitudinalMeters: 3000, longitudinalMeters: 3000)), interactionModes: []) {
                            Marker("", coordinate: .init(latitude: latitude, longitude: longitude))
                        }
                        .frame(height: 140)
                        .listRowInsets(EdgeInsets())
                        if let place = InfoFormatting.place(exif) { Text(place) }
                    }
                }
                Section {
                    ForEach(search.results, id: \.self) { result in
                        Button {
                            choose(result)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(result.title).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(working)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a place")
            .navigationTitle("Adjust Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func choose(_ completion: MKLocalSearchCompletion) {
        working = true
        Task {
            do {
                let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
                guard let item = response.mapItems.first else {
                    throw CloudError(kind: .decoding, message: "That place has no coordinates.")
                }
                let coordinate: CLLocationCoordinate2D
                if #available(iOS 26.0, *) {
                    coordinate = item.location.coordinate
                } else {
                    coordinate = item.placemark.coordinate
                }
                try await session.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, assetIDs: assetIDs ?? [details.asset.id])
                dismiss()
                onDone(String(localized: "Location adjusted"))
            } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
                working = false
            }
        }
    }
}

/// Place search suggestions as you type (MapKit).
@MainActor
@Observable
final class LocationSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { completer.queryFragment = query }
    }
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // The completer calls its delegate on the main thread.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { self.results = self.completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { self.results = [] }
    }
}
