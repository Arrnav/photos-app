import CloudCore
import Core
import Foundation
import ImmichAPI

/// Immich (https://immich.app) as the app's Cloud.
public struct ImmichProvider: CloudProvider {
    public let name = "Immich"
    private let session: URLSession

    public init(session: URLSession = ImmichClient.makeSession()) {
        self.session = session
    }

    public var prober: any ServerProber { PingProber() }

    public func serverInfo(at server: URL) async throws -> CloudServerInfo {
        do {
            let version = try await ImmichClient.make(server: server, session: session).serverVersion()
            return CloudServerInfo(version: version.description, warning: VersionCheck(server: version).warning)
        } catch {
            throw APIError.wrap(error, operation: "Version check")
        }
    }

    public func signIn(at server: URL, email: String, password: String) async throws -> CloudSignIn {
        let result = try await ImmichClient.make(server: server, session: session).login(email: email, password: password)
        return CloudSignIn(token: result.accessToken, userID: result.userID, email: result.email, name: result.name, isAdmin: result.isAdmin)
    }

    public func signOut(at server: URL, token: String) async {
        do {
            try await ImmichClient.make(server: server, session: session) { token }.logoutSession()
        } catch {
            Log.networking.notice("Server sign-out failed (continuing): \(APIError.wrap(error, operation: "Sign out").message, privacy: .public)")
        }
    }

    public func connection(to server: ActiveServer, token: String) -> any CloudConnection {
        ImmichConnection(server: server, token: token, session: session)
    }

    public func uploadResult(statusCode: Int, body: Data) -> Result<CloudUploadResult, CloudError> {
        // Parsing doesn't use the address or token.
        ImmichBackupTransport(server: URL(string: "http://localhost")!, token: "").uploadResult(statusCode: statusCode, body: body)
    }
}
