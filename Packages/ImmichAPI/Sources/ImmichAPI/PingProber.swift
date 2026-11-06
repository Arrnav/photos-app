import CloudCore
import Foundation
import OpenAPIRuntime

/// Probes `GET /server/ping` through the generated client.
public struct PingProber: ServerProber {
    public init() {}

    public func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError> {
        let session = ImmichClient.makeSession(requestTimeout: timeout.timeInterval)
        defer { session.finishTasksAndInvalidate() }
        let client = ImmichClient.make(server: server, session: session)
        do {
            switch try await client.pingServer() {
            case .ok(let response):
                let body = try response.body.json
                guard body.res == "pong" else {
                    return .failure(APIError(kind: .decoding, message: "answered, but not like a Cloud server."))
                }
                return .success(())
            case .undocumented(let status, let payload):
                return .failure(await APIError.from(statusCode: status, payload: payload, operation: "ping"))
            }
        } catch {
            return .failure(APIError.wrap(error, operation: "ping"))
        }
    }
}

