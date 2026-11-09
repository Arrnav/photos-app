import Foundation
import Persistence

enum Formatting {
    /// Timeline dates are wall-clock times stored as UTC (Immich `localDateTime`),
    /// so they are always formatted in UTC to show the time where the photo was taken.
    static let wallClock: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func duration(milliseconds: Int?) -> String {
        let total = max(0, (milliseconds ?? 0) / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func monthYear(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: wallClock.timeZone).month(.wide).year())
    }

    static func dayMonthYear(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: wallClock.timeZone).day().month(.wide).year())
    }

    /// "Today", "Yesterday", a weekday within the last week, else "24 October" (this year)
    /// or "24 October 2024". `date` is wall-clock time (see `wallClock`); "today" is the
    /// phone's local date.
    static func relativeDay(_ date: Date, now: Date = .now, calendar local: Calendar = .current) -> String {
        let taken = wallClock.dateComponents([.year, .month, .day], from: date)
        let today = local.dateComponents([.year, .month, .day], from: now)
        guard let takenDay = wallClock.date(from: taken), let todayDay = wallClock.date(from: today) else {
            return dayMonthYear(date)
        }
        let days = wallClock.dateComponents([.day], from: takenDay, to: todayDay).day ?? Int.max
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2...6: return date.formatted(Date.FormatStyle(timeZone: wallClock.timeZone).weekday(.wide))
        default:
            let style = Date.FormatStyle(timeZone: wallClock.timeZone).day().month(.wide)
            return taken.year == today.year ? date.formatted(style) : date.formatted(style.year())
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: wallClock.timeZone).hour().minute())
    }

    /// "24 Oct 2026", "16–24 Oct 2026", "28 Sep – 3 Oct 2026" (the Library subtitle).
    static func dateRange(_ range: ClosedRange<Date>) -> String {
        let zone = wallClock.timeZone
        if wallClock.isDate(range.lowerBound, inSameDayAs: range.upperBound) {
            return range.lowerBound.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone))
        }
        let style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, timeZone: zone)
        return (range.lowerBound..<range.upperBound).formatted(style)
    }

    static func accessibilityLabel(for item: TimelineItem) -> String {
        var parts: [String] = []
        if item.isVideo {
            parts.append(String(localized: "Video"))
            parts.append(duration(milliseconds: item.durationMs))
        } else {
            parts.append(item.isLivePhoto ? String(localized: "Live Photo") : String(localized: "Photo"))
        }
        parts.append(item.date.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: wallClock.timeZone)))
        if item.isFavorite { parts.append(String(localized: "Favourite")) }
        if item.isLocal && !item.isRemote { parts.append(String(localized: "Only on This iPhone")) }
        return parts.joined(separator: ", ")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
