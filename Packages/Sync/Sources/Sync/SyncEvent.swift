import Foundation
import ImmichAPI

public typealias Schemas = Components.Schemas

/// One decoded line of `/sync/stream`.
public struct SyncLine: Sendable {
    /// The raw `type` string, e.g. "AssetV2". Lines are applied in runs of the same type.
    public let type: String
    /// Opaque checkpoint to send back with `POST /sync/ack`.
    public let ack: String
    public let event: SyncEvent
}

public enum SyncEvent: Sendable {
    case authUser(Schemas.SyncAuthUserV2)
    case user(Schemas.SyncUserV1)
    case userDelete(Schemas.SyncUserDeleteV1)
    case asset(Schemas.SyncAssetV2)
    case assetDelete(Schemas.SyncAssetDeleteV1)
    case assetExif(Schemas.SyncAssetExifV1)
    case assetMetadata(Schemas.SyncAssetMetadataV1)
    case assetMetadataDelete(Schemas.SyncAssetMetadataDeleteV1)
    /// The server wants the client to drop all synced data and start again.
    case reset
    /// End of this stream; acking it records when the client last caught up.
    case complete
    /// A type this client did not request or does not know. Acked and ignored.
    case ignored
    /// A known type whose payload failed to decode (e.g. a newer server added an enum value).
    case undecodable(String)
}

/// The request types this app asks for (PLAN.md §3). Later milestones add more.
public enum SyncRequestTypes {
    public static let current: [Schemas.SyncRequestType] = [
        .authUsersV2,
        .usersV1,
        .assetsV2,
        .assetExifsV1,
        .assetMetadataV1,
    ]
}

extension SyncLine: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case ack
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        ack = try container.decode(String.self, forKey: .ack)

        func payload<T: Decodable>(_ make: (T) -> SyncEvent) -> SyncEvent {
            do {
                return make(try container.decode(T.self, forKey: .data))
            } catch {
                return .undecodable(String(describing: error))
            }
        }

        switch Schemas.SyncEntityType(rawValue: type) {
        case .authUserV2: event = payload(SyncEvent.authUser)
        case .userV1: event = payload(SyncEvent.user)
        case .userDeleteV1: event = payload(SyncEvent.userDelete)
        case .assetV2: event = payload(SyncEvent.asset)
        case .assetDeleteV1: event = payload(SyncEvent.assetDelete)
        case .assetExifV1: event = payload(SyncEvent.assetExif)
        case .assetMetadataV1: event = payload(SyncEvent.assetMetadata)
        case .assetMetadataDeleteV1: event = payload(SyncEvent.assetMetadataDelete)
        case .syncResetV1: event = .reset
        case .syncCompleteV1: event = .complete
        default: event = .ignored
        }
    }
}
