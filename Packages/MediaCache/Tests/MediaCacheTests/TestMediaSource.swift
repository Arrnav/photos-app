import CloudCore
import Foundation

/// A media source with predictable URLs; the real ones are tested with each provider.
extension MediaSource {
    static func test(token: String = "token") -> MediaSource {
        @Sendable func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://media.test/\(path)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        return MediaSource(
            identity: "test-\(token)",
            image: { id, size in request("\(id)/\(size.rawValue)") },
            original: { id in request("\(id)/original") },
            video: { id in (URL(string: "https://media.test/\(id)/video")!, [:]) }
        )
    }
}
