import CloudCore
import Foundation
import OpenAPIRuntime

/// Partner sharing: one account shares its whole library with another.
extension Client {
    /// Everyone else on the server (the server leaves out the signed-in user).
    public func otherUsers() async throws -> [CloudUser] {
        do {
            switch try await searchUsers() {
            case .ok(let response):
                return try response.body.json.map { CloudUser(id: $0.id, name: $0.name, email: $0.email) }
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load the people on this server")
            }
        } catch {
            throw APIError.wrap(error, operation: "People on this server")
        }
    }

    public func createPartner(sharedWith userID: String) async throws {
        do {
            switch try await createPartner(body: .json(.init(sharedWithId: userID))) {
            case .created:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "share your library")
            }
        } catch {
            throw APIError.wrap(error, operation: "Share library")
        }
    }

    public func removePartner(sharedWith userID: String) async throws {
        do {
            switch try await removePartner(path: .init(id: userID)) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "stop sharing your library")
            }
        } catch {
            throw APIError.wrap(error, operation: "Stop sharing library")
        }
    }

    /// `partnerID` is the person sharing with the signed-in user.
    public func setPartnerInTimeline(_ inTimeline: Bool, partnerID: String) async throws {
        do {
            switch try await updatePartner(path: .init(id: partnerID), body: .json(.init(inTimeline: inTimeline))) {
            case .ok:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "change the shared library")
            }
        } catch {
            throw APIError.wrap(error, operation: "Shared library")
        }
    }
}
