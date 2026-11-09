import Foundation
import GRDB

/// Counts of synced assets for one owner, for the diagnostics in Settings.
public struct LibraryCounts: Sendable, Equatable {
    /// Shown in the timeline (visibility `timeline`, not trashed).
    public var timelineImages = 0
    public var timelineVideos = 0
    /// Hidden videos are mostly the motion halves of Live Photos.
    public var hidden = 0
    public var archived = 0
    public var locked = 0
    public var trashed = 0
    /// Timeline assets the server hasn't made previews for yet (no thumbhash).
    public var waitingForPreviews = 0

    public var timelineTotal: Int { timelineImages + timelineVideos }

    public init() {}

    public static func fetch(ownerID: String, in db: Database) throws -> LibraryCounts {
        var counts = LibraryCounts()
        let rows = try Row.fetchAll(db, sql: """
            SELECT visibility, deletedAt IS NOT NULL AS trashed, type, thumbhash IS NULL AS noThumbhash, COUNT(*) AS n
            FROM remoteAsset WHERE ownerId = ?
            GROUP BY 1, 2, 3, 4
            """, arguments: [ownerID])
        for row in rows {
            let n: Int = row["n"]
            let visibility: String = row["visibility"]
            if row["trashed"] as Bool {
                counts.trashed += n
                continue
            }
            switch RemoteVisibility(rawValue: visibility) {
            case .timeline:
                if row["type"] as String == RemoteAssetType.video.rawValue {
                    counts.timelineVideos += n
                } else {
                    counts.timelineImages += n
                }
                if row["noThumbhash"] as Bool { counts.waitingForPreviews += n }
            case .hidden: counts.hidden += n
            case .archive: counts.archived += n
            case .locked: counts.locked += n
            case nil: break
            }
        }
        return counts
    }
}
