import CloudCore
import Foundation
import ImmichAPI

/// `POST /assets` for background uploads (PLAN.md D2): the multipart body goes to a
/// file so a background `URLSession` can send it, with the same fields the official
/// app sends, so the two apps' uploads are indistinguishable to the server.
struct ImmichBackupTransport: CloudBackupTransport {
    let server: URL
    let token: String

    /// The key the official app stores the iCloud identity under (read back by sync).
    static let mobileAppMetadataKey = "mobile-app"

    func uploadBody(for item: CloudBackupItem) throws -> CloudUploadBody {
        let boundary = "photos-\(UUID().uuidString)"
        var prefix = MultipartText(boundary: boundary)
        // deviceAssetId/deviceId are only needed by servers ≤ 2.7.5, but the official app still sends them.
        prefix.field("deviceAssetId", item.deviceAssetID)
        prefix.field("deviceId", item.deviceID)
        prefix.field("fileCreatedAt", Self.utc(item.createdAt))
        prefix.field("fileModifiedAt", Self.utc(item.modifiedAt))
        prefix.field("isFavorite", item.isFavorite ? "true" : "false")
        prefix.field("duration", String(Int(((item.durationSeconds ?? 0) * 1000).rounded())))
        if let livePhotoVideoID = item.livePhotoVideoID {
            prefix.field("livePhotoVideoId", livePhotoVideoID)
        }
        if let visibility = item.visibility {
            prefix.field("visibility", visibility.rawValue)
        }
        if let origin = item.origin {
            prefix.field("metadata", try Self.metadataJSON(origin))
        }
        prefix.fileHeader("assetData", fileName: item.fileName)
        return CloudUploadBody(prefix: prefix.data, suffix: Data("\r\n--\(boundary)--\r\n".utf8), contentType: "multipart/form-data; boundary=\(boundary)")
    }

    func uploadRequest(for item: CloudBackupItem, body: CloudUploadBody) -> URLRequest {
        var request = URLRequest(url: ImmichClient.apiURL(for: server).appending(path: "assets"))
        request.httpMethod = "POST"
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The server answers "duplicate" from this header before reading the body.
        request.setValue(item.checksum, forHTTPHeaderField: "x-immich-checksum")
        for (name, value) in DeviceHeaders.values { request.setValue(value, forHTTPHeaderField: name.rawName) }
        return request
    }

    func uploadResult(statusCode: Int, body: Data) -> Result<CloudUploadResult, CloudError> {
        struct Response: Decodable { let id: String; let status: String? }
        struct Failure: Decodable { let message: Message?
            enum Message: Decodable {
                case one(String), many([String])
                init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) { self = .one(text) } else { self = .many(try container.decode([String].self)) }
                }
                var text: String { switch self { case .one(let text): text; case .many(let texts): texts.joined(separator: "; ") } }
            }
        }
        switch statusCode {
        case 200, 201:
            guard let response = try? JSONDecoder().decode(Response.self, from: body) else {
                return .failure(CloudError(kind: .decoding, message: "Upload: the server's response could not be read."))
            }
            return .success(CloudUploadResult(assetID: response.id, created: statusCode == 201 && response.status != "duplicate"))
        case 401:
            return .failure(CloudError(kind: .unauthorized, message: "The server rejected the sign-in (401). Sign in again."))
        default:
            let detail = (try? JSONDecoder().decode(Failure.self, from: body))?.message.map { ": \($0.text)" } ?? ""
            return .failure(CloudError(kind: .http(status: statusCode), message: "The server refused the upload (\(statusCode))\(detail)."))
        }
    }

    static func utc(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// `[{"key":"mobile-app","value":{"iCloudId":…,"createdAt":…,"adjustmentTime":…,"latitude":"…","longitude":"…"}}]`
    static func metadataJSON(_ origin: CloudBackupOrigin) throws -> String {
        var value: [String: String] = ["iCloudId": origin.cloudID]
        if let createdAt = origin.createdAt { value["createdAt"] = utc(createdAt) }
        if let adjustmentTime = origin.adjustmentTime { value["adjustmentTime"] = utc(adjustmentTime) }
        if let latitude = origin.latitude { value["latitude"] = String(latitude) }
        if let longitude = origin.longitude { value["longitude"] = String(longitude) }
        let item: [String: Any] = ["key": mobileAppMetadataKey, "value": value]
        let data = try JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// The text parts of a multipart/form-data body (the file's bytes are added separately).
struct MultipartText {
    let boundary: String
    private(set) var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func field(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func fileHeader(_ name: String, fileName: String) {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
    }
}
