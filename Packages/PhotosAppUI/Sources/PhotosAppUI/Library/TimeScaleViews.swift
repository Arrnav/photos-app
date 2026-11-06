import CloudCore
import MediaCache
import Persistence
import SwiftUI

/// Library › Years and Months: one card per year or month with a key photo.
/// Newest at the bottom; tapping drills down (Years → Months → All).
struct TimeScaleView: View {
    let scale: TimeScale
    let groups: [TimeGroup]
    let pipeline: RemoteImagePipeline
    @Bindable var ui: LibraryUIState
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: scale == .years ? 16 : 12) {
                    Color.clear.frame(height: topInset)
                    ForEach(groups) { group in
                        Button {
                            open(group)
                        } label: {
                            TimeGroupCard(group: group, scale: scale, pipeline: pipeline)
                        }
                        .buttonStyle(.plain)
                        .id(group.id)
                    }
                    Color.clear.frame(height: bottomInset)
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let anchor = ui.timeScaleAnchor, groups.contains(where: { $0.id == anchor }) {
                    proxy.scrollTo(anchor, anchor: .top)
                } else if let last = groups.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                ui.timeScaleAnchor = nil
            }
        }
    }

    private func open(_ group: TimeGroup) {
        withAnimation(.smooth(duration: 0.35)) {
            if scale == .years {
                ui.timeScaleAnchor = TimeGroup.monthID(year: group.year, month: group.firstMonth)
                ui.timeScale = .months
            } else {
                ui.scrollTarget = group.start
                ui.timeScale = .all
            }
        }
    }
}

/// A year or month of the library.
struct TimeGroup: Identifiable, Sendable {
    let id: String
    let year: Int
    let month: Int?
    let firstMonth: Int
    let start: Date
    let count: Int
    let keyItem: TimelineItem

    static func monthID(year: Int, month: Int) -> String { "\(year)-\(month)" }

    /// Groups items (oldest first) by year or by month.
    static func make(_ items: [TimelineItem], scale: TimeScale) -> [TimeGroup] {
        let calendar = Formatting.wallClock
        var groups: [TimeGroup] = []
        var bucket: [TimelineItem] = []
        var currentKey: (Int, Int)?

        func flush() {
            guard let first = bucket.first, let key = currentKey else { return }
            // Key photo: a favourite if there is one, otherwise one from the middle.
            let key_ = bucket.last(where: \.isFavorite) ?? bucket[bucket.count / 2]
            let month = calendar.component(.month, from: first.date)
            groups.append(TimeGroup(
                id: scale == .years ? "\(key.0)" : monthID(year: key.0, month: key.1),
                year: key.0,
                month: scale == .years ? nil : key.1,
                firstMonth: month,
                start: first.date,
                count: bucket.count,
                keyItem: key_
            ))
        }

        for item in items {
            let parts = calendar.dateComponents([.year, .month], from: item.date)
            let key = (parts.year ?? 0, scale == .years ? 0 : (parts.month ?? 0))
            if let currentKey, currentKey != key {
                flush()
                bucket.removeAll(keepingCapacity: true)
            }
            currentKey = key
            bucket.append(item)
        }
        flush()
        return groups
    }
}

private struct TimeGroupCard: View {
    let group: TimeGroup
    let scale: TimeScale
    let pipeline: RemoteImagePipeline

    var body: some View {
        PipelineImage(item: group.keyItem, pipeline: pipeline, pixelSize: 1200)
            .frame(height: scale == .years ? 300 : 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: scale == .years ? 34 : 26, weight: .bold))
                    if let subtitle {
                        Text(subtitle).font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                .padding(18)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(group.count == 1 ? "1 Item" : "\(group.count.formatted()) Items")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4)
                    .padding(14)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        if scale == .years { return String(group.year) }
        return group.start.formatted(Date.FormatStyle(timeZone: Formatting.wallClock.timeZone).month(.wide))
    }

    private var subtitle: String? {
        scale == .years ? nil : String(group.year)
    }
}

/// A server image in SwiftUI: the thumbhash placeholder, then the preview.
struct PipelineImage: View {
    let assetID: String
    let thumbhash: String?
    /// The phone's copy, loaded from PhotoKit when present.
    var localID: String? = nil
    @Environment(\.phoneImages) private var phone
    let pipeline: RemoteImagePipeline
    var pixelSize: Int = 600
    var size: CloudImageSize = .preview
    @State private var image: UIImage?

    init(item: TimelineItem, pipeline: RemoteImagePipeline, pixelSize: Int = 600, size: CloudImageSize = .preview) {
        self.init(assetID: item.id, thumbhash: item.thumbhash, pipeline: pipeline, pixelSize: pixelSize, size: size)
        localID = item.localID
    }

    init(assetID: String, thumbhash: String?, pipeline: RemoteImagePipeline, pixelSize: Int = 600, size: CloudImageSize = .preview) {
        self.assetID = assetID
        self.thumbhash = thumbhash
        self.pipeline = pipeline
        self.pixelSize = pixelSize
        self.size = size
    }

    var body: some View {
        // The image fills whatever frame the caller gives; it never sizes the layout itself.
        Color(.systemGray5)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let thumbhash, let placeholder = ThumbHash.image(base64: thumbhash) {
                    Image(decorative: placeholder, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: assetID) {
                if let localID, let phone {
                    let side = CGFloat(pixelSize)
                    phone.requestImage(localID: localID, pixelSize: CGSize(width: side, height: side), fill: true, quality: .high) { loaded, _ in
                        image = loaded
                    }
                    return
                }
                if let cached = pipeline.cachedImage(assetID: assetID, size: size, maxPixelSize: pixelSize) {
                    image = UIImage(cgImage: cached)
                    return
                }
                if let loaded = try? await pipeline.image(assetID: assetID, size: size, maxPixelSize: pixelSize, revision: thumbhash) {
                    image = UIImage(cgImage: loaded)
                }
            }
    }
}

extension EnvironmentValues {
    /// The phone's photo library images (set at the top of the signed-in app).
    @Entry var phoneImages: PhoneImages?
}
