import Foundation
import Testing
@testable import Persistence

@Suite struct TimelineCacheTests {
    @Test func roundTripsEveryField() {
        let items = [
            TimelineItem(id: "a", date: Date(timeIntervalSince1970: 1_700_000_000.25), isVideo: true, durationMs: 12_345, isFavorite: true,
                         isLivePhoto: false, thumbhash: "1QcSHQ", aspectRatio: 0.75, uploadedAt: Date(timeIntervalSince1970: 1_700_000_100),
                         isEdited: true, hasCamera: true, isScreenshot: false, ownerID: "me", localID: "L/1", isRemote: true),
            TimelineItem(id: "local:L/2", date: .distantPast, isVideo: false, durationMs: nil, isFavorite: false, isLivePhoto: true,
                         thumbhash: nil, aspectRatio: 1, uploadedAt: nil, isScreenshot: true, ownerID: "ü-owner", localID: "L/2", isRemote: false),
        ]
        #expect(TimelineCache.decode(TimelineCache.encode(items)) == items)
    }

    @Test func rejectsDamagedFiles() {
        let data = TimelineCache.encode([TimelineItem(id: "a", date: .now, isVideo: false, durationMs: nil, isFavorite: false, isLivePhoto: false, thumbhash: nil, aspectRatio: 1)])
        #expect(TimelineCache.decode(data.dropLast(3)) == nil)
        #expect(TimelineCache.decode(Data("nonsense".utf8)) == nil)
        #expect(TimelineCache.decode(Data()) == nil)
    }

    @Test func decodesALargeLibraryQuickly() {
        var items: [TimelineItem] = []
        for i in 0..<25_000 {
            let localID: String? = i % 2 == 0 ? "ABCDEF-\(i)/L0/001" : nil
            let date = Date(timeIntervalSince1970: Double(i) * 60)
            items.append(TimelineItem(id: UUID().uuidString, date: date, isVideo: i % 10 == 0, durationMs: nil,
                                      isFavorite: false, isLivePhoto: false, thumbhash: "1QcSHQRnh493V4dIh4eXh1h4kJUI", aspectRatio: 0.75,
                                      ownerID: "11111111-1111-4111-8111-111111111111", localID: localID))
        }
        let data = TimelineCache.encode(items)
        let start = ContinuousClock.now
        let decoded = TimelineCache.decode(data)
        let elapsed = ContinuousClock.now - start
        #expect(decoded?.count == 25_000)
        #expect(elapsed < .milliseconds(150))
        print("decoded 25k in \(elapsed), \(data.count) bytes")
    }
}
