import Foundation
import Photos

/// Same month/day in earlier years, in the user's current calendar and time zone.
nonisolated enum OnThisDay {
    struct YearRange: Equatable, Sendable {
        var year: Int
        var interval: DateInterval
    }

    /// - Leap days: on Feb 29 only earlier Feb 29ths match. On Feb 28 of a non-leap year, Feb 29 of earlier
    ///   leap years is included too, so those memories still surface.
    /// - `spanDays` widens the match to ±N days (0 = exact day).
    static func ranges(today: Date, earliest: Date, spanDays: Int = 0, calendar: Calendar = .current) -> [YearRange] {
        let t = calendar.dateComponents([.year, .month, .day], from: today)
        guard let thisYear = t.year, let month = t.month, let day = t.day else { return [] }
        let firstYear = calendar.component(.year, from: earliest)
        guard firstYear < thisYear else { return [] }
        let todayIsLeapDay = month == 2 && day == 29
        let thisYearIsLeap = isLeap(thisYear, calendar: calendar)

        var result: [YearRange] = []
        for year in stride(from: thisYear - 1, through: firstYear, by: -1) {
            var startDay = DateComponents(year: year, month: month, day: day)
            var endDay = startDay
            if todayIsLeapDay {
                guard isLeap(year, calendar: calendar) else { continue }
            } else if month == 2, day == 28, !thisYearIsLeap, isLeap(year, calendar: calendar) {
                endDay = DateComponents(year: year, month: 2, day: 29)
            }
            guard let s = calendar.date(from: startDay), let e = calendar.date(from: endDay) else { continue }
            let start = calendar.date(byAdding: .day, value: -spanDays, to: calendar.startOfDay(for: s)) ?? s
            let endBase = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e)) ?? e
            let end = calendar.date(byAdding: .day, value: spanDays, to: endBase) ?? endBase
            startDay.day = nil
            result.append(YearRange(year: year, interval: DateInterval(start: start, end: end)))
        }
        return result
    }

    static func isLeap(_ year: Int, calendar: Calendar) -> Bool {
        guard let date = calendar.date(from: DateComponents(year: year, month: 2, day: 1)) else { return false }
        return calendar.range(of: .day, in: .month, for: date)?.count == 29
    }

    /// Predicate for photos/videos in one year's range, excluding screenshots by default. Hidden assets are
    /// excluded by the fetch options. Assets with no creation date never match.
    static func predicate(for range: YearRange, includeScreenshots: Bool) -> NSPredicate {
        let dates = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                range.interval.start as NSDate, range.interval.end as NSDate)
        var parts = [dates, PhotoLibrary.photosAndVideos]
        if !includeScreenshots {
            parts.append(NSPredicate(format: "NOT ((mediaSubtypes & %d) != 0)", PHAssetMediaSubtype.photoScreenshot.rawValue))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }
}
