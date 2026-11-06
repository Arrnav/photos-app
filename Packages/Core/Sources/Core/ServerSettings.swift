import Foundation
import Observation

/// The two server addresses. Shared by all accounts (both users are on the same server).
public struct ServerAddresses: Codable, Hashable, Sendable {
    public var local: URL?
    public var remote: URL?

    public init(local: URL?, remote: URL?) {
        self.local = local
        self.remote = remote
    }

    /// Prefilled at sign-in: the app's build settings (`CLOUD_DEFAULT_LOCAL_SERVER` and
    /// `CLOUD_DEFAULT_REMOTE_SERVER` in Config/Local.xcconfig), or none.
    public static let defaults = ServerAddresses(
        local: (Bundle.main.object(forInfoDictionaryKey: "CloudDefaultLocalServer") as? String).flatMap(normalize),
        remote: (Bundle.main.object(forInfoDictionaryKey: "CloudDefaultRemoteServer") as? String).flatMap(normalize)
    )

    /// Parses user input such as `192.168.1.10:2283` or `http://host:2283/api`.
    /// The scheme defaults to http and a trailing `/api` is removed (the client adds it).
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}

@MainActor
@Observable
public final class ServerSettings {
    public var addresses: ServerAddresses {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let key = "server.addresses"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(ServerAddresses.self, from: data) {
            addresses = decoded
        } else {
            addresses = .defaults
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(addresses), forKey: Self.key)
    }
}
