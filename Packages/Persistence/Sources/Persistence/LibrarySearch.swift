import Foundation
import GRDB

/// Search over the synced metadata (place, caption, file name, camera), so Search
/// works offline and costs the server nothing. Every word must match somewhere.
public enum LibrarySearch {
    /// IDs of the owner's visible photos matching all words, newest first.
    public static func assetIDs(ownerID: String, text: String, in db: Database) throws -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map { String($0) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let fields = "(COALESCE(e.city,'') || ' ' || COALESCE(e.state,'') || ' ' || COALESCE(e.country,'') || ' ' || COALESCE(e.description,'') || ' ' || a.originalFileName || ' ' || COALESCE(e.make,'') || ' ' || COALESCE(e.model,'') || ' ' || COALESCE(e.lensModel,''))"
        let conditions = Array(repeating: "\(fields) LIKE ? ESCAPE '\\'", count: words.count).joined(separator: " AND ")
        var arguments: StatementArguments = [ownerID, RemoteVisibility.timeline.rawValue]
        for word in words {
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            arguments += ["%\(escaped)%"]
        }
        return try String.fetchAll(db, sql: """
            SELECT a.id FROM remoteAsset a
            LEFT JOIN remoteExif e ON e.assetId = a.id
            WHERE a.ownerId = ? AND a.visibility = ? AND a.deletedAt IS NULL AND \(conditions)
            ORDER BY a.localDateTime DESC
            LIMIT 2000
            """, arguments: arguments)
    }

    /// Places with the most photos (city, else state/country), for suggestions.
    public static func topPlaces(ownerID: String, limit: Int, in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT COALESCE(NULLIF(e.city,''), NULLIF(e.state,''), NULLIF(e.country,'')) AS place
            FROM remoteAsset a JOIN remoteExif e ON e.assetId = a.id
            WHERE a.ownerId = ? AND a.visibility = ? AND a.deletedAt IS NULL AND place IS NOT NULL
            GROUP BY place ORDER BY COUNT(*) DESC LIMIT ?
            """, arguments: [ownerID, RemoteVisibility.timeline.rawValue, limit])
    }

    /// Geotagged visible photos (newest first) for the Map.
    public static func locations(ownerID: String, limit: Int, in db: Database) throws -> [AssetLocation] {
        try Row.fetchAll(db, sql: """
            SELECT a.id, e.latitude, e.longitude FROM remoteAsset a JOIN remoteExif e ON e.assetId = a.id
            WHERE a.ownerId = ? AND a.visibility = ? AND a.deletedAt IS NULL
              AND e.latitude IS NOT NULL AND e.longitude IS NOT NULL AND NOT (e.latitude = 0 AND e.longitude = 0)
            ORDER BY a.localDateTime DESC LIMIT ?
            """, arguments: [ownerID, RemoteVisibility.timeline.rawValue, limit])
            .map { AssetLocation(assetID: $0[0], latitude: $0[1], longitude: $0[2]) }
    }
}

public struct AssetLocation: Sendable, Hashable {
    public let assetID: String
    public let latitude: Double
    public let longitude: Double
}
