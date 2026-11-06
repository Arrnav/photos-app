import Backup
import CloudCore
import Core
import Foundation
import GRDB
import Library
import Persistence

extension LibrarySession {
    /// End-to-end check of the upload format with no side effects: a phone photo that Cloud
    /// already has is exported, wrapped exactly like a backup upload, and sent *without* the
    /// checksum header, so the server reads and parses the whole body and must answer
    /// "duplicate" with the existing asset's id. Nothing is created. (`-BackupSelfTest`)
    func backupSelfTest() async -> String {
        do {
            let connection = try connected()
            let ownerID = account.userID
            guard let pair = try await database.reader.read({ db in
                try Row.fetchOne(db, sql: """
                    SELECT l.id AS localId, r.id AS remoteId FROM localAsset l JOIN remoteAsset r ON r.checksum = l.checksum AND r.ownerId = ?
                    WHERE (l.subtypes & 8) = 0 AND l.mediaType = 1 ORDER BY l.localDateTime DESC LIMIT 1
                    """, arguments: [ownerID]).map { ($0["localId"] as String, $0["remoteId"] as String) }
            }) else { return "no phone photo that is already in Cloud" }
            let folder = FileManager.default.temporaryDirectory.appending(path: "selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            let exporter = PhotoKitExporter()
            let file = try await exporter.describe(localID: pair.0, part: .single)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appending(path: "source")
            FileManager.default.createFile(atPath: source.path, contents: nil)
            let output = try FileHandle(forWritingTo: source)
            let box = HandleBox(output)
            try await exporter.stream(localID: pair.0, part: .single, allowNetwork: false) { chunk in try box.write(chunk) }
            try output.close()
            let checksum = try ChecksumHasher.checksum(ofFile: source)
            let item = CloudBackupItem(
                fileName: file.fileName, createdAt: file.createdAt, modifiedAt: file.modifiedAt, isFavorite: file.isFavorite,
                durationSeconds: file.durationSeconds, livePhotoVideoID: nil, visibility: nil, checksum: checksum,
                deviceAssetID: pair.0, deviceID: Self.deviceID, origin: file.origin
            )
            let body = folder.appending(path: "body")
            var request = try connection.backup.prepareUpload(item, source: source, bodyFile: body)
            request.setValue(nil, forHTTPHeaderField: "x-immich-checksum")
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch provider.uploadResult(statusCode: status, body: data) {
            case .success(let result):
                let ok = !result.created && result.assetID == pair.1
                return "\(ok ? "PASS" : "FAIL") status=\(status) created=\(result.created) asset=\(result.assetID) expected=\(pair.1) file=\(file.fileName) bytes=\((try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? Int) ?? 0)"
            case .failure(let error):
                return "FAIL status=\(status) \(error.message)"
            }
        } catch {
            return "FAIL \(CloudError.wrap(error, operation: "Self-test").message)"
        }
    }
}

private final class HandleBox: @unchecked Sendable {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
}
