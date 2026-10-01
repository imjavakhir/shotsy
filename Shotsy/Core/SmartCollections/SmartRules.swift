import Foundation

nonisolated enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo, video, screenshot, livePhoto

    var title: LocalizedStringResource {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .screenshot: "Screenshot"
        case .livePhoto: "Live Photo"
        }
    }
}

nonisolated enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed, kept, marked

    var title: LocalizedStringResource {
        switch self {
        case .unreviewed: "Unreviewed"
        case .kept: "Kept"
        case .marked: "Marked for deletion"
        }
    }
}

/// A saved live-filter rule. Shotsy metadata only; never synced to Apple Photos.
nonisolated enum SmartRule: Codable, Hashable, Sendable {
    case mediaType(MediaKind)
    case newerThanDays(Int)
    case olderThanDays(Int)
    case dateRange(start: Date, end: Date)
    case favorite(Bool)
    case reviewStatus(ReviewStatus)
    case inAlbum(id: String, title: String)
    case screenshotCategory(ScreenshotCategory)
    case screenshotLabel(String)
    case pinned
    case person(id: UUID, name: String)
    case videoLongerThan(seconds: Double)
    case videoLargerThan(bytes: Int64)
}

nonisolated enum Tri: Equatable, Sendable {
    case yes, no, unknown
}

/// What a rule can know about one asset.
nonisolated struct AssetFacts: Sendable {
    var id: String
    var isVideo: Bool
    var isScreenshot: Bool
    var isLivePhoto: Bool
    var creationDate: Date?
    var isFavorite: Bool
    var duration: TimeInterval
}

/// Lookup tables for rules that depend on Shotsy's local index. Missing entries mean "unknown", not "no".
nonisolated struct RuleContext: Sendable {
    var now: Date = .now
    var calendar: Calendar = .current
    var decisions: [String: ReviewDecision] = [:]
    /// nil value = album inaccessible or deleted.
    var albumMembers: [String: Set<String>?] = [:]
    /// Effective screenshot category; absent for screenshots not yet indexed.
    var screenshotCategories: [String: ScreenshotCategory] = [:]
    var screenshotLabels: [String: [String]] = [:]
    var pinned: Set<String> = []
    var personAssets: [UUID: Set<String>] = [:]
    var videoBytes: [String: Int64] = [:]
}

nonisolated struct RuleIssue: Hashable, Sendable {
    var message: String
}

nonisolated enum SmartRuleEngine {
    static func evaluate(_ rule: SmartRule, _ a: AssetFacts, _ ctx: RuleContext) -> Tri {
        switch rule {
        case .mediaType(let kind):
            switch kind {
            case .video: return a.isVideo ? .yes : .no
            case .screenshot: return a.isScreenshot ? .yes : .no
            case .livePhoto: return a.isLivePhoto ? .yes : .no
            case .photo: return (!a.isVideo && !a.isScreenshot) ? .yes : .no
            }
        case .newerThanDays(let days):
            guard let date = a.creationDate else { return .unknown }
            let cutoff = ctx.calendar.date(byAdding: .day, value: -days, to: ctx.now) ?? ctx.now
            return date >= cutoff ? .yes : .no
        case .olderThanDays(let days):
            guard let date = a.creationDate else { return .unknown }
            let cutoff = ctx.calendar.date(byAdding: .day, value: -days, to: ctx.now) ?? ctx.now
            return date < cutoff ? .yes : .no
        case .dateRange(let start, let end):
            guard let date = a.creationDate else { return .unknown }
            let endOfDay = ctx.calendar.date(byAdding: .day, value: 1, to: ctx.calendar.startOfDay(for: end)) ?? end
            return (date >= ctx.calendar.startOfDay(for: start) && date < endOfDay) ? .yes : .no
        case .favorite(let wanted):
            return a.isFavorite == wanted ? .yes : .no
        case .reviewStatus(let status):
            let d = ctx.decisions[a.id]
            switch status {
            case .unreviewed: return d == nil ? .yes : .no
            case .kept: return d == .keep ? .yes : .no
            case .marked: return d == .marked ? .yes : .no
            }
        case .inAlbum(let id, _):
            guard let entry = ctx.albumMembers[id], let members = entry else { return .unknown }
            return members.contains(a.id) ? .yes : .no
        case .screenshotCategory(let category):
            guard a.isScreenshot else { return .no }
            guard let c = ctx.screenshotCategories[a.id] else { return .unknown }
            return c == category ? .yes : .no
        case .screenshotLabel(let label):
            guard a.isScreenshot else { return .no }
            return (ctx.screenshotLabels[a.id] ?? []).contains(label) ? .yes : .no
        case .pinned:
            return ctx.pinned.contains(a.id) ? .yes : .no
        case .person(let id, _):
            guard let assets = ctx.personAssets[id] else { return .unknown }
            return assets.contains(a.id) ? .yes : .no
        case .videoLongerThan(let seconds):
            guard a.isVideo else { return .no }
            return a.duration > seconds ? .yes : .no
        case .videoLargerThan(let bytes):
            guard a.isVideo else { return .no }
            guard let size = ctx.videoBytes[a.id] else { return .unknown }
            return size > bytes ? .yes : .no
        }
    }

    /// ALL: any "no" → no; else any "unknown" → unknown; else yes.
    /// ANY: any "yes" → yes; else any "unknown" → unknown; else no.
    static func evaluate(_ rules: [SmartRule], matchAll: Bool, _ a: AssetFacts, _ ctx: RuleContext) -> Tri {
        guard !rules.isEmpty else { return .no }
        var sawUnknown = false
        for rule in rules {
            switch evaluate(rule, a, ctx) {
            case .yes where !matchAll: return .yes
            case .no where matchAll: return .no
            case .unknown: sawUnknown = true
            default: break
            }
        }
        if sawUnknown { return .unknown }
        return matchAll ? .yes : .no
    }

    /// Rule combinations that can never match (ALL) or are malformed.
    static func validate(_ rules: [SmartRule], matchAll: Bool) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        if rules.isEmpty { issues.append(RuleIssue(message: String(localized: "Add at least one rule."))) }
        guard matchAll else { return issues }
        let kinds = rules.compactMap { if case .mediaType(let k) = $0 { k } else { nil } }
        if Set(kinds).count > 1 {
            issues.append(RuleIssue(message: String(localized: "An item can't be two media types at once. Use Any, or keep one type.")))
        }
        let wantsVideo = rules.contains { if case .videoLongerThan = $0 { true } else if case .videoLargerThan = $0 { true } else { false } }
        let wantsScreenshot = rules.contains { if case .screenshotCategory = $0 { true } else if case .screenshotLabel = $0 { true } else { false } }
        if wantsVideo && wantsScreenshot {
            issues.append(RuleIssue(message: String(localized: "Video rules and screenshot rules can't both match the same item.")))
        }
        if wantsVideo, kinds.contains(where: { $0 != .video }) {
            issues.append(RuleIssue(message: String(localized: "Video length or size rules need the Video type.")))
        }
        if wantsScreenshot, kinds.contains(where: { $0 != .screenshot }) {
            issues.append(RuleIssue(message: String(localized: "Screenshot rules need the Screenshot type.")))
        }
        let newer = rules.compactMap { if case .newerThanDays(let d) = $0 { d } else { nil } }.min()
        let older = rules.compactMap { if case .olderThanDays(let d) = $0 { d } else { nil } }.max()
        if let newer, let older, older >= newer {
            issues.append(RuleIssue(message: String(localized: "\"Newer than\" and \"older than\" don't overlap.")))
        }
        let statuses = rules.compactMap { if case .reviewStatus(let s) = $0 { s } else { nil } }
        if Set(statuses).count > 1 {
            issues.append(RuleIssue(message: String(localized: "An item has only one review status.")))
        }
        let favs = rules.compactMap { if case .favorite(let f) = $0 { f } else { nil } }
        if Set(favs).count > 1 {
            issues.append(RuleIssue(message: String(localized: "Favorite and not favorite can't both match.")))
        }
        return issues
    }

    static func describe(_ rule: SmartRule) -> String {
        switch rule {
        case .mediaType(let k): return String(localized: "Type is \(String(localized: k.title))")
        case .newerThanDays(let d): return String(localized: "Newer than \(d) days")
        case .olderThanDays(let d): return String(localized: "Older than \(d) days")
        case .dateRange(let s, let e):
            return String(localized: "From \(s.formatted(date: .abbreviated, time: .omitted)) to \(e.formatted(date: .abbreviated, time: .omitted))")
        case .favorite(let f): return f ? String(localized: "Is a favorite") : String(localized: "Is not a favorite")
        case .reviewStatus(let s): return String(localized: "Status is \(String(localized: s.title))")
        case .inAlbum(_, let title): return String(localized: "In album \"\(title)\"")
        case .screenshotCategory(let c): return String(localized: "Screenshot category is \(String(localized: c.title))")
        case .screenshotLabel(let l): return String(localized: "Screenshot label is \"\(l)\"")
        case .pinned: return String(localized: "Pinned screenshot")
        case .person(_, let name): return String(localized: "Includes \(name)")
        case .videoLongerThan(let s): return String(localized: "Video longer than \(AssetDescription.duration(s))")
        case .videoLargerThan(let b):
            return String(localized: "Video larger than \(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))")
        }
    }
}

nonisolated struct SmartMatchResult: Sendable, Equatable {
    var matches: [String]
    /// Items that couldn't be checked (e.g. not indexed yet, size unknown).
    var unknown: Int
}
