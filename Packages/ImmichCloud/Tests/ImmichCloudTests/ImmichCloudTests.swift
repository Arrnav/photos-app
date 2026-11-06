import CloudCore
import Foundation
import Testing
@testable import ImmichCloud

private let server = URL(string: "http://192.168.1.10:2283")!

@Suite struct BackupTransportTests {
    private func item(origin: CloudBackupOrigin? = nil, live: String? = nil, visibility: CloudVisibility? = nil) -> CloudBackupItem {
        CloudBackupItem(
            fileName: "IMG_0001.HEIC", createdAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            isFavorite: true, durationSeconds: 2.5, livePhotoVideoID: live, visibility: visibility,
            checksum: "abc=", deviceAssetID: "LOCAL/L0/001", deviceID: "device-1", origin: origin
        )
    }

    @Test func writesTheFieldsAndStreamsTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.heic")
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let body = folder.appending(path: "body")

        let transport = ImmichBackupTransport(server: server, token: "t0k")
        let request = try transport.prepareUpload(item(live: "11111111-1111-4111-8111-111111111111", visibility: .hidden), source: source, bodyFile: body)

        #expect(request.url?.absoluteString == "http://192.168.1.10:2283/api/assets")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-immich-checksum") == "abc=")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)

        let written = try Data(contentsOf: body)
        let text = String(decoding: written, as: UTF8.self)
        for (name, value) in [("fileCreatedAt", "2023-11-14T22:13:20.000Z"), ("fileModifiedAt", "2023-11-14T22:15:00.000Z"),
                              ("isFavorite", "true"), ("duration", "2500"), ("deviceAssetId", "LOCAL/L0/001"),
                              ("livePhotoVideoId", "11111111-1111-4111-8111-111111111111"), ("visibility", "hidden")] {
            #expect(text.contains("name=\"\(name)\"\r\n\r\n\(value)\r\n"), "missing \(name)")
        }
        #expect(!text.contains("name=\"metadata\""))
        #expect(text.contains("name=\"assetData\"; filename=\"IMG_0001.HEIC\""))
        #expect(text.hasSuffix("--\(boundary)--\r\n"))
        // The file bytes are copied exactly (the server hashes them).
        let marker = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
        let start = try #require(written.range(of: marker)).upperBound
        #expect(written[start..<(start + payload.count)] == payload)
    }

    @Test func metadataMatchesTheOfficialAppsFormat() throws {
        let origin = CloudBackupOrigin(cloudID: "CLOUD-1", createdAt: Date(timeIntervalSince1970: 1_700_000_000), adjustmentTime: nil, latitude: 47.37, longitude: 8.54)
        let json = try ImmichBackupTransport.metadataJSON(origin)
        #expect(json == #"[{"key":"mobile-app","value":{"createdAt":"2023-11-14T22:13:20.000Z","iCloudId":"CLOUD-1","latitude":"47.37","longitude":"8.54"}}]"#)
    }

    @Test func readsUploadResponses() throws {
        let transport = ImmichBackupTransport(server: server, token: "t")
        #expect(try transport.uploadResult(statusCode: 201, body: Data(#"{"id":"a1","status":"created"}"#.utf8)).get() == CloudUploadResult(assetID: "a1", created: true))
        #expect(try transport.uploadResult(statusCode: 200, body: Data(#"{"id":"a2","status":"duplicate"}"#.utf8)).get() == CloudUploadResult(assetID: "a2", created: false))
        guard case .failure(let error) = transport.uploadResult(statusCode: 400, body: Data(#"{"message":["bad date"]}"#.utf8)) else {
            Issue.record("expected failure"); return
        }
        #expect(error.message.contains("bad date"))
        guard case .failure(let auth) = transport.uploadResult(statusCode: 401, body: Data()) else { Issue.record("expected failure"); return }
        #expect(auth.kind == .unauthorized)
    }
}

@Suite struct MediaSourceTests {
    @Test func buildsImmichMediaURLs() {
        let connection = ImmichProvider().connection(to: ActiveServer(route: .local, url: server), token: "token")
        let thumb = connection.media.imageRequest(assetID: "a1", size: .thumbnail)
        #expect(thumb.url?.absoluteString == "http://192.168.1.10:2283/api/assets/a1/thumbnail?size=thumbnail")
        #expect(thumb.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(connection.media.originalRequest(assetID: "a1").url?.absoluteString == "http://192.168.1.10:2283/api/assets/a1/original")
        let video = connection.media.videoStream(assetID: "v1")
        #expect(video.url.absoluteString == "http://192.168.1.10:2283/api/assets/v1/video/playback")
        #expect(video.headers["Authorization"] == "Bearer token")
        // Same server and account → equal sources (caches stay valid); another token → different.
        let again = ImmichProvider().connection(to: ActiveServer(route: .local, url: server), token: "token").media
        let other = ImmichProvider().connection(to: ActiveServer(route: .local, url: server), token: "other").media
        #expect(connection.media == again)
        #expect(connection.media != other)
    }
}
