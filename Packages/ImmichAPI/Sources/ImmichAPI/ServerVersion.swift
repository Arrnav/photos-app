import Foundation

public struct ServerVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The Immich release `api/immich-openapi-specs.json` came from.
    public static let generatedFrom = ServerVersion(major: 3, minor: 3, patch: 5)

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum VersionCheck: Sendable, Equatable {
    case matches
    /// The server is newer than the spec; most things should still work but warn.
    case serverNewer(ServerVersion)
    /// The server is older than the spec; endpoints may be missing.
    case serverOlder(ServerVersion)

    public init(server: ServerVersion, client: ServerVersion = .generatedFrom) {
        if server == client {
            self = .matches
        } else if server > client {
            self = .serverNewer(server)
        } else {
            self = .serverOlder(server)
        }
    }

    public var warning: String? {
        switch self {
        case .matches:
            nil
        case .serverNewer(let version):
            "The Cloud server runs version \(version), newer than \(ServerVersion.generatedFrom) which this app was built for. Some features may not work until the app is updated."
        case .serverOlder(let version):
            "The Cloud server runs version \(version), older than \(ServerVersion.generatedFrom) which this app was built for. Update the server."
        }
    }
}

extension Client {
    /// Fetches `GET /server/version`.
    public func serverVersion() async throws -> ServerVersion {
        switch try await getServerVersion() {
        case .ok(let response):
            let dto = try response.body.json
            return ServerVersion(major: dto.major, minor: dto.minor, patch: dto.patch)
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "server version")
        }
    }
}
