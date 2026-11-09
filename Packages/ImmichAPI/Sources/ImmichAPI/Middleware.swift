import Core
import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Adds the bearer token and the device headers Immich records on sessions.
struct AuthMiddleware: ClientMiddleware {
    let token: TokenProvider

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = await token() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        for (name, value) in DeviceHeaders.values {
            request.headerFields[name] = value
        }
        return try await next(request, body, baseURL)
    }
}

struct LoggingMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let start = ContinuousClock.now
        do {
            let (response, responseBody) = try await next(request, body, baseURL)
            let elapsed = ContinuousClock.now - start
            Log.networking.debug("\(operationID, privacy: .public) \(response.status.code) in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public) via \(baseURL.host() ?? "?", privacy: .public)")
            return (response, responseBody)
        } catch {
            Log.networking.error("\(operationID, privacy: .public) failed via \(baseURL.host() ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

public enum DeviceHeaders {
    /// Immich shows these in the user's session list.
    public static let values: [(HTTPField.Name, String)] = [
        (HTTPField.Name("deviceType")!, "iOS"),
        (HTTPField.Name("deviceModel")!, machineIdentifier),
    ]

    private static let machineIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}
