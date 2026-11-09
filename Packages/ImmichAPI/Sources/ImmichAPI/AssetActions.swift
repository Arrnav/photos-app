import CloudCore
import Foundation

public typealias AlbumSummary = CloudAlbum

/// Server-side changes the viewer makes. Favourite and archive go through the
/// deprecated bulk `PUT /assets` (docs/DESIGN.md D4: the replacement PATCH isn't in the
/// spec); it's wrapped here so switching later is a one-line change.
extension Client {
    public func setFavorite(_ isFavorite: Bool, assetIDs: [String]) async throws {
        try await bulkUpdate(.init(ids: assetIDs, isFavorite: isFavorite), operation: isFavorite ? "add to Favourites" : "remove from Favourites")
    }

    public func setArchived(_ archived: Bool, assetIDs: [String]) async throws {
        try await bulkUpdate(.init(ids: assetIDs, visibility: archived ? .archive : .timeline), operation: archived ? "archive" : "unarchive")
    }

    func bulkUpdateVisibility(_ visibility: Components.Schemas.AssetVisibility, assetIDs: [String], operation: String) async throws {
        try await bulkUpdate(.init(ids: assetIDs, visibility: visibility), operation: operation)
    }

    /// New capture date and time. `dateTimeOriginal` is ISO 8601 with the photo's UTC offset.
    public func setDateTimeOriginal(_ dateTimeOriginal: String, assetIDs: [String]) async throws {
        try await bulkUpdate(.init(dateTimeOriginal: dateTimeOriginal, ids: assetIDs), operation: "change the date")
    }

    public func setLocation(latitude: Double, longitude: Double, assetIDs: [String]) async throws {
        try await bulkUpdate(.init(ids: assetIDs, latitude: latitude, longitude: longitude), operation: "change the location")
    }

    /// `POST /albums`, optionally shared with other users (as editors) and with assets.
    public func createAlbum(name: String, assetIDs: [String], sharedWith userIDs: [String] = []) async throws -> AlbumSummary {
        let users = userIDs.map { Components.Schemas.AlbumUserCreateDto(role: .editor, userId: $0) }
        do {
            switch try await createAlbum(body: .json(.init(albumName: name, albumUsers: users.isEmpty ? nil : users, assetIds: assetIDs))) {
            case .created(let response):
                let dto = try response.body.json
                return AlbumSummary(id: dto.id, name: dto.albumName, assetCount: dto.assetCount, isShared: dto.shared)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "create the album")
            }
        } catch {
            throw APIError.wrap(error, operation: "New album")
        }
    }

    /// `DELETE /albums/{id}/assets`. Returns the ids actually removed; the server refuses
    /// some when the user may not remove them (in a shared album, only the owner or whoever added them).
    public func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws -> (removed: [String], refused: Int) {
        do {
            switch try await removeAssetFromAlbum(path: .init(id: albumID), body: .json(.init(ids: assetIDs))) {
            case .ok(let response):
                let results = try response.body.json
                // "not_found" means it was already out of the album: as good as removed.
                let removed = results.filter { $0.success || $0.error == .notFound }.map(\.id)
                return (removed, results.count - removed.count)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "remove from the album")
            }
        } catch {
            throw APIError.wrap(error, operation: "Remove from album")
        }
    }

    /// `PUT /albums/{id}/assets`.
    public func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws {
        do {
            switch try await addAssetsToAlbum(path: .init(id: albumID), body: .json(.init(ids: assetIDs))) {
            case .ok:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "add to the album")
            }
        } catch {
            throw APIError.wrap(error, operation: "Add to album")
        }
    }

    /// Albums owned by the user (`shared: false`) or shared with/by them (`shared: true`).
    public func albums(shared: Bool) async throws -> [AlbumSummary] {
        do {
            switch try await getAllAlbums(query: .init(isShared: shared)) {
            case .ok(let response):
                return try response.body.json.map {
                    AlbumSummary(id: $0.id, name: $0.albumName, assetCount: $0.assetCount, isShared: $0.shared,
                                 thumbnailAssetID: $0.albumThumbnailAssetId, updatedAt: $0.lastModifiedAssetTimestamp ?? $0.updatedAt)
                }
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load albums")
            }
        } catch {
            throw APIError.wrap(error, operation: "Albums")
        }
    }

    /// The caption (Immich "description").
    public func setDescription(_ text: String, assetID: String) async throws {
        try await bulkUpdate(.init(description: text, ids: [assetID]), operation: "save the caption")
    }

    private func bulkUpdate(_ dto: Components.Schemas.AssetBulkUpdateDto, operation: String) async throws {
        do {
            switch try await updateAssets(body: .json(dto)) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: operation)
            }
        } catch {
            throw APIError.wrap(error, operation: operation.prefix(1).uppercased() + operation.dropFirst())
        }
    }

    /// `DELETE /assets` without `force`: moves the assets to the Immich trash.
    public func moveToTrash(assetIDs: [String]) async throws {
        do {
            switch try await deleteAssets(body: .json(.init(force: false, ids: assetIDs))) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "move to Trash")
            }
        } catch {
            throw APIError.wrap(error, operation: "Move to Trash")
        }
    }

    /// `POST /trash/restore/assets`.
    /// Deletes for good (Recently Deleted › Delete); this can't be undone.
    public func deletePermanently(assetIDs: [String]) async throws {
        do {
            switch try await deleteAssets(body: .json(.init(force: true, ids: assetIDs))) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "delete")
            }
        } catch {
            throw APIError.wrap(error, operation: "Delete")
        }
    }

    public func restoreFromTrash(assetIDs: [String]) async throws {
        do {
            switch try await restoreAssets(body: .json(.init(ids: assetIDs))) {
            case .ok:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "restore from Trash")
            }
        } catch {
            throw APIError.wrap(error, operation: "Restore from Trash")
        }
    }

    /// `GET /albums?assetId=`: albums (own and shared) that contain the asset.
    public func albums(containing assetID: String) async throws -> [AlbumSummary] {
        do {
            switch try await getAllAlbums(query: .init(assetId: assetID)) {
            case .ok(let response):
                return try response.body.json.map {
                    AlbumSummary(id: $0.id, name: $0.albumName, assetCount: $0.assetCount, isShared: $0.shared,
                                 thumbnailAssetID: $0.albumThumbnailAssetId, updatedAt: $0.lastModifiedAssetTimestamp ?? $0.updatedAt)
                }
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load albums")
            }
        } catch {
            throw APIError.wrap(error, operation: "Albums")
        }
    }
}

public struct SharedLink: Sendable, Equatable {
    public let id: String
    public let key: String
    public let expiresAt: Date?

    /// The public page for the link on `server` (Immich serves it at `/share/<key>`).
    public func url(on server: URL) -> URL {
        server.appending(path: "share/\(key)")
    }
}

extension Client {
    /// `POST /shared-links` for individual assets (Share › Create Shared Album Link).
    public func createSharedLink(assetIDs: [String], expiresAt: Date? = nil, allowDownload: Bool = true, description: String? = nil) async throws -> SharedLink {
        do {
            let body = Components.Schemas.SharedLinkCreateDto(
                allowDownload: allowDownload, assetIds: assetIDs, description: description, expiresAt: expiresAt, showMetadata: true, _type: .individual
            )
            switch try await createSharedLink(body: .json(body)) {
            case .created(let response):
                let dto = try response.body.json
                return SharedLink(id: dto.id, key: dto.key, expiresAt: dto.expiresAt)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "create a shared link")
            }
        } catch {
            throw APIError.wrap(error, operation: "Shared link")
        }
    }

    /// `DELETE /shared-links/{id}`.
    public func deleteSharedLink(id: String) async throws {
        do {
            switch try await removeSharedLink(path: .init(id: id)) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "delete the shared link")
            }
        } catch {
            throw APIError.wrap(error, operation: "Shared link")
        }
    }
}
