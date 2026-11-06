import CloudCore
import Foundation
import OpenAPIRuntime

/// Immich calls fail with the app's provider-neutral error.
public typealias APIError = CloudError

extension CloudError {
    /// Builds an error from an undocumented response, reading Immich's
    /// `{"message": ..., "error": ..., "statusCode": ...}` body when present.
    public static func from(statusCode: Int, payload: UndocumentedPayload, operation: String) async -> CloudError {
        var serverMessage: String?
        if let body = payload.body,
           let data = try? await Data(collecting: body, upTo: 64 * 1024),
           let decoded = try? JSONDecoder().decode(ServerErrorBody.self, from: data) {
            serverMessage = decoded.message?.joined
        }
        let detail = serverMessage.map { ": \($0)" } ?? ""
        switch statusCode {
        case 401:
            return APIError(kind: .unauthorized, message: "The server rejected the sign-in (401)\(detail). Sign in again.")
        case 403:
            return APIError(kind: .http(status: 403), message: "Not allowed (403) for \(operation)\(detail).")
        case 404:
            return APIError(kind: .http(status: 404), message: "Not found (404) for \(operation)\(detail).")
        case 500...:
            return APIError(kind: .http(status: statusCode), message: "The server had an error (\(statusCode)) during \(operation)\(detail).")
        default:
            return APIError(kind: .http(status: statusCode), message: "Unexpected response \(statusCode) for \(operation)\(detail).")
        }
    }

}

/// The generated client wraps transport and decoding failures; unwrap them for a readable message.
extension ClientError: @retroactive CloudErrorConvertible {
    public func cloudError(operation: String) -> CloudError {
        CloudError.wrap(underlyingError, operation: operation, causeDescription: causeDescription)
    }
}

extension CloudError {
    static func wrap(_ error: any Error, operation: String, causeDescription: String?) -> CloudError {
        if let error = error as? CloudError { return error }
        return describe(error, operation: operation, causeDescription: causeDescription)
    }
}

private struct ServerErrorBody: Decodable {
    /// Immich sends either a string or an array of validation messages.
    enum Message: Decodable {
        case one(String)
        case many([String])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self = .one(single)
            } else {
                self = .many(try container.decode([String].self))
            }
        }

        var joined: String {
            switch self {
            case .one(let text): text
            case .many(let texts): texts.joined(separator: "; ")
            }
        }
    }

    let message: Message?
}

