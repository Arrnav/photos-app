import Core
import Foundation
import CloudCore
import Observation

/// The Hidden album, backed by Immich's Locked Folder.
///
/// The server only shows locked assets while the session is unlocked with the
/// account's Immich PIN. The user's own PIN is entered once on this phone and kept
/// in the Keychain behind Face ID (or the phone's passcode); after that, unlocking
/// is the iPhone way:
/// - no Immich PIN yet: the user chooses one (6 digits, e.g. the same as their passcode);
/// - a PIN already set elsewhere (web, official app): it's asked for once, checked, and stored.
@MainActor
@Observable
public final class HiddenVault {
    public enum State: Equatable {
        case locked
        case unlocking
        case unlocked
        /// The account has an Immich PIN this phone doesn't know yet.
        case needsExistingPin
        /// The account has no Immich PIN; the user chooses one.
        case needsNewPin
    }

    public private(set) var state = State.locked
    public private(set) var errorMessage: String?

    private let userID: String
    private let makeConnection: () throws -> any CloudConnection
    private let store = ProtectedSecretStore()

    init(userID: String, makeConnection: @escaping () throws -> any CloudConnection) {
        self.userID = userID
        self.makeConnection = makeConnection
    }

    private var pinKey: String { Self.pinKey(userID) }
    private nonisolated static func pinKey(_ userID: String) -> String { "immich-pin.\(userID)" }

    /// Forgets an account's stored PIN (sign-out).
    nonisolated static func forgetPin(userID: String) {
        try? ProtectedSecretStore().delete(pinKey(userID))
    }

    /// Face ID (or passcode), then unlocks the server session. Returns true when unlocked.
    @discardableResult
    public func unlock() async -> Bool {
        guard state != .unlocking else { return false }
        errorMessage = nil
        state = .unlocking
        do {
            let client = try makeConnection()
            let status = try await client.lockedFolderStatus()
            switch try await readPin(reason: String(localized: "Unlock the Hidden album")) {
            case .value(let pin):
                do {
                    try await client.unlockLockedFolder(pin: pin)
                    state = .unlocked
                    return true
                } catch let error as CloudError where error.kind == .unauthorized {
                    // The PIN was changed elsewhere: forget it and ask for the current one.
                    try? store.delete(pinKey)
                    state = .needsExistingPin
                    errorMessage = String(localized: "Your Cloud PIN has changed. Enter the current PIN once.")
                    return false
                }
            case .cancelled:
                state = .locked
                return false
            case .notFound where status.hasPin:
                state = .needsExistingPin
                return false
            case .notFound:
                state = .needsNewPin
                return false
            }
        } catch {
            state = .locked
            errorMessage = (error as? CloudError)?.message ?? (error as? KeychainError)?.description ?? error.localizedDescription
            return false
        }
    }

    /// For accounts without an Immich PIN: sets the user's chosen PIN on the server and stores it.
    @discardableResult
    public func createPin(_ pin: String) async -> Bool {
        errorMessage = nil
        guard Self.isValidPin(pin) else {
            errorMessage = String(localized: "The PIN must be exactly 6 digits.")
            return false
        }
        do {
            let client = try makeConnection()
            try await client.setUpLockedFolder(pin: pin)
            try store.write(pin, for: pinKey)
            try await client.unlockLockedFolder(pin: pin)
            Log.networking.info("Set up the Hidden album with the user's Cloud PIN")
            state = .unlocked
            return true
        } catch {
            errorMessage = (error as? CloudError)?.message ?? (error as? KeychainError)?.description ?? error.localizedDescription
            state = .needsNewPin
            return false
        }
    }

    /// Immich requires exactly six digits.
    public static func isValidPin(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }

    /// For accounts that already had an Immich PIN: checks it with the server and stores it.
    @discardableResult
    public func submitExistingPin(_ pin: String) async -> Bool {
        errorMessage = nil
        do {
            let client = try makeConnection()
            try await client.unlockLockedFolder(pin: pin)
            try store.write(pin, for: pinKey)
            state = .unlocked
            return true
        } catch let error as CloudError where error.kind == .unauthorized {
            errorMessage = String(localized: "That PIN didn’t work. Check it in the Cloud web app under Account Settings › PIN Code.")
            state = .needsExistingPin
            return false
        } catch {
            errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            state = .needsExistingPin
            return false
        }
    }

    /// Locks the server session again (leaving the Hidden album, or the app going to the background).
    public func lock() async {
        guard state == .unlocked else {
            if state == .needsExistingPin || state == .needsNewPin { state = .locked }
            return
        }
        state = .locked
        do {
            try await makeConnection().lockLockedFolder()
        } catch {
            Log.networking.notice("Locking the Hidden album on the server failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The stored Immich PIN, after Face ID (so it can be used in the Immich web app).
    public func revealPin() async -> String? {
        if case .value(let pin) = try? await readPin(reason: String(localized: "Show your Cloud PIN")) { return pin }
        return nil
    }

    public var hasStoredPin: Bool { store.exists(pinKey) }

    private func readPin(reason: String) async throws -> ProtectedSecretStore.ReadResult {
        let store = store, key = pinKey
        // The Keychain read blocks while the Face ID prompt is up.
        return try await Task.detached { try store.read(key, reason: reason) }.value
    }
}
