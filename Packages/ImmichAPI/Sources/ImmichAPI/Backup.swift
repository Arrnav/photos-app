import CloudCore
import Foundation

extension Client {
    /// `POST /assets/bulk-upload-check` in batches of 500 (gentle on the Pi): which
    /// checksums the server already has for this user, including trashed ones.
    public func existingAssets(_ items: [(itemID: String, checksum: String)]) async throws -> [CloudExistingAsset] {
        var results: [CloudExistingAsset] = []
        for start in stride(from: 0, to: items.count, by: 500) {
            let batch = items[start..<min(start + 500, items.count)]
            let body = Components.Schemas.AssetBulkUploadCheckDto(assets: batch.map { .init(checksum: $0.checksum, id: $0.itemID) })
            do {
                switch try await checkBulkUpload(body: .json(body)) {
                case .ok(let response):
                    for result in try response.body.json.results {
                        // "reject" with an asset id means the server has this file already.
                        let existing = result.action == .reject ? result.assetId : nil
                        results.append(CloudExistingAsset(itemID: result.id, assetID: existing, isTrashed: result.isTrashed ?? false))
                    }
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "check for existing uploads")
                }
            } catch {
                throw APIError.wrap(error, operation: "Upload check")
            }
        }
        return results
    }

    /// `POST /stacks`: the first id becomes the stack's cover.
    public func stack(assetIDs: [String]) async throws {
        guard assetIDs.count >= 2 else { return }
        do {
            switch try await createStack(body: .json(.init(assetIds: assetIDs))) {
            case .created:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "stack versions")
            }
        } catch {
            throw APIError.wrap(error, operation: "Stack")
        }
    }
}
