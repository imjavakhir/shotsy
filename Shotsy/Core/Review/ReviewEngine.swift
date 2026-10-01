import Foundation

/// A persisted per-asset review decision. "Unreviewed" means no decision.
nonisolated enum ReviewDecision: String, Codable, Sendable, CaseIterable {
    case keep
    /// In Shotsy's pending queue. The Photos asset is untouched until confirmed deletion.
    case marked
}

/// What happened to one item in a session. Skip leaves the asset unreviewed.
nonisolated enum SessionOutcome: String, Codable, Sendable {
    case keep, mark, skip

    var decision: ReviewDecision? {
        switch self {
        case .keep: .keep
        case .mark: .marked
        case .skip: nil
        }
    }
}

nonisolated enum SessionKind: String, Codable, Sendable {
    case month, quick20, category, onThisDay, screenshots, album
}

/// One undoable step.
nonisolated struct SessionHistoryEntry: Codable, Equatable, Sendable {
    var assetID: String
    var outcome: SessionOutcome
    /// The asset's decision before this step (restored on undo).
    var previousDecision: ReviewDecision?
    /// Day key if this step consumed free quota, so undo can give it back.
    var countedDay: String?
}

/// Frozen list of assets plus position, outcomes and undo history.
nonisolated struct SessionState: Codable, Equatable, Sendable {
    var assetIDs: [String]
    var position = 0
    var outcomes: [String: SessionOutcome] = [:]
    var history: [SessionHistoryEntry] = []

    init(assetIDs: [String]) {
        // Deduplicate while keeping order: an asset appears once per session.
        var seen = Set<String>()
        self.assetIDs = assetIDs.filter { seen.insert($0).inserted }
    }

    var isFinished: Bool { position >= assetIDs.count }
    var currentID: String? { assetIDs.indices.contains(position) ? assetIDs[position] : nil }
    var canUndo: Bool { !history.isEmpty }

    /// Drops assets that vanished from the library (deleted elsewhere, access revoked) while keeping
    /// the user's place: the position shifts back by the number of removed items before it.
    mutating func remove(_ removed: Set<String>) {
        guard assetIDs.contains(where: removed.contains) else { return }
        let removedBefore = assetIDs.prefix(position).filter(removed.contains).count
        assetIDs.removeAll(where: removed.contains)
        position = min(max(0, position - removedBefore), assetIDs.count)
        for id in removed { outcomes[id] = nil }
        history.removeAll { removed.contains($0.assetID) }
    }

    var keptCount: Int { outcomes.values.filter { $0 == .keep }.count }
    var markedCount: Int { outcomes.values.filter { $0 == .mark }.count }
    var skippedCount: Int { outcomes.values.filter { $0 == .skip }.count }
}

/// One asset whose decision an operation changed. `nil` means unreviewed.
/// Lets ReviewStore persist only what moved instead of diffing every decision.
nonisolated struct DecisionChange: Equatable, Sendable {
    var assetID: String
    var previous: ReviewDecision?
    var current: ReviewDecision?
}

nonisolated enum ReviewError: Error, Equatable {
    /// Free daily allowance used up. Undo, corrections and queued deletions still work.
    case dailyLimitReached(limit: Int)
    case sessionFinished
}

/// Pure review logic shared by every entry point (monthly sorting, Quick 20, categories, library).
/// ReviewStore persists it; tests exercise it directly.
nonisolated struct ReviewLedger: Equatable, Sendable {
    var decisions: [String: ReviewDecision] = [:]
    /// Unique asset IDs that consumed free quota, per local day key ("2026-09-28").
    var dailyReviews: [String: Set<String>] = [:]

    // MARK: Quota

    func reviewsUsed(on day: String) -> Int { dailyReviews[day]?.count ?? 0 }

    func remainingReviews(on day: String, policy: Policy, isPro: Bool) -> Int? {
        isPro ? nil : max(0, policy.freeDailyReviews - reviewsUsed(on: day))
    }

    /// Whether a new decision on `assetID` today is allowed. Re-deciding an asset already counted today is free.
    func canDecide(_ assetID: String, day: String, policy: Policy, isPro: Bool) -> Bool {
        if isPro { return true }
        if dailyReviews[day]?.contains(assetID) == true { return true }
        return reviewsUsed(on: day) < policy.freeDailyReviews
    }

    /// Records quota use; returns the day key if this call newly counted the asset.
    mutating func countReview(_ assetID: String, day: String, isPro: Bool) -> String? {
        guard !isPro else { return nil }
        return dailyReviews[day, default: []].insert(assetID).inserted ? day : nil
    }

    // MARK: Sessions

    /// Records `decision` for `id` and reports it if the value actually changed.
    private mutating func setDecision(_ decision: ReviewDecision?, for id: String, into changes: inout [DecisionChange]) {
        let previous = decisions[id]
        guard previous != decision else { return }
        decisions[id] = decision
        changes.append(DecisionChange(assetID: id, previous: previous, current: decision))
    }

    /// Applies a swipe/button outcome to the current item. Skip never consumes quota.
    /// Returns the decisions that changed.
    @discardableResult
    mutating func apply(_ outcome: SessionOutcome, to session: inout SessionState,
                        day: String, policy: Policy, isPro: Bool) throws -> [DecisionChange] {
        guard let id = session.currentID else { throw ReviewError.sessionFinished }
        var counted: String?
        if outcome != .skip {
            guard canDecide(id, day: day, policy: policy, isPro: isPro) else {
                throw ReviewError.dailyLimitReached(limit: policy.freeDailyReviews)
            }
            counted = countReview(id, day: day, isPro: isPro)
        }
        session.history.append(SessionHistoryEntry(assetID: id, outcome: outcome,
                                                   previousDecision: decisions[id], countedDay: counted))
        session.outcomes[id] = outcome
        var changes: [DecisionChange] = []
        if let decision = outcome.decision { setDecision(decision, for: id, into: &changes) }
        session.position += 1
        return changes
    }

    /// Undo is always allowed, even at the daily limit or after Pro expires. Returns the decisions that changed.
    @discardableResult
    mutating func undo(in session: inout SessionState) -> [DecisionChange] {
        guard let last = session.history.popLast() else { return [] }
        var changes: [DecisionChange] = []
        setDecision(last.previousDecision, for: last.assetID, into: &changes)
        session.outcomes[last.assetID] = nil
        if let day = last.countedDay {
            dailyReviews[day]?.remove(last.assetID)
        }
        if let index = session.assetIDs.firstIndex(of: last.assetID) {
            session.position = index
        } else {
            session.position = max(0, session.position - 1)
        }
        return changes
    }

    // MARK: Direct decisions (library, categories, review grid)

    /// Marks or keeps outside a session. Counts quota once per asset per day. Returns the decisions that changed.
    @discardableResult
    mutating func decide(_ decision: ReviewDecision, for ids: [String], day: String,
                         policy: Policy, isPro: Bool) throws -> [DecisionChange] {
        let unique = Array(Set(ids))
        if !isPro {
            let newOnes = unique.filter { dailyReviews[day]?.contains($0) != true }
            guard reviewsUsed(on: day) + newOnes.count <= policy.freeDailyReviews else {
                throw ReviewError.dailyLimitReached(limit: policy.freeDailyReviews)
            }
        }
        var changes: [DecisionChange] = []
        for id in unique {
            _ = countReview(id, day: day, isPro: isPro)
            setDecision(decision, for: id, into: &changes)
        }
        return changes
    }

    /// Deselecting in the review grid is a correction, not a new review: never blocked, never counted.
    @discardableResult
    mutating func unmark(_ ids: [String]) -> [DecisionChange] {
        var changes: [DecisionChange] = []
        for id in ids where decisions[id] == .marked {
            setDecision(.keep, for: id, into: &changes)
        }
        return changes
    }

    /// Clears decisions for assets that no longer exist or were deleted.
    @discardableResult
    mutating func forget(_ ids: some Sequence<String>) -> [DecisionChange] {
        var changes: [DecisionChange] = []
        for id in ids { setDecision(nil, for: id, into: &changes) }
        return changes
    }

    var pendingIDs: [String] { decisions.compactMap { $0.value == .marked ? $0.key : nil } }
}

nonisolated enum DayKey {
    /// Local calendar day, e.g. "2026-09-28". Uses the user's current calendar and time zone.
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

/// Builds frozen session lists.
nonisolated enum SessionBuilder {
    /// Up to `limit` eligible, unreviewed assets, deduplicated, excluding anything already queued for deletion.
    /// `candidates` should already be in the preferred order (newest first) and scoped to accessible assets.
    static func quick(from candidates: [String], ledger: ReviewLedger, limit: Int,
                      remainingQuota: Int?) -> [String] {
        let cap = min(limit, remainingQuota ?? limit)
        guard cap > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for id in candidates where ledger.decisions[id] == nil && seen.insert(id).inserted {
            result.append(id)
            if result.count == cap { break }
        }
        return result
    }

    /// Unreviewed assets for a month session; if everything is reviewed, returns an empty list.
    static func month(from monthAssets: [String], ledger: ReviewLedger) -> [String] {
        var seen = Set<String>()
        return monthAssets.filter { ledger.decisions[$0] == nil && seen.insert($0).inserted }
    }
}
