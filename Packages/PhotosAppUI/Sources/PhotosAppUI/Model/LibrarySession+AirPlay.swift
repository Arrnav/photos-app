import CloudCore
import Core
import Foundation

/// AirPlay for Cloud videos (PLAN.md M4). A receiver fetches the URL itself, so it can't
/// send the app's sign-in. At home it gets a one-video public link that expires after an
/// hour and is deleted as soon as playback ends (and at the next launch if the app was
/// stopped first). Away from home the receiver can't reach the server at all, so the
/// video is downloaded and AirPlay streams the local file.
extension LibrarySession {
    private static let linksKey = "airplay.temporaryLinks"

    func airPlayVideoURL(assetID: String) async throws -> URL {
        let connection = try connected()
        if connection.server.route == .local {
            let link = try await connection.temporaryPublicVideoURL(assetID: assetID, expiresAt: .now.addingTimeInterval(3600))
            var links = UserDefaults.standard.stringArray(forKey: Self.linksKey) ?? []
            links.append(link.id)
            UserDefaults.standard.set(links, forKey: Self.linksKey)
            return link.url
        }
        let fileName = detailsNow(for: assetID)?.asset.originalFileName ?? "\(assetID).mov"
        return try await originals.file(assetID: assetID, fileName: fileName)
    }

    /// Deletes every temporary AirPlay link this app created (and any left from a previous run).
    func releaseAirPlayLinks() {
        let links = UserDefaults.standard.stringArray(forKey: Self.linksKey) ?? []
        guard !links.isEmpty, let connection = try? connected() else { return }
        Task {
            var remaining: [String] = []
            for id in links {
                do {
                    try await connection.deleteSharedLink(id: id)
                } catch let error as CloudError where error.kind == .http(status: 404) {
                    // Already gone (expired or deleted).
                } catch {
                    remaining.append(id)
                    Log.networking.notice("Couldn't delete AirPlay link yet: \(error.localizedDescription, privacy: .public)")
                }
            }
            UserDefaults.standard.set(remaining, forKey: Self.linksKey)
        }
    }
}
