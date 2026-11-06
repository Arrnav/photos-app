import Foundation
import OpenAPIRuntime

public struct UploadResult: Sendable, Equatable {
    public let assetID: String
    /// False when the server already had this exact file (same checksum).
    public let created: Bool
}

extension Client {
    /// `POST /assets` in the foreground, through the generated client (used for
    /// Duplicate). Background backup uploads use a background URLSession instead (D2).
    public func uploadFile(
        at fileURL: URL,
        fileName: String,
        fileCreatedAt: Date,
        fileModifiedAt: Date,
        livePhotoVideoID: String? = nil,
        visibility: Components.Schemas.AssetVisibility? = nil,
        isFavorite: Bool = false
    ) async throws -> UploadResult {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let dates = ImmichDateTranscoder()
        var parts: [Components.Schemas.AssetMediaCreateDto] = [
            .assetData(.init(payload: .init(body: HTTPBody(data)), filename: fileName)),
            .fileCreatedAt(.init(payload: .init(body: HTTPBody(try dates.encode(fileCreatedAt))))),
            .fileModifiedAt(.init(payload: .init(body: HTTPBody(try dates.encode(fileModifiedAt))))),
            .filename(.init(payload: .init(body: HTTPBody(fileName)))),
            .isFavorite(.init(payload: .init(body: HTTPBody(isFavorite ? "true" : "false")))),
        ]
        if let livePhotoVideoID {
            parts.append(.livePhotoVideoId(.init(payload: .init(body: HTTPBody(livePhotoVideoID)))))
        }
        if let visibility {
            parts.append(.visibility(.init(payload: .init(body: HTTPBody(visibility.rawValue)))))
        }
        do {
            switch try await uploadAsset(body: .multipartForm(MultipartBody(parts))) {
            case .created(let response):
                return UploadResult(assetID: try response.body.json.id, created: true)
            case .ok(let response):
                return UploadResult(assetID: try response.body.json.id, created: false)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "upload")
            }
        } catch {
            throw APIError.wrap(error, operation: "Upload")
        }
    }
}
