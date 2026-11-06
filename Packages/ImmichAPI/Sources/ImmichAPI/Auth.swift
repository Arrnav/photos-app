import Foundation
import OpenAPIRuntime

public struct LoginResult: Sendable, Equatable {
    public let accessToken: String
    public let userID: String
    public let email: String
    public let name: String
    public let isAdmin: Bool
}

extension Client {
    /// `POST /auth/login`. A 401 means wrong email or password.
    public func login(email: String, password: String) async throws -> LoginResult {
        let output: Operations.Login.Output
        do {
            output = try await login(body: .json(.init(email: email, password: password)))
        } catch {
            throw APIError.wrap(error, operation: "Sign in")
        }
        switch output {
        case .created(let response):
            let dto = try response.body.json
            return LoginResult(
                accessToken: dto.accessToken,
                userID: dto.userId,
                email: dto.userEmail,
                name: dto.name,
                isAdmin: dto.isAdmin
            )
        case .undocumented(401, _):
            throw APIError(kind: .unauthorized, message: "Wrong email or password.")
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "sign in")
        }
    }

    /// `POST /auth/logout`. Ends the server session for the current token.
    public func logoutSession() async throws {
        do {
            switch try await logout() {
            case .ok:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "sign out")
            }
        } catch {
            throw APIError.wrap(error, operation: "Sign out")
        }
    }

    /// `GET /users/me`. Throws `APIError` with kind `.unauthorized` when the token is no longer valid.
    public func currentUser() async throws -> Components.Schemas.UserAdminResponseDto {
        do {
            switch try await getMyUser() {
            case .ok(let response):
                return try response.body.json
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load your account")
            }
        } catch {
            throw APIError.wrap(error, operation: "Load your account")
        }
    }
}

extension Client {
    /// `POST /users/profile-image`: sets the signed-in user's profile picture (JPEG).
    public func setProfileImage(jpeg: Data) async throws {
        do {
            let part = Components.Schemas.CreateProfileImageDto.file(.init(payload: .init(body: HTTPBody(jpeg)), filename: "profile.jpg"))
            switch try await createProfileImage(body: .multipartForm(MultipartBody([part]))) {
            case .created:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "set the profile picture")
            }
        } catch {
            throw APIError.wrap(error, operation: "Profile picture")
        }
    }
}
