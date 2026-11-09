import Foundation
import Persistence

/// A photo server the app can use as its "Cloud". The app is written against this
/// protocol; Immich is one implementation (`ImmichCloud.ImmichProvider`). Another
/// server only needs its own provider and connection.
public protocol CloudProvider: Sendable {
    /// Shown in diagnostics, e.g. "Immich".
    var name: String { get }
    /// How to tell that an address is this kind of server and answering.
    var prober: any ServerProber { get }

    func serverInfo(at server: URL) async throws -> CloudServerInfo
    func signIn(at server: URL, email: String, password: String) async throws -> CloudSignIn
    /// Ends the server session for this token; failures are logged, not thrown.
    func signOut(at server: URL, token: String) async
    /// Everything the app does with one signed-in account on the active server.
    func connection(to server: ActiveServer, token: String) -> any CloudConnection
    /// Reads a backup upload's response. Needs no connection: after a background relaunch
    /// results can arrive before any server has been probed.
    func uploadResult(statusCode: Int, body: Data) -> Result<CloudUploadResult, CloudError>
}

/// One account on one server address. Cheap to create; recreated when the address changes.
public protocol CloudConnection: Sendable {
    var server: ActiveServer { get }
    /// Where media bytes come from (thumbnails, previews, originals, video).
    var media: MediaSource { get }

    // MARK: Library sync

    /// Brings the phone's copy of the library (`AppDatabase`) up to date. `progress` reports applied changes.
    func syncLibrary(
        into database: AppDatabase, sessionFingerprint: String, fromScratch: Bool,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws
    func libraryCounts() async throws -> CloudLibraryCounts

    // MARK: Changes to assets

    func setFavorite(_ isFavorite: Bool, assetIDs: [String]) async throws
    func setArchived(_ archived: Bool, assetIDs: [String]) async throws
    func setLocked(_ locked: Bool, assetIDs: [String]) async throws
    func moveToTrash(assetIDs: [String]) async throws
    func restoreFromTrash(assetIDs: [String]) async throws
    func deletePermanently(assetIDs: [String]) async throws
    /// ISO-8601 with the photo's own offset, so the wall-clock time is what the user picked.
    func setDateTimeOriginal(_ iso8601: String, assetIDs: [String]) async throws
    func setLocation(latitude: Double, longitude: Double, assetIDs: [String]) async throws
    func setDescription(_ text: String, assetID: String) async throws
    /// Groups versions of one photo (an edited re-upload with its original).
    func stack(assetIDs: [String]) async throws

    // MARK: Albums, memories, search, sharing

    func albums(shared: Bool) async throws -> [CloudAlbum]
    func albums(containing assetID: String) async throws -> [CloudAlbum]
    func createAlbum(name: String, assetIDs: [String], sharedWith userIDs: [String]) async throws -> CloudAlbum
    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws
    /// Takes photos out of an album (they stay in the library). Returns the ids removed and how many the server refused.
    func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws -> (removed: [String], refused: Int)
    func memories() async throws -> [CloudMemory]
    func search(_ query: CloudSearchQuery, limit: Int) async throws -> [CloudAsset]
    func createSharedLink(assetIDs: [String], expiresAt: Date?) async throws -> CloudSharedLink
    func deleteSharedLink(id: String) async throws
    /// A URL anyone can stream one video from until `expiresAt` (AirPlay receivers fetch
    /// URLs themselves, without the app's sign-in). Delete the link when done.
    func temporaryPublicVideoURL(assetID: String, expiresAt: Date) async throws -> CloudSharedLink

    // MARK: Shared Library (each person's library shared whole with someone else)

    /// Everyone else with an account on the server.
    func otherUsers() async throws -> [CloudUser]
    /// Shares the signed-in user's library with `userID`.
    func startSharingLibrary(with userID: String) async throws
    func stopSharingLibrary(with userID: String) async throws
    /// Whether the library `partnerID` shares with the signed-in user shows in their Library.
    func showSharedLibraryInLibrary(_ shown: Bool, partnerID: String) async throws

    // MARK: Hidden (a PIN-protected area on the server)

    func lockedFolderStatus() async throws -> CloudLockedFolderStatus
    func setUpLockedFolder(pin: String) async throws
    func unlockLockedFolder(pin: String) async throws
    func lockLockedFolder() async throws

    // MARK: Uploads

    /// A foreground upload (Duplicate).
    func upload(_ file: CloudUploadFile) async throws -> CloudUploadResult
    /// Which checksums the server already has, in batches the server can handle.
    func existingAssets(_ items: [(itemID: String, checksum: String)]) async throws -> [CloudExistingAsset]
    /// Background backup: the request and body file for one upload (see `CloudBackupUpload`).
    var backup: any CloudBackupTransport { get }

    // MARK: People

    func profileImageRequest(userID: String) -> URLRequest
    /// Sets the signed-in user's profile picture.
    func setProfileImage(jpeg: Data) async throws

    // MARK: Machine learning (face recognition, smart search) and server settings

    /// Everyone recognised in the library (not hidden), most photographed first.
    func people() async throws -> [CloudPerson]
    /// The people recognised in one photo.
    func people(inAsset assetID: String) async throws -> [CloudPerson]
    /// Names (or renames) a person; nil leaves a field unchanged.
    func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson
    /// The person's face picture.
    func personThumbnailRequest(personID: String) -> URLRequest
    /// Search by meaning ("dog on a beach"), newest first.
    func smartSearch(_ text: String, limit: Int) async throws -> [CloudAsset]
    /// How many days deleted items stay in Recently Deleted.
    func trashRetentionDays() async throws -> Int
}

/// How a backup upload is sent with a background `URLSession`, which needs the
/// whole request body in a file on disk. The body is built in one pass: the provider's
/// `prefix`, the photo's bytes streamed straight from the photo library (hashed on the
/// way), then the `suffix`. So a file never has to exist twice on the phone.
public protocol CloudBackupTransport: Sendable {
    /// What goes around the file's bytes (`item.checksum` isn't known yet and isn't used).
    func uploadBody(for item: CloudBackupItem) throws -> CloudUploadBody
    /// The request that sends the finished body (with the file's checksum).
    func uploadRequest(for item: CloudBackupItem, body: CloudUploadBody) -> URLRequest
    /// Reads the server's answer to an upload.
    func uploadResult(statusCode: Int, body: Data) -> Result<CloudUploadResult, CloudError>
}

public struct CloudUploadBody: Sendable {
    public let prefix: Data
    public let suffix: Data
    public let contentType: String

    public init(prefix: Data, suffix: Data, contentType: String) {
        self.prefix = prefix
        self.suffix = suffix
        self.contentType = contentType
    }
}

extension CloudBackupTransport {
    /// Builds the body from a file already on disk (self-test, tests) and returns the request.
    public func prepareUpload(_ item: CloudBackupItem, source: URL, bodyFile: URL) throws -> URLRequest {
        let body = try uploadBody(for: item)
        FileManager.default.createFile(atPath: bodyFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyFile)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try output.write(contentsOf: body.prefix)
        while true {
            // Each chunk is released straight away: a multi-GB video must not pile up in memory.
            let more: Bool = try autoreleasepool {
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                try output.write(contentsOf: chunk)
                return true
            }
            if !more { break }
        }
        try output.write(contentsOf: body.suffix)
        return uploadRequest(for: item, body: body)
    }
}

/// One file of a backup (a photo, a video, or a Live Photo's still or motion part).
public struct CloudBackupItem: Sendable, Equatable {
    public var fileName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isFavorite: Bool
    public var durationSeconds: Double?
    /// The motion part's server id, when uploading a Live Photo's still.
    public var livePhotoVideoID: String?
    public var visibility: CloudVisibility?
    /// SHA-1 (base64) of `source`: lets the server answer "duplicate" before reading the body.
    public var checksum: String
    public var deviceAssetID: String
    public var deviceID: String
    /// Lets a reinstalled app recognise this upload without hashing again.
    public var origin: CloudBackupOrigin?

    public init(
        fileName: String, createdAt: Date, modifiedAt: Date, isFavorite: Bool, durationSeconds: Double?,
        livePhotoVideoID: String?, visibility: CloudVisibility?, checksum: String, deviceAssetID: String,
        deviceID: String, origin: CloudBackupOrigin?
    ) {
        self.fileName = fileName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isFavorite = isFavorite
        self.durationSeconds = durationSeconds
        self.livePhotoVideoID = livePhotoVideoID
        self.visibility = visibility
        self.checksum = checksum
        self.deviceAssetID = deviceAssetID
        self.deviceID = deviceID
        self.origin = origin
    }
}

/// Where an uploaded file came from on the phone (iCloud identity and edit state).
public struct CloudBackupOrigin: Sendable, Equatable, Codable {
    public var cloudID: String
    public var createdAt: Date?
    public var adjustmentTime: Date?
    public var latitude: Double?
    public var longitude: Double?

    public init(cloudID: String, createdAt: Date?, adjustmentTime: Date?, latitude: Double?, longitude: Double?) {
        self.cloudID = cloudID
        self.createdAt = createdAt
        self.adjustmentTime = adjustmentTime
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Builds requests for media bytes. Equal sources produce identical requests, so caches
/// can tell when the server or account changed.
public struct MediaSource: Sendable, Equatable {
    /// Identifies server + account (not secret).
    public let identity: String
    private let image: @Sendable (String, CloudImageSize) -> URLRequest
    private let original: @Sendable (String) -> URLRequest
    private let video: @Sendable (String) -> (url: URL, headers: [String: String])

    public init(
        identity: String,
        image: @escaping @Sendable (_ assetID: String, _ size: CloudImageSize) -> URLRequest,
        original: @escaping @Sendable (_ assetID: String) -> URLRequest,
        video: @escaping @Sendable (_ assetID: String) -> (url: URL, headers: [String: String])
    ) {
        self.identity = identity
        self.image = image
        self.original = original
        self.video = video
    }

    public func imageRequest(assetID: String, size: CloudImageSize) -> URLRequest { image(assetID, size) }
    public func originalRequest(assetID: String) -> URLRequest { original(assetID) }
    /// A streamable video URL and the headers AVPlayer must send with it.
    public func videoStream(assetID: String) -> (url: URL, headers: [String: String]) { video(assetID) }

    public static func == (lhs: MediaSource, rhs: MediaSource) -> Bool { lhs.identity == rhs.identity }
}
