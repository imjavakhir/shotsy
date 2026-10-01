import CoreGraphics
import Foundation
import Testing
@testable import Shotsy

// MARK: - On This Day

@Suite("On This Day dates")
struct OnThisDayTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func sameDayInEarlierYearsNewestFirst() {
        let ranges = OnThisDay.ranges(today: date(2026, 9, 28), earliest: date(2023, 1, 1), calendar: calendar)
        #expect(ranges.map(\.year) == [2025, 2024, 2023])
        #expect(ranges[0].interval.contains(date(2025, 9, 28, 0)))
        #expect(ranges[0].interval.contains(date(2025, 9, 28, 23)))
        // Half-open: the fetch predicate uses creationDate < end, so the end is the next local midnight.
        #expect(ranges[0].interval.end == date(2025, 9, 29, 0))
    }

    @Test func leapDayOnlyMatchesLeapYears() {
        let ranges = OnThisDay.ranges(today: date(2028, 2, 29), earliest: date(2019, 1, 1), calendar: calendar)
        #expect(ranges.map(\.year) == [2024, 2020])
    }

    @Test func feb28InNonLeapYearIncludesEarlierFeb29() {
        let ranges = OnThisDay.ranges(today: date(2026, 2, 28), earliest: date(2024, 1, 1), calendar: calendar)
        let r2024 = try! #require(ranges.first { $0.year == 2024 })
        #expect(r2024.interval.contains(date(2024, 2, 29, 10)))
        #expect(r2024.interval.contains(date(2024, 2, 28, 10)))
        let r2025 = try! #require(ranges.first { $0.year == 2025 })
        #expect(!r2025.interval.contains(date(2025, 3, 1, 10)))
    }

    @Test func spanWidensRange() {
        let ranges = OnThisDay.ranges(today: date(2026, 9, 28), earliest: date(2025, 1, 1), spanDays: 3, calendar: calendar)
        #expect(ranges[0].interval.contains(date(2025, 9, 25, 1)))
        #expect(ranges[0].interval.contains(date(2025, 10, 1, 22)))
    }

    @Test func noEarlierYearsMeansEmpty() {
        #expect(OnThisDay.ranges(today: date(2026, 9, 28), earliest: date(2026, 1, 1), calendar: calendar).isEmpty)
    }

    @Test func dayKeysFollowLocalTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let instant = date(2026, 9, 28, 20) // 8 PM New York = next morning in Tokyo
        #expect(DayKey.key(for: instant, calendar: calendar) == "2026-09-28")
        #expect(DayKey.key(for: instant, calendar: tokyo) == "2026-09-29")
    }
}

// MARK: - Smart Collections

@Suite("Smart Collection rules")
struct SmartRuleTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func facts(_ id: String, video: Bool = false, screenshot: Bool = false, daysAgo: Int? = 5,
               favorite: Bool = false, duration: TimeInterval = 0) -> AssetFacts {
        AssetFacts(id: id, isVideo: video, isScreenshot: screenshot, isLivePhoto: false,
                   creationDate: daysAgo.map { now.addingTimeInterval(TimeInterval(-$0 * 86_400)) },
                   isFavorite: favorite, duration: duration)
    }

    var ctx: RuleContext {
        var c = RuleContext()
        c.now = now
        return c
    }

    @Test func allRequiresEveryRule() {
        let rules: [SmartRule] = [.mediaType(.screenshot), .olderThanDays(30)]
        #expect(SmartRuleEngine.evaluate(rules, matchAll: true, facts("a", screenshot: true, daysAgo: 40), ctx) == .yes)
        #expect(SmartRuleEngine.evaluate(rules, matchAll: true, facts("b", screenshot: true, daysAgo: 10), ctx) == .no)
    }

    @Test func anyNeedsOneRule() {
        let rules: [SmartRule] = [.favorite(true), .mediaType(.video)]
        #expect(SmartRuleEngine.evaluate(rules, matchAll: false, facts("a", video: true), ctx) == .yes)
        #expect(SmartRuleEngine.evaluate(rules, matchAll: false, facts("b"), ctx) == .no)
    }

    @Test func unknownIsNotTreatedAsNo() {
        // Screenshot not indexed yet → its category is unknown.
        let rules: [SmartRule] = [.screenshotCategory(.receipts)]
        #expect(SmartRuleEngine.evaluate(rules, matchAll: true, facts("s", screenshot: true), ctx) == .unknown)
        // A definite "no" elsewhere still decides ALL.
        #expect(SmartRuleEngine.evaluate(rules + [.favorite(true)], matchAll: true, facts("s", screenshot: true), ctx) == .no)
        // A definite "yes" decides ANY.
        #expect(SmartRuleEngine.evaluate(rules + [.favorite(true)], matchAll: false,
                                         facts("s", screenshot: true, favorite: true), ctx) == .yes)
    }

    @Test func unknownVideoSizeAndMissingDate() {
        #expect(SmartRuleEngine.evaluate(.videoLargerThan(bytes: 1), facts("v", video: true), ctx) == .unknown)
        #expect(SmartRuleEngine.evaluate(.olderThanDays(1), facts("x", daysAgo: nil), ctx) == .unknown)
        var c = ctx
        c.videoBytes["v"] = 10
        #expect(SmartRuleEngine.evaluate(.videoLargerThan(bytes: 1), facts("v", video: true), c) == .yes)
    }

    @Test func deletedAlbumIsUnknown() {
        var c = ctx
        c.albumMembers["gone"] = .some(nil)
        #expect(SmartRuleEngine.evaluate(.inAlbum(id: "gone", title: "Trip"), facts("a"), c) == .unknown)
    }

    @Test func reviewStatusUsesLocalDecisions() {
        var c = ctx
        c.decisions = ["k": .keep]
        #expect(SmartRuleEngine.evaluate(.reviewStatus(.unreviewed), facts("u"), c) == .yes)
        #expect(SmartRuleEngine.evaluate(.reviewStatus(.kept), facts("k"), c) == .yes)
    }

    @Test func validationCatchesImpossibleCombinations() {
        #expect(!SmartRuleEngine.validate([.mediaType(.video), .mediaType(.photo)], matchAll: true).isEmpty)
        #expect(SmartRuleEngine.validate([.mediaType(.video), .mediaType(.photo)], matchAll: false).isEmpty)
        #expect(!SmartRuleEngine.validate([.videoLongerThan(seconds: 60), .screenshotCategory(.receipts)], matchAll: true).isEmpty)
        #expect(!SmartRuleEngine.validate([.newerThanDays(10), .olderThanDays(30)], matchAll: true).isEmpty)
        #expect(SmartRuleEngine.validate([.newerThanDays(30), .olderThanDays(10)], matchAll: true).isEmpty)
        #expect(!SmartRuleEngine.validate([], matchAll: true).isEmpty)
    }

    @Test func rulesRoundTripThroughJSON() throws {
        let rules: [SmartRule] = [.mediaType(.screenshot), .person(id: UUID(), name: "Ana"), .videoLargerThan(bytes: 5)]
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([SmartRule].self, from: data) == rules)
    }
}

// MARK: - Screenshot Inbox

@Suite("Screenshot classification")
struct ClassifierTests {
    @Test(arguments: [
        ("Coffee Shop RECEIPT\nLatte $4.50\nMuffin $3.25\nSubtotal $7.75\nTax $0.62\nTotal $8.37\nVISA ****1234", ScreenshotCategory.receipts),
        ("BOARDING PASS\nFlight UA 123\nGate B12  Seat 14C\nDeparture 10:45", .tickets),
        ("Banana Bread\nIngredients\n2 cups flour\n1 tsp baking soda\nPreheat oven to 350F and bake 60 minutes", .recipes),
        ("Linen Shirt\n$49.00\nSize M\nIn stock\nAdd to Bag\nFree shipping on orders over $50", .shopping),
    ])
    func recognizesClearCases(text: String, expected: ScreenshotCategory) {
        #expect(ScreenshotClassifier.classify(text).category == expected)
    }

    @Test func weakOrAmbiguousTextIsOther() {
        #expect(ScreenshotClassifier.classify("").category == .other)
        #expect(ScreenshotClassifier.classify("hello there, see you at 5").category == .other)
        #expect(ScreenshotClassifier.classify("Ticket total paid").category == .other) // weak and mixed signals
    }

    @Test func userCorrectionAlwaysWins() {
        #expect(ScreenshotClassifier.effectiveCategory(userCategory: .tickets, suggested: .receipts, suggestionsEnabled: true) == .tickets)
        #expect(ScreenshotClassifier.effectiveCategory(userCategory: .tickets, suggested: .receipts, suggestionsEnabled: false) == .tickets)
        #expect(ScreenshotClassifier.effectiveCategory(userCategory: nil, suggested: .receipts, suggestionsEnabled: false) == nil)
    }

    @Test func linksAreExtractedNotFetched() {
        let links = ScreenshotClassifier.links(in: "Read more at https://example.com/a and https://example.com/a again")
        #expect(links == ["https://example.com/a"])
    }
}

// MARK: - Similarity, duplicates, blur

@Suite("Cleanup analysis")
struct CleanupAlgorithmTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func photo(_ id: String, _ seconds: TimeInterval, _ v: [Float], fav: Bool = false, w: Int = 4032, h: Int = 3024,
               sharp: Double? = 100) -> AnalyzedPhoto {
        AnalyzedPhoto(id: id, date: base.addingTimeInterval(seconds), vector: v, isFavorite: fav,
                      pixelWidth: w, pixelHeight: h, sharpness: sharp)
    }

    @Test func groupsCloseShotsOnlyWithinTimeWindow() {
        let groups = SimilarityGrouper.groups([
            photo("a", 0, [1, 0, 0]), photo("b", 5, [0.95, 0.05, 0]),
            photo("c", 3600, [1, 0, 0]),       // same look, an hour later → not grouped
            photo("d", 10, [0, 1, 0]),         // different content
        ])
        #expect(groups.count == 1)
        #expect(Set(groups[0].ids) == ["a", "b"])
    }

    @Test func keeperPrefersFavoriteThenResolution() {
        let (fav, r1) = SimilarityGrouper.suggestKeeper([photo("a", 0, [1]), photo("b", 1, [1], fav: true)])
        #expect(fav == "b" && r1 == .favorite)
        let (big, r2) = SimilarityGrouper.suggestKeeper([photo("a", 0, [1], w: 100, h: 100), photo("b", 1, [1])])
        #expect(big == "b" && r2 == .higherResolution)
    }

    @Test func defaultSelectionNeverTakesEveryone() {
        let group = SimilarGroup(ids: ["a", "b"], suggestedKeeper: "a", reason: .earliest, isDuplicateCandidate: false)
        let sel = SimilarityGrouper.defaultSelection(for: group, favorites: [], protectFavorites: true)
        #expect(sel == ["b"])
        let favGroup = SimilarGroup(ids: ["a", "b", "c"], suggestedKeeper: "a", reason: .earliest, isDuplicateCandidate: false)
        #expect(SimilarityGrouper.defaultSelection(for: favGroup, favorites: ["b"], protectFavorites: true) == ["c"])
    }

    @Test func nearIdenticalSameSizeIsOnlyACandidate() {
        let groups = SimilarityGrouper.groups([photo("a", 0, [1, 0]), photo("b", 1, [1, 0.001])])
        #expect(groups.first?.isDuplicateCandidate == true)
        let resized = SimilarityGrouper.groups([photo("a", 0, [1, 0]), photo("b", 1, [1, 0.001], w: 2000, h: 1500)])
        #expect(resized.first?.isDuplicateCandidate == false)
    }

    @Test func verifiedDuplicatesNeedEveryResourceToMatch() {
        let photoA = ResourceFingerprint(type: 1, uti: "public.heic", sha256: "aaa")
        let video = ResourceFingerprint(type: 9, uti: "com.apple.quicktime-movie", sha256: "vvv")
        let otherVideo = ResourceFingerprint(type: 9, uti: "com.apple.quicktime-movie", sha256: "www")
        let groups = DuplicateVerification.verifiedGroups([
            "1": [photoA, video],
            "2": [video, photoA],        // same set, different order → duplicate
            "3": [photoA, otherVideo],   // same still, different Live Photo video → not a duplicate
            "4": [photoA],               // missing the paired video → not a duplicate
            "5": nil,                    // unreadable → unverified
        ])
        #expect(groups == [["1", "2"]])
    }

    @Test func blurMetricSeparatesFlatFromDetailed() {
        let w = 32, h = 32
        let flat = [UInt8](repeating: 128, count: w * h)
        var checker = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where (x + y) % 2 == 0 { checker[y * w + x] = 255 } }
        #expect(BlurMetric.laplacianVariance(gray: flat, width: w, height: h) == 0)
        #expect(BlurMetric.laplacianVariance(gray: checker, width: w, height: h) > SimilarityTuning.blurThreshold)
    }
}

// MARK: - People

@Suite("Face grouping")
struct FaceGrouperTests {
    func face(_ v: [Float], manual: UUID? = nil, rejected: Set<UUID> = []) -> FaceGrouper.Face {
        FaceGrouper.Face(id: UUID(), embedding: v, manualPerson: manual, rejected: rejected)
    }

    @Test func groupsCloseFacesAndLeavesSingletonsUngrouped() {
        let a1 = face([1, 0, 0]), a2 = face([0.98, 0.02, 0]), b = face([0, 1, 0])
        let result = FaceGrouper.group([a1, a2, b], threshold: 0.1)
        #expect(Set(result.map(\.faceID)) == [a1.id, a2.id])
        #expect(Set(result.compactMap(\.newGroup)).count == 1)
    }

    @Test func manualAssignmentsAreKeptAndAttract() {
        let ana = UUID()
        let m = face([1, 0], manual: ana)
        let auto = face([0.99, 0.01])
        let result = FaceGrouper.group([m, auto], threshold: 0.1)
        #expect(result == [FaceGrouper.Assignment(faceID: auto.id, person: ana, newGroup: nil)])
    }

    @Test func rejectionIsRespected() {
        let ana = UUID()
        let m = face([1, 0], manual: ana)
        let rejected = face([0.99, 0.01], rejected: [ana])
        #expect(FaceGrouper.group([m, rejected], threshold: 0.1).isEmpty)
    }

    @Test func chainOfWeakMatchesDoesNotMergeStrangers() {
        // Each step is close to the previous, but the ends are far apart.
        let steps: [[Float]] = (0..<6).map { i in
            let angle = Float(i) * 0.35
            return [cos(angle), sin(angle)]
        }
        let result = FaceGrouper.group(steps.map { face($0) }, threshold: 0.08)
        let groups = Dictionary(grouping: result, by: { $0.newGroup })
        #expect(groups.values.allSatisfy { $0.count <= 3 })
    }
}

// MARK: - Purchases

@Suite("Entitlements (RevenueCat CustomerInfo mapping)")
struct EntitlementTests {
    let later = Date(timeIntervalSince1970: 1_900_000_000)
    let lifetime = OwnerConfig.lifetimeProductID
    let weekly = OwnerConfig.weeklyProductID

    @Test func noEntitlementMeansFree() {
        #expect(EntitlementResolver.resolve(nil) == .none)
    }

    @Test func inactiveEntitlementMeansFree() {
        // Expired, refunded, or revoked: RevenueCat reports the entitlement as inactive.
        let s = EntitlementSnapshot(isActive: false, productIdentifier: weekly, expirationDate: later)
        #expect(EntitlementResolver.resolve(s) == .none)
    }

    @Test func activeWeekly() {
        let s = EntitlementSnapshot(isActive: true, productIdentifier: weekly, expirationDate: later, activeSubscriptions: [weekly])
        #expect(EntitlementResolver.resolve(s) == .weekly(expires: later))
    }

    @Test func lifetimeHasNoExpiry() {
        let s = EntitlementSnapshot(isActive: true, productIdentifier: lifetime, expirationDate: nil)
        #expect(EntitlementResolver.resolve(s) == .lifetime(alsoHasWeekly: false))
    }

    @Test func lifetimeWinsAndNotesActiveWeekly() {
        let s = EntitlementSnapshot(isActive: true, productIdentifier: lifetime, expirationDate: nil, activeSubscriptions: [weekly])
        let result = EntitlementResolver.resolve(s)
        #expect(result == .lifetime(alsoHasWeekly: true))
        #expect(result.isPro)
    }
}

// MARK: - Deep links, reminders

@Suite("Deep links and reminders")
struct SystemIntegrationTests {
    @Test func deepLinksParseOnlyKnownDestinations() {
        #expect(DeepLink(url: URL(string: "shotsy://quick20")!) == .quick20)
        #expect(DeepLink(url: URL(string: "shotsy://review")!) == .reviewDeletions)
        let id = UUID()
        #expect(DeepLink(url: URL(string: "shotsy://session/\(id.uuidString)")!) == .session(id))
        #expect(DeepLink(url: URL(string: "shotsy://delete")!) == nil)
        #expect(DeepLink(url: URL(string: "shotsy://session/not-a-uuid")!) == nil)
        #expect(DeepLink(url: URL(string: "https://quick20")!) == nil)
        for link in [DeepLink.clean, .quick20, .session(id), .reviewDeletions, .library, .albums] {
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test func reminderPlanIsStableAndClamped() {
        let plan = ReminderPlan.requests(weekdays: [4, 1, 9], hour: 25, minute: -3)
        #expect(plan.map(\.id) == ["shotsy.reminder.1", "shotsy.reminder.4"])
        #expect(plan.allSatisfy { $0.components.hour == 23 && $0.components.minute == 0 })
        #expect(plan.allSatisfy { $0.components.timeZone == nil }, "Must follow the device's current time zone")
        #expect(ReminderPlan.requests(weekdays: [], hour: 9, minute: 0).isEmpty)
    }
}

// MARK: - Compression, library index

@Suite("Compression and library index")
struct CompressionAndIndexTests {
    func info(w: CGFloat = 3840, h: CGFloat = 2160, bytes: Int64? = 900_000_000, hdr: Bool = false,
              spatial: Bool = false, cinematic: Bool = false, slowmo: Bool = false) -> VideoSourceInfo {
        VideoSourceInfo(duration: 60, size: CGSize(width: w, height: h), bytes: bytes, isHDR: hdr, frameRate: 30,
                        isSlowMotion: slowmo, isCinematic: cinematic, isSpatial: spatial, hasAudio: true)
    }

    @Test func spatialIsNotOffered() {
        if case .available = CompressionPolicy.availability(of: .hevc1080, for: info(spatial: true)) {
            Issue.record("Spatial video must not be compressed")
        }
    }

    @Test func notesExplainWhatIsLost() {
        guard case .available(let notes) = CompressionPolicy.availability(of: .h264_720, for: info(hdr: true, cinematic: true)) else {
            Issue.record("Expected available"); return
        }
        #expect(notes.count == 2)
        guard case .available(let hevcNotes) = CompressionPolicy.availability(of: .hevc1080, for: info(hdr: true)) else { return }
        #expect(hevcNotes.isEmpty, "HEVC keeps HDR")
    }

    @Test func downscalePresetsNeedABiggerSource() {
        if case .available = CompressionPolicy.availability(of: .hevc1080, for: info(w: 1920, h: 1080)) {
            Issue.record("1080p source shouldn't offer the 1080p preset")
        }
    }

    @Test func largerOutputIsNeverReportedAsSaving() {
        #expect(CompressionPolicy.verdict(sourceBytes: 100, outputBytes: 120) == .notSmaller)
        #expect(CompressionPolicy.verdict(sourceBytes: nil, outputBytes: 50) == .notSmaller)
        #expect(CompressionPolicy.verdict(sourceBytes: 100, outputBytes: 40) == .smaller(saving: 60))
    }

    @Test func diskSpaceCheck() {
        #expect(!CompressionPolicy.hasSpace(available: 100_000_000, estimatedOutput: 200_000_000, sourceBytes: nil))
        #expect(CompressionPolicy.hasSpace(available: 5_000_000_000, estimatedOutput: 200_000_000, sourceBytes: nil))
    }

    @Test func monthSectionsAreContiguous() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let d = { (m: Int, day: Int) in c.date(from: DateComponents(year: 2026, month: m, day: day))! }
        let sections = LibraryIndex.months(dates: [d(9, 20), d(9, 1), d(8, 31), nil, d(7, 4)], calendar: c)
        #expect(sections.map(\.key) == ["2026-09", "2026-08", "undated", "2026-07"])
        #expect(sections.map(\.range) == [0..<2, 2..<3, 3..<4, 4..<5])
    }
}
