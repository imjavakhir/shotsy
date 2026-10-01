import Foundation
import SwiftData

/// Persists review decisions, sessions, and the free-quota log. Every entry point
/// (monthly sorting, Quick 20, categories, library, On This Day) goes through here.
@Observable
final class ReviewStore {
    private let context: ModelContext
    private(set) var ledger = ReviewLedger()
    /// Pending deletion queue, oldest decision first. Maintained incrementally from each operation's changes
    /// (a newly marked asset is always the newest), so reading it or its count never scans every decision.
    private(set) var pendingIDs: [String] = []
    @ObservationIgnored private var decisionRecords: [String: DecisionRecord] = [:]
    /// Decoded session states, so refreshing a view doesn't re-decode unchanged JSON. Keyed by session ID and
    /// checked against `updatedAt`; `save` refreshes an entry, deleting or resetting drops it.
    @ObservationIgnored private var stateCache: [UUID: (updatedAt: Date, state: SessionState)] = [:]

    @ObservationIgnored var isPro: () -> Bool = { false }
    @ObservationIgnored var policy = Policy.current
    /// Called after any change that affects progress (widget snapshot, etc).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Bumps whenever sessions change so views refresh.
    private(set) var revision = 0

    init(context: ModelContext) {
        self.context = context
        load()
    }

    private func load() {
        let decisions = (try? context.fetch(FetchDescriptor<DecisionRecord>())) ?? []
        var marked: [(id: String, at: Date)] = []
        for record in decisions {
            guard let decision = ReviewDecision(rawValue: record.decisionRaw) else { continue }
            ledger.decisions[record.assetID] = decision
            decisionRecords[record.assetID] = record
            if decision == .marked { marked.append((record.assetID, record.decidedAt)) }
        }
        pendingIDs = marked.sorted { $0.at < $1.at }.map(\.id)
        let today = Self.today
        let logs = (try? context.fetch(FetchDescriptor<DailyReviewRecord>())) ?? []
        for log in logs {
            if log.dayKey == today {
                ledger.dailyReviews[log.dayKey] = Set(log.assetIDs)
            } else {
                context.delete(log) // older days no longer matter
            }
        }
        try? context.save()
    }

    static var today: String { DayKey.key(for: .now) }

    // MARK: Queries

    func decision(for id: String) -> ReviewDecision? { ledger.decisions[id] }

    /// O(1): read by many views, including every frame of a sort-card drag.
    var pendingCount: Int { pendingIDs.count }
    var reviewedIDs: Set<String> { Set(ledger.decisions.keys) }

    /// `nil` means unlimited (Pro).
    var remainingToday: Int? {
        ledger.remainingReviews(on: Self.today, policy: policy, isPro: isPro())
    }

    var usedToday: Int { ledger.reviewsUsed(on: Self.today) }

    // MARK: Sessions

    func session(id: UUID) -> SessionRecord? {
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Most recently touched unfinished session.
    func latestUnfinished() -> SessionRecord? {
        var descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 10
        return (try? context.fetch(descriptor))?.first { !state(of: $0).isFinished }
    }

    func unfinishedMonthSession(monthKey: String) -> SessionRecord? {
        let kind = SessionKind.month.rawValue
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.completedAt == nil && $0.kindRaw == kind && $0.monthKey == monthKey },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.first { !state(of: $0).isFinished }
    }

    func state(of record: SessionRecord) -> SessionState {
        if let cached = stateCache[record.id], cached.updatedAt == record.updatedAt { return cached.state }
        let state = (try? JSONDecoder().decode(SessionState.self, from: record.stateData)) ?? SessionState(assetIDs: [])
        stateCache[record.id] = (record.updatedAt, state)
        return state
    }

    private func save(_ state: SessionState, to record: SessionRecord) {
        if let data = try? JSONEncoder().encode(state) {
            record.stateData = data
            record.updatedAt = .now
            stateCache[record.id] = (record.updatedAt, state)
        } else {
            // Encoding failed: the record keeps its old data, so the cache must not claim otherwise.
            record.updatedAt = .now
            stateCache[record.id] = nil
        }
        if state.isFinished, record.completedAt == nil { record.completedAt = .now }
        if !state.isFinished { record.completedAt = nil }
    }

    @discardableResult
    func createSession(kind: SessionKind, title: String, assetIDs: [String], monthKey: String? = nil) -> SessionRecord {
        let state = SessionState(assetIDs: assetIDs)
        let record = SessionRecord(kind: kind, title: title,
                                   state: (try? JSONEncoder().encode(state)) ?? Data(), monthKey: monthKey)
        context.insert(record)
        persist()
        return record
    }

    /// Applies Keep/Mark/Skip to the current item and saves immediately (survives termination).
    func apply(_ outcome: SessionOutcome, in record: SessionRecord) throws {
        var state = state(of: record)
        let today = Self.today
        let used = ledger.reviewsUsed(on: today)
        let changes = try ledger.apply(outcome, to: &state, day: today, policy: policy, isPro: isPro())
        save(state, to: record)
        syncDecisions(changes, quota: (today, used))
        persist()
    }

    /// Always allowed, including at the free limit.
    func undo(in record: SessionRecord) {
        var state = state(of: record)
        let today = Self.today
        let used = ledger.reviewsUsed(on: today)
        let changes = ledger.undo(in: &state)
        save(state, to: record)
        syncDecisions(changes, quota: (today, used))
        persist()
    }

    func finish(_ record: SessionRecord) {
        record.completedAt = record.completedAt ?? .now
        persist()
    }

    func deleteSession(_ record: SessionRecord) {
        stateCache[record.id] = nil
        context.delete(record)
        persist()
    }

    // MARK: Direct decisions

    func decide(_ decision: ReviewDecision, ids: [String]) throws {
        let today = Self.today
        let used = ledger.reviewsUsed(on: today)
        let changes = try ledger.decide(decision, for: ids, day: today, policy: policy, isPro: isPro())
        syncDecisions(changes, quota: (today, used))
        persist()
    }

    /// Take items out of the deletion queue (kept). A correction: never counted, never blocked.
    func unmark(_ ids: [String]) {
        syncDecisions(ledger.unmark(ids))
        persist()
    }

    /// After confirmed deletion or when assets disappear: drop decisions and prune sessions.
    func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        syncDecisions(ledger.forget(ids))
        let sessions = (try? context.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.completedAt == nil }))) ?? []
        for record in sessions {
            var state = state(of: record)
            let old = state
            state.remove(ids)
            if state != old { save(state, to: record) }
        }
        persist()
    }

    /// Clears review history (decisions, sessions). Never touches Photos.
    func resetHistory() {
        try? context.delete(model: DecisionRecord.self)
        try? context.delete(model: SessionRecord.self)
        ledger.decisions = [:]
        pendingIDs = []
        decisionRecords = [:]
        stateCache = [:]
        persist()
    }

    // MARK: Persistence

    /// Persists only the decisions an operation changed (never a scan of every decision), keeps `pendingIDs`
    /// in step, and writes the day's quota log when its count moved. `quota` is nil for operations that never
    /// touch quota (unmark, forget). One operation only adds to the day's set or only removes from it, so
    /// comparing counts is enough.
    private func syncDecisions(_ changes: [DecisionChange], quota: (day: String, usedBefore: Int)? = nil) {
        let now = Date.now
        var unqueued = Set<String>()
        for change in changes {
            let id = change.assetID
            if let decision = change.current {
                if let record = decisionRecords[id] {
                    record.decisionRaw = decision.rawValue
                    record.decidedAt = now
                } else {
                    let record = DecisionRecord(assetID: id, decision: decision, decidedAt: now)
                    context.insert(record)
                    decisionRecords[id] = record
                }
            } else if let record = decisionRecords.removeValue(forKey: id) {
                context.delete(record)
            }
            if change.previous == .marked { unqueued.insert(id) }
        }
        if !unqueued.isEmpty { pendingIDs.removeAll(where: unqueued.contains) }
        // Newly marked assets carry the newest timestamp, so they join the end of the queue.
        let queued = changes.filter { $0.current == .marked }.map(\.assetID)
        if !queued.isEmpty { pendingIDs.append(contentsOf: queued) }
        if let quota, quota.usedBefore != ledger.reviewsUsed(on: quota.day) {
            let today = quota.day
            let ids = Array(ledger.dailyReviews[today] ?? [])
            var descriptor = FetchDescriptor<DailyReviewRecord>(predicate: #Predicate { $0.dayKey == today })
            descriptor.fetchLimit = 1
            if let log = try? context.fetch(descriptor).first {
                log.assetIDs = ids
            } else {
                context.insert(DailyReviewRecord(dayKey: today, assetIDs: ids))
            }
        }
    }

    private func persist() {
        try? context.save()
        revision += 1
        onChange?()
    }
}
