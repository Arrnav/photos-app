import Foundation
import Observation

/// A signed-in Immich user on this device. Each account has its own database
/// and caches (see `AccountPaths`) so the two libraries never mix.
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public let userID: String
    public var email: String
    public var name: String
    public var isAdmin: Bool

    public var id: String { userID }

    public init(userID: String, email: String, name: String, isAdmin: Bool) {
        self.userID = userID
        self.email = email
        self.name = name
        self.isAdmin = isAdmin
    }
}

/// Signed-in accounts and which one is active. Tokens live in the Keychain;
/// everything else in UserDefaults.
@MainActor
@Observable
public final class AccountStore {
    public private(set) var accounts: [Account]
    public private(set) var activeAccountID: String?

    public var activeAccount: Account? {
        accounts.first { $0.userID == activeAccountID }
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStore

    private static let accountsKey = "accounts.list"
    private static let activeKey = "accounts.active"

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
        if let data = defaults.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }
        let active = defaults.string(forKey: Self.activeKey)
        activeAccountID = accounts.contains { $0.userID == active } ? active : accounts.first?.userID
    }

    public func token(for account: Account) -> String? {
        do {
            return try secrets.read(Self.tokenKey(account.userID))
        } catch {
            Log.networking.error("Reading token for \(account.email, privacy: .private) failed: \(String(describing: error))")
            return nil
        }
    }

    /// Adds or updates an account, stores its token and makes it active.
    public func signIn(_ account: Account, token: String) throws {
        try secrets.write(token, for: Self.tokenKey(account.userID))
        if let index = accounts.firstIndex(where: { $0.userID == account.userID }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        activeAccountID = account.userID
        persist()
    }

    public func switchTo(_ account: Account) {
        guard accounts.contains(account) else { return }
        activeAccountID = account.userID
        persist()
    }

    /// Removes the account and its token. Local data is removed by the caller.
    public func signOut(_ account: Account) {
        try? secrets.delete(Self.tokenKey(account.userID))
        accounts.removeAll { $0.userID == account.userID }
        if activeAccountID == account.userID {
            activeAccountID = accounts.first?.userID
        }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
        defaults.set(activeAccountID, forKey: Self.activeKey)
    }

    private static func tokenKey(_ userID: String) -> String { "token.\(userID)" }
}

/// Per-account file locations.
public struct AccountPaths: Sendable {
    public let root: URL
    public let caches: URL

    public init(userID: String, fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = support.appending(path: "Accounts/\(userID)", directoryHint: .isDirectory)
        self.caches = caches.appending(path: "Accounts/\(userID)", directoryHint: .isDirectory)
    }

    public var database: URL { root.appending(path: "library.sqlite") }
    public var mediaCache: URL { caches.appending(path: "Media", directoryHint: .isDirectory) }
    /// Originals kept offline (Keep Offline): in Application Support, so iOS never clears them
    /// to free space, and left out of the phone's own backups.
    public var offline: URL { root.appending(path: "Offline", directoryHint: .isDirectory) }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mediaCache, withIntermediateDirectories: true)
    }

    public func removeAll(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
        try? fileManager.removeItem(at: caches)
    }
}
