import Foundation

/// Backup preferences (Settings › Backup). Off until the user turns it on.
public struct BackupSettings: Codable, Sendable, Equatable {
    public var isEnabled = false
    public var isPaused = false
    /// Upload over mobile data (and other expensive networks such as a phone hotspot).
    public var allowsMobileData = false
    public var onlyWhileCharging = false
    /// Download originals kept only in iCloud ("Optimise iPhone Storage") to back them up.
    public var downloadsFromICloud = true
    /// …but only on Wi-Fi.
    public var iCloudDownloadsOnWiFiOnly = true
    /// Temporary upload files on disk at most: 2 GB by default.
    public var tempBudgetBytes = 2 * 1024 * 1024 * 1024
    /// Mirror the chosen phone albums as Cloud albums (like the Immich app's Sync Albums).
    public var syncsAlbums = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BackupSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? defaults.isPaused
        allowsMobileData = try container.decodeIfPresent(Bool.self, forKey: .allowsMobileData) ?? defaults.allowsMobileData
        onlyWhileCharging = try container.decodeIfPresent(Bool.self, forKey: .onlyWhileCharging) ?? defaults.onlyWhileCharging
        downloadsFromICloud = try container.decodeIfPresent(Bool.self, forKey: .downloadsFromICloud) ?? defaults.downloadsFromICloud
        iCloudDownloadsOnWiFiOnly = try container.decodeIfPresent(Bool.self, forKey: .iCloudDownloadsOnWiFiOnly) ?? defaults.iCloudDownloadsOnWiFiOnly
        tempBudgetBytes = try container.decodeIfPresent(Int.self, forKey: .tempBudgetBytes) ?? defaults.tempBudgetBytes
        syncsAlbums = try container.decodeIfPresent(Bool.self, forKey: .syncsAlbums) ?? defaults.syncsAlbums
    }

    private static let key = "backup.settings"

    public static func load(_ defaults: UserDefaults = .standard) -> BackupSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BackupSettings.self, from: $0) } ?? BackupSettings()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// Retry delays: 30 s, then doubling, at most 6 hours, with ±20 % jitter so retries spread out.
public enum Backoff {
    public static func delay(afterAttempt attempt: Int, jitter: Double = Double.random(in: -0.2...0.2)) -> TimeInterval {
        let base = 30 * pow(2, Double(max(attempt - 1, 0)))
        return min(base, 6 * 3600) * (1 + jitter)
    }
}
