import Foundation

public struct AuthStatus: Sendable, Equatable {
    /// The account has an Immich PIN (needed for the Locked Folder, shown as "Hidden").
    public let hasPinCode: Bool
    /// This session is currently unlocked for locked assets.
    public let isElevated: Bool
}

/// Immich's Locked Folder: assets with visibility `locked` are only served while the
/// session is unlocked with the account PIN (15 minutes, extended by use).
extension Client {
    public func authStatus() async throws -> AuthStatus {
        do {
            switch try await getAuthStatus() {
            case .ok(let response):
                let dto = try response.body.json
                return AuthStatus(hasPinCode: dto.pinCode, isElevated: dto.isElevated)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "check the Hidden album")
            }
        } catch {
            throw APIError.wrap(error, operation: "Hidden album")
        }
    }

    public func setUpPinCode(_ pin: String) async throws {
        do {
            switch try await setupPinCode(body: .json(.init(pinCode: pin))) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "set up the Hidden album")
            }
        } catch {
            throw APIError.wrap(error, operation: "Hidden album setup")
        }
    }

    /// Unlocks this session for locked assets. A 400/401 means the PIN is wrong.
    public func unlockSession(pin: String) async throws {
        let output: Operations.UnlockAuthSession.Output
        do {
            output = try await unlockAuthSession(body: .json(.init(pinCode: pin)))
        } catch {
            throw APIError.wrap(error, operation: "Unlock Hidden")
        }
        switch output {
        case .noContent:
            return
        case .undocumented(let status, _) where status == 400 || status == 401:
            throw APIError(kind: .unauthorized, message: "The Cloud PIN was not accepted.")
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "unlock the Hidden album")
        }
    }

    public func lockSession() async throws {
        do {
            switch try await lockAuthSession() {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "lock the Hidden album")
            }
        } catch {
            throw APIError.wrap(error, operation: "Lock Hidden")
        }
    }

    public func setHidden(_ hidden: Bool, assetIDs: [String]) async throws {
        try await bulkUpdateVisibility(hidden ? .locked : .timeline, assetIDs: assetIDs, operation: hidden ? "hide" : "unhide")
    }
}
