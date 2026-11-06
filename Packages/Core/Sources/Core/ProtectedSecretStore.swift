import Foundation
import LocalAuthentication
import Security

/// Keychain items that can only be read after Face ID (or the device passcode as
/// a fallback). Used for the Immich PIN behind the Hidden album, so unlocking it
/// asks for the phone's own authentication instead of the Immich PIN.
public struct ProtectedSecretStore: Sendable {
    public enum ReadResult: Sendable, Equatable {
        case value(String)
        case notFound
        case cancelled
    }

    private let service: String

    public init(service: String = "com.ethwood.photos.protected") {
        self.service = service
    }

    /// Stores (or replaces) a secret that requires user presence to read. Only on this device.
    public func write(_ value: String, for key: String) throws {
        try? delete(key)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error
        ) else {
            throw KeychainError(status: errSecParam)
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessControl as String: access,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Reads the secret, showing the system Face ID / passcode prompt with `reason`.
    /// Blocks while the prompt is shown, so call it off the main thread.
    public func read(_ key: String, reason: String) throws -> ReadResult {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return .notFound }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed:
            return .cancelled
        default:
            throw KeychainError(status: status)
        }
    }

    /// Whether the secret exists, without prompting.
    public func exists(_ key: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // With interaction disallowed, an existing protected item reports "interaction not allowed".
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Asks for Face ID / passcode without reading anything (opening the Hidden album
    /// while the server session is still unlocked). Returns false if cancelled.
    public static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
