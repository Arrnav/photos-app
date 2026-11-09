import CloudCore
import Foundation
import OpenAPIRuntime

extension CloudPerson {
    init(_ dto: Components.Schemas.PersonResponseDto) {
        self.init(id: dto.id, name: dto.name, birthDate: dto.birthDate, isHidden: dto.isHidden, isFavorite: dto.isFavorite ?? false)
    }
}

/// Face recognition, smart search and server settings. People and smart search need the
/// server's machine learning (which may run on another computer).
extension Client {
    /// Everyone recognised, not hidden, in pages of 500 (most photographed first, as the server orders them).
    public func people() async throws -> [CloudPerson] {
        var results: [CloudPerson] = []
        var page = 1
        do {
            while page <= 20 {
                switch try await getAllPeople(query: .init(page: page, size: 500, withHidden: false)) {
                case .ok(let response):
                    let body = try response.body.json
                    results += body.people.filter { !$0.isHidden }.map(CloudPerson.init)
                    guard body.hasNextPage == true else { return results }
                    page += 1
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "load people")
                }
            }
            return results
        } catch {
            throw APIError.wrap(error, operation: "People")
        }
    }

    /// The people recognised in one photo.
    public func people(inAsset assetID: String) async throws -> [CloudPerson] {
        do {
            switch try await getAssetInfo(path: .init(id: assetID)) {
            case .ok(let response):
                return try (response.body.json.people ?? []).filter { !$0.isHidden }.map(CloudPerson.init)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load the people in this photo")
            }
        } catch {
            throw APIError.wrap(error, operation: "People")
        }
    }

    public func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson {
        var dto = Components.Schemas.PersonUpdateDto()
        dto.name = name
        dto.birthDate = birthDate
        do {
            switch try await updatePerson(path: .init(id: id), body: .json(dto)) {
            case .ok(let response):
                return try CloudPerson(response.body.json)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "name this person")
            }
        } catch {
            throw APIError.wrap(error, operation: "Name person")
        }
    }

    /// Search by meaning, in pages of 100 up to `limit`.
    public func smartSearch(_ text: String, limit: Int) async throws -> [CloudAsset] {
        var results: [CloudAsset] = []
        var page = 1
        do {
            while results.count < limit {
                var dto = Components.Schemas.SmartSearchDto()
                dto.query = text
                dto.page = page
                dto.size = 100
                switch try await searchSmart(body: .json(dto)) {
                case .ok(let response):
                    let assets = try response.body.json.assets
                    results += assets.items.map(CloudAsset.init)
                    guard assets.nextPage != nil, !assets.items.isEmpty else { return results }
                    page += 1
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "search")
                }
            }
            return results
        } catch {
            throw APIError.wrap(error, operation: "Smart search")
        }
    }

    /// How many days the server keeps trashed items.
    public func trashRetentionDays() async throws -> Int {
        do {
            switch try await getServerConfig() {
            case .ok(let response):
                return try response.body.json.trashDays
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "read the server settings")
            }
        } catch {
            throw APIError.wrap(error, operation: "Server settings")
        }
    }
}
