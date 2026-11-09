import Library
import Persistence
import Photos
import SwiftUI

/// Settings › This iPhone: Photos access, the phone's photo count and the tile status badges.
struct PhoneLibrarySection: View {
    let session: LibrarySession
    @AppStorage(PhotosSettings.showTileStatus) private var showsStatus = true
    @State private var counts: LocalCounts?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch session.photoAccess {
            case .authorized:
                LabeledContent("Photos Access", value: String(localized: "Full"))
            case .limited:
                LabeledContent("Photos Access", value: String(localized: "Limited"))
                Button("Allow Full Access") { openSettings() }
            case .notDetermined:
                Button("Show Photos on This iPhone") { Task { await session.requestPhotoAccess() } }
            default:
                LabeledContent("Photos Access", value: String(localized: "Off"))
                Button("Turn On in Settings") { openSettings() }
            }
            if let counts, counts.total > 0 {
                LabeledContent("On This iPhone", value: counts.total.formatted())
            }
            Toggle("Show Status on Tiles", isOn: $showsStatus)
        } header: {
            Text("This iPhone")
        } footer: {
            Text("Photos on this iPhone and in Cloud are shown once. Tiles show \(Image(systemName: "iphone")) only on this iPhone, \(Image(systemName: "cloud")) only in Cloud, \(Image(systemName: "checkmark.icloud")) in both.")
        }
        .task { counts = await session.phoneCounts() }

    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
