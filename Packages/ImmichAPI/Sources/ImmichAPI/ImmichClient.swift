import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Supplies the access token for the active account. Returns nil when signed out.
public typealias TokenProvider = @Sendable () async -> String?

public enum ImmichClient {
    /// The API root for a server address, e.g. `http://host:2283` → `http://host:2283/api`.
    public static func apiURL(for server: URL) -> URL {
        server.appending(path: "api", directoryHint: .notDirectory)
    }

    /// Shared session for JSON API calls. Cookies and URL caching are off: auth is
    /// the bearer header, and media has its own cache.
    public static func makeSession(requestTimeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public static func make(
        server: URL,
        session: URLSession,
        token: @escaping TokenProvider = { nil }
    ) -> Client {
        Client(
            serverURL: apiURL(for: server),
            configuration: .init(dateTranscoder: ImmichDateTranscoder()),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: [AuthMiddleware(token: token), LoggingMiddleware()]
        )
    }
}

/// Immich sends dates with and without fractional seconds.
public struct ImmichDateTranscoder: DateTranscoder {
    public init() {}

    public func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    public func decode(_ string: String) throws -> Date {
        if let date = ImmichDateParser.parse(string) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unrecognised date: \(string)"))
    }
}

public enum ImmichDateParser {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    public static func parse(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }

    /// JSON decoder for payloads decoded outside the generated client (sync stream lines).
    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(string)")
            }
            return date
        }
        return decoder
    }
}
