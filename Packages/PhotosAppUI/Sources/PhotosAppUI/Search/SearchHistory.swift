import Foundation

/// Search › Recents: past searches and recently viewed / shared photos, kept on this phone.
@MainActor
enum SearchHistory {
    private static let queriesKey = "search.recentQueries"
    private static let viewedKey = "search.recentlyViewed"
    private static let sharedKey = "search.recentlyShared"
    private static let limit = 200

    static var queries: [String] { UserDefaults.standard.stringArray(forKey: queriesKey) ?? [] }
    /// Asset IDs, most recent first.
    static var viewed: [String] { UserDefaults.standard.stringArray(forKey: viewedKey) ?? [] }
    static var shared: [String] { UserDefaults.standard.stringArray(forKey: sharedKey) ?? [] }

    static func recordQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        push([trimmed], key: queriesKey, max: 20)
    }

    static func recordViewed(_ assetID: String) { push([assetID], key: viewedKey, max: limit) }
    static func recordShared(_ assetIDs: [String]) { push(assetIDs, key: sharedKey, max: limit) }

    static func clear() {
        for key in [queriesKey, viewedKey, sharedKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func push(_ values: [String], key: String, max: Int) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { values.contains($0) }
        list.insert(contentsOf: values, at: 0)
        UserDefaults.standard.set(Array(list.prefix(max)), forKey: key)
    }
}
