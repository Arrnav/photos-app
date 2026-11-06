import CloudCore
import CryptoKit
import Foundation
import ImmichAPI
import Persistence
import Sync

/// One signed-in Immich account on one server address.
struct ImmichConnection: CloudConnection {
    let server: ActiveServer
    private let token: String
    private let client: Client

    init(server: ActiveServer, token: String, session: URLSession) {
        self.server = server
        self.token = token
        client = ImmichClient.make(server: server.url, session: session) { token }
    }

    // MARK: Media

    var media: MediaSource {
        let server = server.url, token = token
        // Identifies server + account without exposing the token.
        let fingerprint = SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return MediaSource(
            identity: "immich|\(server.absoluteString)|\(fingerprint)",
            image: { id, size in MediaEndpoints.request(MediaEndpoints.thumbnail(server: server, assetID: id, size: size), token: token) },
            original: { id in MediaEndpoints.request(MediaEndpoints.original(server: server, assetID: id), token: token) },
            video: { id in
                var headers = ["Authorization": "Bearer \(token)"]
                for (name, value) in DeviceHeaders.values { headers[name.rawName] = value }
                return (MediaEndpoints.videoPlayback(server: server, assetID: id), headers)
            }
        )
    }

    func setProfileImage(jpeg: Data) async throws { try await client.setProfileImage(jpeg: jpeg) }

    func profileImageRequest(userID: String) -> URLRequest {
        MediaEndpoints.request(MediaEndpoints.profileImage(server: server.url, userID: userID), token: token)
    }

    // MARK: People, smart search, server settings

    func people() async throws -> [CloudPerson] { try await client.people() }
    func people(inAsset assetID: String) async throws -> [CloudPerson] { try await client.people(inAsset: assetID) }
    func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson {
        try await client.updatePerson(id: id, name: name, birthDate: birthDate)
    }
    func personThumbnailRequest(personID: String) -> URLRequest {
        MediaEndpoints.request(MediaEndpoints.personThumbnail(server: server.url, personID: personID), token: token)
    }
    func smartSearch(_ text: String, limit: Int) async throws -> [CloudAsset] { try await client.smartSearch(text, limit: limit) }
    func trashRetentionDays() async throws -> Int { try await client.trashRetentionDays() }

    // MARK: Library sync

    func syncLibrary(into database: AppDatabase, sessionFingerprint: String, fromScratch: Bool, progress: @escaping @Sendable (Int) -> Void) async throws {
        let service = SyncService(database: database, api: ClientSyncAPI(client: client))
        _ = try await service.run(sessionFingerprint: sessionFingerprint, fromScratch: fromScratch, onProgress: progress)
    }

    func libraryCounts() async throws -> CloudLibraryCounts {
        try await client.timelineCounts()
    }

    // MARK: Changes

    func setFavorite(_ isFavorite: Bool, assetIDs: [String]) async throws { try await client.setFavorite(isFavorite, assetIDs: assetIDs) }
    func setArchived(_ archived: Bool, assetIDs: [String]) async throws { try await client.setArchived(archived, assetIDs: assetIDs) }
    func setLocked(_ locked: Bool, assetIDs: [String]) async throws { try await client.setHidden(locked, assetIDs: assetIDs) }
    func moveToTrash(assetIDs: [String]) async throws { try await client.moveToTrash(assetIDs: assetIDs) }
    func restoreFromTrash(assetIDs: [String]) async throws { try await client.restoreFromTrash(assetIDs: assetIDs) }
    func deletePermanently(assetIDs: [String]) async throws { try await client.deletePermanently(assetIDs: assetIDs) }
    func setDateTimeOriginal(_ iso8601: String, assetIDs: [String]) async throws { try await client.setDateTimeOriginal(iso8601, assetIDs: assetIDs) }
    func setLocation(latitude: Double, longitude: Double, assetIDs: [String]) async throws {
        try await client.setLocation(latitude: latitude, longitude: longitude, assetIDs: assetIDs)
    }
    func setDescription(_ text: String, assetID: String) async throws { try await client.setDescription(text, assetID: assetID) }
    func stack(assetIDs: [String]) async throws { try await client.stack(assetIDs: assetIDs) }

    // MARK: Albums, memories, search, sharing

    func albums(shared: Bool) async throws -> [CloudAlbum] { try await client.albums(shared: shared) }
    func albums(containing assetID: String) async throws -> [CloudAlbum] { try await client.albums(containing: assetID) }
    func createAlbum(name: String, assetIDs: [String], sharedWith userIDs: [String]) async throws -> CloudAlbum {
        try await client.createAlbum(name: name, assetIDs: assetIDs, sharedWith: userIDs)
    }
    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws { try await client.addAssets(assetIDs, toAlbum: albumID) }
    func memories() async throws -> [CloudMemory] { try await client.memories() }
    func search(_ query: CloudSearchQuery, limit: Int) async throws -> [CloudAsset] { try await client.searchAssets(query, limit: limit) }

    func createSharedLink(assetIDs: [String], expiresAt: Date?) async throws -> CloudSharedLink {
        let link = try await client.createSharedLink(assetIDs: assetIDs, expiresAt: expiresAt)
        return CloudSharedLink(id: link.id, url: link.url(on: server.url), expiresAt: link.expiresAt)
    }

    func deleteSharedLink(id: String) async throws { try await client.deleteSharedLink(id: id) }

    /// A one-asset shared link; `playAssetVideo` accepts its key (PLAN.md M4, approved 2026-10-25).
    func temporaryPublicVideoURL(assetID: String, expiresAt: Date) async throws -> CloudSharedLink {
        let link = try await client.createSharedLink(assetIDs: [assetID], expiresAt: expiresAt, allowDownload: true, description: "ethwood Photos AirPlay (temporary)")
        var components = URLComponents(url: MediaEndpoints.videoPlayback(server: server.url, assetID: assetID), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: link.key)]
        return CloudSharedLink(id: link.id, url: components.url!, expiresAt: link.expiresAt)
    }

    // MARK: Hidden (Immich Locked Folder)

    func lockedFolderStatus() async throws -> CloudLockedFolderStatus {
        let status = try await client.authStatus()
        return CloudLockedFolderStatus(hasPin: status.hasPinCode, isUnlocked: status.isElevated)
    }
    func setUpLockedFolder(pin: String) async throws { try await client.setUpPinCode(pin) }
    func unlockLockedFolder(pin: String) async throws { try await client.unlockSession(pin: pin) }
    func lockLockedFolder() async throws { try await client.lockSession() }

    // MARK: Uploads

    func upload(_ file: CloudUploadFile) async throws -> CloudUploadResult {
        let result = try await client.uploadFile(
            at: file.fileURL, fileName: file.fileName, fileCreatedAt: file.createdAt, fileModifiedAt: file.modifiedAt,
            livePhotoVideoID: file.livePhotoVideoID,
            visibility: file.visibility.flatMap { Components.Schemas.AssetVisibility(rawValue: $0.rawValue) },
            isFavorite: file.isFavorite
        )
        return CloudUploadResult(assetID: result.assetID, created: result.created)
    }

    func existingAssets(_ items: [(itemID: String, checksum: String)]) async throws -> [CloudExistingAsset] {
        try await client.existingAssets(items)
    }

    var backup: any CloudBackupTransport { ImmichBackupTransport(server: server.url, token: token) }
}
