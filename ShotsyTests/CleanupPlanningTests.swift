import Foundation
import Testing
@testable import Shotsy

@Suite("Burst best pick")
struct BurstPlannerTests {
    func member(_ id: String, burst: String = "b1", user: Bool = false, auto: Bool = false, rep: Bool = false,
                fav: Bool = false, t: TimeInterval = 0) -> BurstMember {
        BurstMember(id: id, burstID: burst, isUserPick: user, isAutoPick: auto, representsBurst: rep,
                    isFavorite: fav, date: Date(timeIntervalSince1970: 1_000_000 + t), pixelCount: 12_000_000)
    }

    @Test func userPickBeatsAutoPickAndRepresentative() {
        let members = [member("a", rep: true, t: 0), member("b", auto: true, t: 1), member("c", user: true, t: 2)]
        #expect(BurstPlanner.keeper(of: members) == "c")
    }

    @Test func autoPickThenRepresentativeThenFirst() {
        #expect(BurstPlanner.keeper(of: [member("a", rep: true), member("b", auto: true)]) == "b")
        #expect(BurstPlanner.keeper(of: [member("a"), member("b", rep: true)]) == "b")
        #expect(BurstPlanner.keeper(of: [member("a"), member("b")]) == "a")
        #expect(BurstPlanner.keeper(of: []) == nil)
    }

    @Test func extrasLeaveOutKeeperUserPicksAndProtectedFavorites() {
        let members = [member("a", t: 0), member("b", user: true, t: 1), member("c", user: true, t: 2),
                       member("d", fav: true, t: 3), member("e", t: 4)]
        let protected = BurstPlanner.groups(members, protectFavorites: true)
        #expect(protected.count == 1)
        #expect(protected[0].keeper == "b")
        #expect(protected[0].extras == ["a", "e"])
        let unprotected = BurstPlanner.groups(members, protectFavorites: false)
        #expect(unprotected[0].extras == ["a", "d", "e"])
    }

    @Test func groupsInCaptureOrderNewestBurstFirstAndSinglesDropped() {
        let members = [
            member("old2", burst: "old", t: 2), member("old1", burst: "old", t: 1),
            member("new1", burst: "new", t: 100), member("new2", burst: "new", auto: true, t: 101),
            member("solo", burst: "solo", t: 50),
        ]
        let groups = BurstPlanner.groups(members, protectFavorites: true)
        #expect(groups.map(\.id) == ["new", "old"])
        #expect(groups[1].ids == ["old1", "old2"])
        #expect(groups[0].keeper == "new2")
        #expect(groups[0].extras == ["new1"])
    }

    @Test func burstWithNothingToSuggestIsDropped() {
        let members = [member("a", user: true), member("b", fav: true, t: 1)]
        #expect(BurstPlanner.groups(members, protectFavorites: true).isEmpty)
    }

    @Test func changingKeeperMakesTheOldKeeperAnExtra() {
        let members = [member("a", auto: true, t: 0), member("b", t: 1), member("c", fav: true, t: 2)]
        let group = BurstPlanner.groups(members, protectFavorites: true)[0]
        #expect(group.extras(keeping: "a") == ["b"])
        #expect(group.extras(keeping: "b") == ["a"])
        // A protected favorite never becomes an extra, even when it's not the keeper.
        #expect(group.extras(keeping: "c") == ["a", "b"])
    }
}

@Suite("Unsorted months")
struct MonthPlannerTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func listsOnlyMonthsWithUnsortedItemsNewestFirst() {
        let ids = ["s1", "s2", "s3", "a1", "a2", "j1"]
        let dates: [Date?] = [date(2026, 9, 20), date(2026, 9, 10), date(2026, 9, 1),
                              date(2026, 8, 30), date(2026, 8, 2), date(2026, 7, 4)]
        let decisions: [String: ReviewDecision] = ["s1": .keep, "a1": .keep, "a2": .marked]
        let months = MonthPlanner.unsortedMonths(ids: ids, dates: dates, decisions: decisions, calendar: calendar)
        #expect(months.map(\.section.key) == ["2026-09", "2026-07"])
        #expect(months[0].unsorted == 2)
        #expect(months[0].total == 3)
        #expect(months[0].ids == ["s1", "s2", "s3"])
        #expect(months[0].previewIDs == ["s2", "s3"])
        #expect(months[1].unsorted == 1)
    }

    @Test func previewIsCappedAndMismatchedInputIsEmpty() {
        let ids = (0..<10).map { "p\($0)" }
        let dates: [Date?] = Array(repeating: date(2026, 5, 5), count: 10)
        let months = MonthPlanner.unsortedMonths(ids: ids, dates: dates, decisions: [:], previewCount: 4, calendar: calendar)
        #expect(months.count == 1)
        #expect(months[0].previewIDs == ["p0", "p1", "p2", "p3"])
        #expect(MonthPlanner.unsortedMonths(ids: ids, dates: [], decisions: [:], calendar: calendar).isEmpty)
    }

    @Test func splitMonthIsMergedIntoOneCard() {
        let ids = ["a", "u", "b"]
        let dates: [Date?] = [date(2026, 3, 3), nil, date(2026, 3, 1)]
        let months = MonthPlanner.unsortedMonths(ids: ids, dates: dates, decisions: [:], calendar: calendar)
        #expect(months.map(\.section.key) == ["2026-03", "undated"])
        #expect(months[0].ids == ["a", "b"])
        #expect(Set(months.map(\.id)).count == months.count)
    }

    @Test func everythingSortedMeansNoMonths() {
        let months = MonthPlanner.unsortedMonths(ids: ["a"], dates: [date(2026, 1, 1)], decisions: ["a": .keep], calendar: calendar)
        #expect(months.isEmpty)
    }
}

@Suite("Month sections")
struct LibraryIndexMonthsTests {
    /// The previous implementation: calendar work for every date.
    func reference(_ dates: [Date?], calendar: Calendar) -> [MonthSection] {
        var sections: [MonthSection] = []
        var currentKey: String?
        var start = 0
        var title = ""
        for (i, date) in dates.enumerated() {
            let key = date.map { DayKey.monthKey(for: $0, calendar: calendar) } ?? "undated"
            if key != currentKey {
                if let currentKey, i > start { sections.append(MonthSection(key: currentKey, title: title, range: start..<i)) }
                currentKey = key
                start = i
                title = date.map { LibraryIndex.monthTitle($0, calendar: calendar) } ?? String(localized: "Undated")
            }
        }
        if let currentKey, dates.count > start {
            sections.append(MonthSection(key: currentKey, title: title, range: start..<dates.count))
        }
        return sections
    }

    func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    /// Random dates, many right at month boundaries (the first and last second of a month), some undated.
    func randomDates(count: Int, calendar: Calendar, using rng: inout some RandomNumberGenerator) -> [Date?] {
        (0..<count).map { _ -> Date? in
            if Int.random(in: 0..<10, using: &rng) == 0 { return nil }
            let month = calendar.date(from: DateComponents(year: Int.random(in: 2018...2026, using: &rng),
                                                           month: Int.random(in: 1...12, using: &rng), day: 1))!
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: return month
            case 1: return month.addingTimeInterval(-1)
            case 2: return calendar.dateInterval(of: .month, for: month)!.end.addingTimeInterval(-0.001)
            default: return month.addingTimeInterval(Double.random(in: 0..<(31 * 86_400), using: &rng))
            }
        }
    }

    @Test(arguments: ["UTC", "America/New_York", "Asia/Tokyo", "America/Sao_Paulo"])
    func matchesPerDateCalendarWork(zone: String) {
        let c = calendar(zone)
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<40 {
            let dates = randomDates(count: Int.random(in: 0..<300, using: &rng), calendar: c, using: &rng)
            // Unsorted, sorted newest first (undated last, like PhotoKit), and sorted oldest first.
            let newest = dates.sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) }
            let oldest = Array(newest.reversed())
            for input in [dates, newest, oldest] {
                #expect(LibraryIndex.months(dates: input, calendar: c) == reference(input, calendar: c))
            }
        }
    }

    @Test func boundariesAndUndatedRuns() {
        let c = calendar("UTC")
        let sep = c.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let dates: [Date?] = [sep, sep.addingTimeInterval(-1), nil, nil, sep, sep.addingTimeInterval(-0.001), sep]
        let sections = LibraryIndex.months(dates: dates, calendar: c)
        #expect(sections == reference(dates, calendar: c))
        #expect(sections.map(\.key) == ["2026-09", "2026-08", "undated", "2026-09", "2026-08", "2026-09"])
    }

    @Test func snapshotGroupsAndDecisionsOnlyRefilter() {
        let c = calendar("UTC")
        let d = { (m: Int, day: Int) in c.date(from: DateComponents(year: 2026, month: m, day: day, hour: 12))! }
        let ids = ["a", "b", "u", "c", "d"]
        let dates: [Date?] = [d(9, 2), d(9, 1), nil, d(9, 3), d(8, 1)]
        let grouped = MonthPlanner.group(ids: ids, dates: dates, calendar: c)
        #expect(grouped.map(\.section.key) == ["2026-09", "undated", "2026-08"])
        #expect(grouped[0].ids == ["a", "b", "c"])
        let decisions: [String: ReviewDecision] = ["a": .keep, "d": .marked]
        let filtered = MonthPlanner.unsorted(grouped, decisions: decisions, previewCount: 1)
        #expect(filtered == MonthPlanner.unsortedMonths(ids: ids, dates: dates, decisions: decisions,
                                                        previewCount: 1, calendar: c))
        #expect(filtered.map(\.section.key) == ["2026-09", "undated"])
        #expect(filtered[0].unsorted == 2)
        #expect(filtered[0].previewIDs == ["b"])
    }
}

/// Deterministic generator for randomized tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Storage estimate")
struct StorageEstimateTests {
    let mb: Int64 = 1_000_000

    @Test func photoEstimateUsesBytesPerPixel() {
        #expect(StorageEstimate.photoBytes(pixels: 12_000_000) == 3_000_000)
        #expect(StorageEstimate.photoBytes(pixels: -5) == 0)
    }

    @Test func sumsMeasuredVideosAndEstimatedPhotos() {
        let result = StorageEstimate.compute(
            photoPixels: ["p1": 12_000_000, "p2": 4_000_000],
            largeVideos: [VideoItem(id: "big", duration: 60, bytes: 500 * mb),
                          VideoItem(id: "small", duration: 5, bytes: 20 * mb),
                          VideoItem(id: "cloud", duration: 90, bytes: nil)],
            otherVideos: [VideoItem(id: "rec", duration: 30, bytes: 40 * mb)],
            excluded: [], favorites: [], protectFavorites: true)
        #expect(result.measuredVideoBytes == 540 * mb)
        #expect(result.estimatedPhotoBytes == 4_000_000)
        #expect(result.total == 544 * mb)
        #expect(result.unmeasuredVideos == 0)
    }

    @Test func skipsMarkedProtectedFavoritesAndDuplicates() {
        let videos = [VideoItem(id: "big", duration: 60, bytes: 500 * mb)]
        let result = StorageEstimate.compute(
            photoPixels: ["marked": 12_000_000, "fav": 12_000_000, "keep": 8_000_000],
            largeVideos: videos,
            otherVideos: videos + [VideoItem(id: "cloudRec", duration: 10, bytes: nil)],
            excluded: ["marked"], favorites: ["fav"], protectFavorites: true)
        #expect(result.measuredVideoBytes == 500 * mb) // counted once even though it's in two lists
        #expect(result.estimatedPhotoBytes == 2_000_000)
        #expect(result.unmeasuredVideos == 1)

        let unprotected = StorageEstimate.compute(photoPixels: ["fav": 12_000_000], largeVideos: [], otherVideos: [],
                                                  excluded: [], favorites: ["fav"], protectFavorites: false)
        #expect(unprotected.estimatedPhotoBytes == 3_000_000)
    }

    @Test func videosSortBySizeThenDuration() {
        let sorted = VideoItem.bySize([VideoItem(id: "short", duration: 5, bytes: nil),
                                       VideoItem(id: "s", duration: 1, bytes: 10),
                                       VideoItem(id: "long", duration: 50, bytes: nil),
                                       VideoItem(id: "l", duration: 1, bytes: 99)])
        #expect(sorted.map(\.id) == ["l", "s", "long", "short"])
    }
}

@Suite("Fanned stack layout")
struct FannedLayoutTests {
    @Test func fourCardsFanSymmetrically() {
        let slots = FannedLayout.slots(count: 4, spread: 30)
        #expect(slots.map(\.angle) == [-8, -3, 3, 8])
        #expect(slots.first?.x == -30)
        #expect(slots.last?.x == 30)
        #expect(slots.first?.y == 4)
    }

    @Test func countIsCappedAndEmptyIsEmpty() {
        #expect(FannedLayout.slots(count: 9, spread: 10).count == 4)
        #expect(FannedLayout.slots(count: 0, spread: 10).isEmpty)
        #expect(FannedLayout.slots(count: 1, spread: 10) == [FannedLayout.Slot(angle: 0, x: 0, y: 0)])
    }
}
