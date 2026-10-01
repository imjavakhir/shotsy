import Photos

/// A calendar month in a date-sorted fetch result. Members are a contiguous index range.
nonisolated struct MonthSection: Identifiable, Hashable, Sendable {
    /// "2026-09", or "undated".
    var key: String
    var title: String
    var range: Range<Int>

    var id: String { key }
    var count: Int { range.count }
}

nonisolated enum LibraryIndex {
    /// Groups consecutive dates (already sorted) into month sections. Assets without a date go to "Undated".
    /// Calendar work happens once per month, not per date: dates inside the last month's interval reuse its key.
    static func months(dates: [Date?], calendar: Calendar = .current) -> [MonthSection] {
        var sections: [MonthSection] = []
        var currentKey: String?
        var start = 0
        var title = ""
        // The month of the last dated item, as a half-open interval, and its key.
        var month: (start: Date, end: Date, key: String)?
        func close(at end: Int) {
            if let key = currentKey, end > start {
                sections.append(MonthSection(key: key, title: title, range: start..<end))
            }
        }
        for (i, date) in dates.enumerated() {
            let key: String
            if let date {
                if let m = month, date >= m.start, date < m.end {
                    key = m.key
                } else {
                    key = DayKey.monthKey(for: date, calendar: calendar)
                    month = calendar.dateInterval(of: .month, for: date).map { ($0.start, $0.end, key) }
                }
            } else {
                key = "undated"
            }
            if key != currentKey {
                close(at: i)
                currentKey = key
                start = i
                title = date.map { monthTitle($0, calendar: calendar) } ?? String(localized: "Undated")
            }
        }
        close(at: dates.count)
        return sections
    }

    static func monthTitle(_ date: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Reads creation dates off the main thread.
    static func sections(for result: PHFetchResult<PHAsset>) async -> [MonthSection] {
        return await Task.detached(priority: .userInitiated) {
            var dates: [Date?] = []
            dates.reserveCapacity(result.count)
            result.enumerateObjects { a, _, _ in dates.append(a.creationDate) }
            return months(dates: dates)
        }.value
    }

    static func ids(in result: PHFetchResult<PHAsset>, range: Range<Int>) -> [String] {
        guard !range.isEmpty, range.upperBound <= result.count else { return [] }
        return result.objects(at: IndexSet(integersIn: range)).map(\.localIdentifier)
    }
}
