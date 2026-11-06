import CloudCore
import Foundation

/// URLs for the binary media endpoints, which are fetched outside the generated
/// client (PLAN.md D3): the spec declares `application/octet-stream` while the
/// server sends `image/webp`/`image/jpeg`, which the generated client rejects,
/// and AVPlayer must load video URLs itself to use range requests.
///
/// Paths follow the spec: `viewAsset`, `downloadAsset`, `playAssetVideo`.
public enum MediaEndpoints {
    /// `AssetMediaSize` values usable for `viewAsset`.
    public typealias ImageSize = CloudImageSize

    public static func thumbnail(server: URL, assetID: String, size: ImageSize) -> URL {
        var components = URLComponents(
            url: assetURL(server: server, assetID: assetID).appending(path: "thumbnail"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
        return components.url!
    }

    public static func original(server: URL, assetID: String) -> URL {
        assetURL(server: server, assetID: assetID).appending(path: "original")
    }

    public static func videoPlayback(server: URL, assetID: String) -> URL {
        assetURL(server: server, assetID: assetID).appending(path: "video/playback")
    }

    /// The user's profile picture (`getProfileImage`); 404 when they haven't set one.
    public static func profileImage(server: URL, userID: String) -> URL {
        ImmichClient.apiURL(for: server).appending(path: "users/\(userID)/profile-image")
    }

    /// A recognised person's face picture (`getPersonThumbnail`).
    public static func personThumbnail(server: URL, personID: String) -> URL {
        ImmichClient.apiURL(for: server).appending(path: "people/\(personID)/thumbnail")
    }

    /// A GET request carrying the same auth and device headers as the generated client.
    public static func request(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in DeviceHeaders.values {
            request.setValue(value, forHTTPHeaderField: name.rawName)
        }
        return request
    }

    private static func assetURL(server: URL, assetID: String) -> URL {
        ImmichClient.apiURL(for: server).appending(path: "assets/\(assetID)")
    }
}
