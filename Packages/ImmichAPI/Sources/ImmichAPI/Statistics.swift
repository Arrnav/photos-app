import CloudCore
import Foundation

public typealias AssetCounts = CloudLibraryCounts

extension Client {
    /// `GET /assets/statistics?visibility=timeline`: what the server counts as the user's
    /// main timeline (not archived, hidden or locked; not in the trash).
    public func timelineCounts() async throws -> AssetCounts {
        do {
            switch try await getAssetStatistics(query: .init(visibility: .timeline)) {
            case .ok(let response):
                let dto = try response.body.json
                return AssetCounts(images: dto.images, videos: dto.videos, total: dto.total)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load server statistics")
            }
        } catch {
            throw APIError.wrap(error, operation: "Server statistics")
        }
    }
}
