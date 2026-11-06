import CloudCore
import MapKit
import Persistence
import SwiftUI

@MainActor
@Observable
final class InfoModel {
    enum Albums: Equatable {
        case loading
        case loaded([CloudAlbum])
        case failed(String)
    }

    private(set) var assetID: String
    private(set) var details: AssetDetails?
    private(set) var albums: Albums = .loading
    /// People recognised in the photo (the server's face recognition).
    private(set) var people: [CloudPerson] = []
    /// The photo itself, used as the map pin.
    private(set) var thumbnail: UIImage?
    var caption = ""
    private(set) var captionError: String?
    let session: LibrarySession
    private var loadTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?

    init(assetID: String, thumbnail: UIImage?, session: LibrarySession) {
        self.assetID = assetID
        self.thumbnail = thumbnail
        self.session = session
        show(assetID: assetID, thumbnail: thumbnail)
    }

    /// Switches to another photo (paging with the panel open).
    func show(assetID: String, thumbnail: UIImage?) {
        self.assetID = assetID
        self.thumbnail = thumbnail
        details = session.detailsNow(for: assetID)
        caption = details?.exif?.description ?? ""
        captionError = nil
        albums = .loading
        people = []
        loadTask?.cancel()
        peopleTask?.cancel()
        // Only on this iPhone: not in any Cloud album yet.
        if assetID.hasPrefix("local:") {
            albums = .loaded([])
            return
        }
        peopleTask = Task { [weak self] in
            guard let self, let people = try? await self.session.people(inAsset: assetID), !Task.isCancelled, self.assetID == assetID else { return }
            self.people = orderedPeople(people)
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let albums = try await self.session.albums(containing: assetID)
                guard !Task.isCancelled, self.assetID == assetID else { return }
                self.albums = .loaded(albums)
            } catch is CancellationError {
            } catch {
                guard self.assetID == assetID else { return }
                self.albums = .failed((error as? CloudError)?.message ?? error.localizedDescription)
            }
        }
    }

    func saveCaption() {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (details?.exif?.description ?? "") else { return }
        guard !assetID.hasPrefix("local:") else {
            captionError = String(localized: "Captions are saved in Cloud. Back this up first.")
            return
        }
        let id = assetID
        Task {
            do {
                try await session.setCaption(text, assetID: id)
                if assetID == id { details = session.detailsNow(for: id) }
            } catch {
                captionError = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// The info panel: caption, a card with
/// date, file, camera, lens and exposure, a map card, and albums.
struct InfoView: View {
    @Bindable var model: InfoModel
    @FocusState private var captionFocused: Bool
    @Environment(\.openURL) private var openURL
    @State private var openedPerson: CloudPerson?

    var body: some View {
        VStack(spacing: 14) {
            captionField
            if !model.people.isEmpty {
                peopleRow
            }
            if let details = model.details {
                mainCard(details)
                if let exif = details.exif, let latitude = exif.latitude, let longitude = exif.longitude {
                    mapCard(exif, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                }
            }
            albumsCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 120) // clear of the floating toolbar
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Faces recognised in the photo, with names; tap for that person's photos.
    private var peopleRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(model.people) { person in
                    Button { openedPerson = person } label: {
                        VStack(spacing: 5) {
                            PersonFaceView(personID: person.id, session: model.session, size: 56)
                            Text(person.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $openedPerson) { person in
            NavigationStack {
                PersonScreen(person: person, session: model.session, bottomInset: 0)
            }
            .environment(\.phoneImages, model.session.phoneImages)
        }
    }

    private var captionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Add a Caption", text: $model.caption, axis: .vertical)
                .focused($captionFocused)
                .submitLabel(.done)
                .onSubmit { model.saveCaption() }
                .onChange(of: captionFocused) { _, focused in
                    if !focused { model.saveCaption() }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            if let error = model.captionError {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 18)
            }
        }
    }

    private func mainCard(_ details: AssetDetails) -> some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(InfoFormatting.dateLine(details))
                    .font(.body.weight(.semibold))
                Label {
                    Text(InfoFormatting.baseName(details.asset.originalFileName))
                } icon: {
                    Image(systemName: "server.rack")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("On your Cloud server, \(details.asset.originalFileName)")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let exif = details.exif, let camera = InfoFormatting.camera(exif) {
                Divider().padding(.leading, 16)
                HStack {
                    Text(camera).font(.body.weight(.semibold))
                    Spacer()
                    if let format = InfoFormatting.formatBadge(details.asset.originalFileName) {
                        Text(format)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                .padding(16)
            }

            let lensLine = details.exif.flatMap(InfoFormatting.lensLine)
            let fileLine = InfoFormatting.fileLine(details)
            if lensLine != nil || fileLine != nil {
                Divider().padding(.leading, 16)
                VStack(alignment: .leading, spacing: 4) {
                    if let lensLine { Text(lensLine) }
                    if let fileLine { Text(fileLine) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let exposure = details.exif.map(InfoFormatting.exposureParts) ?? []
            if !exposure.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(exposure.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Divider().frame(height: 22) }
                        Text(part)
                            .font(.footnote.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func mapCard(_ exif: RemoteExifRecord, coordinate: CLLocationCoordinate2D) -> some View {
        let place = InfoFormatting.place(exif) ?? String(localized: "Location")
        return InfoCard {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)), interactionModes: []) {
                Annotation("", coordinate: coordinate, anchor: .bottom) {
                    MapPhotoPin(image: model.thumbnail)
                }
            }
            .frame(height: 180)
            .accessibilityLabel(place)

            Menu {
                Button("Open in Maps", systemImage: "map") {
                    openURL(InfoFormatting.mapsURL(coordinate, name: place))
                }
                Button("Open in Google Maps", systemImage: "globe") {
                    openURL(InfoFormatting.googleMapsURL(coordinate))
                }
            } label: {
                HStack(spacing: 4) {
                    Text(place)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .accessibilityHint("Opens the location in Maps or Google Maps")
        }
    }

    private var albumsCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Albums").font(.body.weight(.semibold))
                switch model.albums {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                case .loaded(let albums) where albums.isEmpty:
                    Text("Not in any albums").foregroundStyle(.secondary)
                case .loaded(let albums):
                    ForEach(albums) { album in
                        HStack {
                            Label(album.name, systemImage: album.isShared ? "person.2.fill" : "rectangle.stack")
                            Spacer()
                            Text(album.assetCount.formatted()).foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded card on the grouped background (dark grey on black, white on light grey).
private struct InfoCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// The photo as a map pin with a white border and a little pointer.
private struct MapPhotoPin: View {
    let image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.systemGray4)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(3)
            .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Triangle().fill(.white).frame(width: 14, height: 7)
        }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

enum InfoFormatting {
    /// The capture time where it was taken (Immich `localDateTime` is wall-clock time stored as UTC).
    private static func wallClock(_ details: AssetDetails) -> Date? {
        details.asset.localDateTime ?? details.asset.fileCreatedAt
    }

    /// "Saturday • 24 Oct 2026 • 10:59 am"
    static func dateLine(_ details: AssetDetails) -> String {
        guard let date = wallClock(details) else { return String(localized: "Unknown date") }
        let zone = Formatting.wallClock.timeZone
        let weekday = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide))
        let day = date.formatted(Date.FormatStyle(timeZone: zone).day().month(.abbreviated).year())
        let time = date.formatted(Date.FormatStyle(timeZone: zone).hour().minute())
        return "\(weekday) • \(day) • \(time)"
    }

    /// "IMG_8426.HEIC" → "IMG_8426"
    static func baseName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    static func formatBadge(_ fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "heic", "heif": "HEIF"
        case "jpg", "jpeg": "JPEG"
        case "png": "PNG"
        case "dng": "RAW"
        case "gif": "GIF"
        case "webp": "WEBP"
        case "mov": "MOV"
        case "mp4", "m4v": "MP4"
        case "": nil
        case let other: other.uppercased()
        }
    }

    static func camera(_ exif: RemoteExifRecord) -> String? {
        let make = exif.make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = exif.model?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (make.isEmpty, model.isEmpty) {
        case (true, true): return nil
        case (false, true): return make
        case (true, false): return model
        case (false, false):
            // "Canon" + "Canon EOS R6", but don't repeat a make the model already includes.
            return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        }
    }

    /// "Wide Camera — 5.1 mm ƒ1.6" for iPhone lenses, otherwise the lens name.
    static func lensLine(_ exif: RemoteExifRecord) -> String? {
        let lens = exif.lensModel?.lowercased() ?? ""
        var name: String?
        if lens.contains("front") {
            name = String(localized: "Front Camera")
        } else if lens.contains("back") || lens.contains("rear"), let focal = exif.focalLength {
            // iPhone back cameras by actual focal length.
            name = focal < 2.5 ? String(localized: "Ultra Wide Camera") : focal < 6.2 ? String(localized: "Wide Camera") : String(localized: "Telephoto Camera")
        } else if let model = exif.lensModel, !model.isEmpty {
            name = model
        }
        var optics: [String] = []
        if let focal = exif.focalLength { optics.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        if let f = exif.fNumber { optics.append("ƒ\(f.formatted(.number.precision(.fractionLength(0...1))))") }
        switch (name, optics.isEmpty) {
        case (nil, true): return nil
        case (nil, false): return optics.joined(separator: " ")
        case (let name?, true): return name
        case (let name?, false): return "\(name) — \(optics.joined(separator: " "))"
        }
    }

    /// "12 MP • 3024 × 4032 • 2.4 MB"
    static func fileLine(_ details: AssetDetails) -> String? {
        var parts: [String] = []
        let width = details.exif?.exifImageWidth ?? details.asset.width
        let height = details.exif?.exifImageHeight ?? details.asset.height
        if let width, let height, width > 0, height > 0 {
            let megapixels = Double(width * height) / 1_000_000
            if megapixels >= 1 { parts.append("\(megapixels.formatted(.number.precision(.fractionLength(0)))) MP") }
            parts.append("\(width) × \(height)")
        }
        if let size = details.exif?.fileSizeInByte { parts.append(Formatting.bytes(size)) }
        if details.asset.type == .video, let duration = details.asset.durationMs {
            parts.append(Formatting.duration(milliseconds: duration))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    static func exposureParts(_ exif: RemoteExifRecord) -> [String] {
        var parts: [String] = []
        if let iso = exif.iso { parts.append("ISO \(iso)") }
        if let focal = exif.focalLength { parts.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        if let f = exif.fNumber { parts.append("ƒ\(f.formatted(.number.precision(.fractionLength(0...1))))") }
        if let time = exif.exposureTime, !time.isEmpty { parts.append(time.contains("s") ? time : "\(time) s") }
        return parts
    }

    static func place(_ exif: RemoteExifRecord) -> String? {
        let parts = [exif.city, exif.state, exif.country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.prefix(2).joined(separator: ", ")
    }

    static func mapsURL(_ coordinate: CLLocationCoordinate2D, name: String) -> URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components.url!
    }

    /// Opens the Google Maps app when installed (universal link), otherwise the website.
    static func googleMapsURL(_ coordinate: CLLocationCoordinate2D) -> URL {
        var components = URLComponents(string: "https://www.google.com/maps/search/")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: "\(coordinate.latitude),\(coordinate.longitude)"),
        ]
        return components.url!
    }
}
