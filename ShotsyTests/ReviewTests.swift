import Foundation
import SwiftData
import Testing
@testable import Shotsy

private let day = "2026-09-28"
private let policy = Policy(freeDailyReviews: 3, freeSmartCollections: 1, quickSessionSize: 20)

@Suite("Swipe, undo and quota")
struct ReviewLedgerTests {
    @Test func keepMarkSkipRecordDecisionsAndAdvance() throws {
        var ledger = ReviewLedger()
        var session = SessionState(assetIDs: ["a", "b", "c"])
        try ledger.apply(.keep, to: &session, day: day, policy: policy, isPro: false)
        try ledger.apply(.mark, to: &session, day: day, policy: policy, isPro: false)
        try ledger.apply(.skip, to: &session, day: day, policy: policy, isPro: false)
        #expect(ledger.decisions == ["a": .keep, "b": .marked])
        #expect(session.isFinished)
        #expect(session.keptCount == 1 && session.markedCount == 1 && session.skippedCount == 1)
        #expect(ledger.reviewsUsed(on: day) == 2, "Skip must not consume quota")
    }

    @Test func undoRestoresPreviousDecisionAndGivesQuotaBack() throws {
        var ledger = ReviewLedger()
        ledger.decisions["a"] = .keep // decided earlier, elsewhere
        var session = SessionState(assetIDs: ["a", "b"])
        try ledger.apply(.mark, to: &session, day: day, policy: policy, isPro: false)
        #expect(ledger.decisions["a"] == .marked)
        ledger.undo(in: &session)
        #expect(ledger.decisions["a"] == .keep)
        #expect(session.position == 0)
        #expect(session.outcomes["a"] == nil)
        #expect(ledger.reviewsUsed(on: day) == 0)
    }

    @Test func undoThenRedoDoesNotDoubleCount() throws {
        var ledger = ReviewLedger()
        var session = SessionState(assetIDs: ["a", "b"])
        try ledger.apply(.keep, to: &session, day: day, policy: policy, isPro: false)
        ledger.undo(in: &session)
        try ledger.apply(.mark, to: &session, day: day, policy: policy, isPro: false)
        #expect(ledger.reviewsUsed(on: day) == 1)
    }

    @Test func dailyLimitBlocksNewDecisionsButNotUndoOrSkip() throws {
        var ledger = ReviewLedger()
        var session = SessionState(assetIDs: ["a", "b", "c", "d", "e"])
        for _ in 0..<3 { try ledger.apply(.keep, to: &session, day: day, policy: policy, isPro: false) }
        #expect(throws: ReviewError.dailyLimitReached(limit: 3)) {
            try ledger.apply(.mark, to: &session, day: day, policy: policy, isPro: false)
        }
        #expect(session.position == 3, "A blocked decision must not advance")
        try ledger.apply(.skip, to: &session, day: day, policy: policy, isPro: false)
        ledger.undo(in: &session) // undo skip
        ledger.undo(in: &session) // undo a counted keep, always allowed
        #expect(ledger.reviewsUsed(on: day) == 2)
        try ledger.apply(.mark, to: &session, day: day, policy: policy, isPro: false)
    }

    @Test func proHasNoLimit() throws {
        var ledger = ReviewLedger()
        var session = SessionState(assetIDs: (0..<10).map(String.init))
        for _ in 0..<10 { try ledger.apply(.keep, to: &session, day: day, policy: policy, isPro: true) }
        #expect(session.isFinished)
        #expect(ledger.remainingReviews(on: day, policy: policy, isPro: true) == nil)
    }

    @Test func quotaIsSharedAcrossEntryPoints() throws {
        var ledger = ReviewLedger()
        try ledger.decide(.marked, for: ["x", "y"], day: day, policy: policy, isPro: false) // library selection
        var quick = SessionState(assetIDs: ["z", "w"])
        try ledger.apply(.keep, to: &quick, day: day, policy: policy, isPro: false)     // Quick 20
        #expect(throws: ReviewError.dailyLimitReached(limit: 3)) {
            try ledger.apply(.keep, to: &quick, day: day, policy: policy, isPro: false)
        }
    }

    @Test func redecidingSameAssetTodayIsFree() throws {
        var ledger = ReviewLedger()
        try ledger.decide(.marked, for: ["a", "b", "c"], day: day, policy: policy, isPro: false)
        try ledger.decide(.keep, for: ["a"], day: day, policy: policy, isPro: false)
        #expect(ledger.reviewsUsed(on: day) == 3)
    }

    @Test func batchOverLimitIsRejectedAtomically() {
        var ledger = ReviewLedger()
        #expect(throws: ReviewError.dailyLimitReached(limit: 3)) {
            try ledger.decide(.marked, for: ["a", "b", "c", "d"], day: day, policy: policy, isPro: false)
        }
        #expect(ledger.decisions.isEmpty)
    }

    @Test func unmarkIsNeverBlockedOrCounted() throws {
        var ledger = ReviewLedger()
        try ledger.decide(.marked, for: ["a", "b", "c"], day: day, policy: policy, isPro: false)
        ledger.unmark(["a"])
        #expect(ledger.decisions["a"] == .keep)
        #expect(ledger.reviewsUsed(on: day) == 3)
        #expect(Set(ledger.pendingIDs) == ["b", "c"])
    }

    @Test func assetInSeveralCategoriesIsQueuedOnce() throws {
        var ledger = ReviewLedger()
        try ledger.decide(.marked, for: ["a", "a"], day: day, policy: policy, isPro: true)
        try ledger.decide(.marked, for: ["a"], day: day, policy: policy, isPro: true) // from another category
        #expect(ledger.pendingIDs == ["a"])
    }
}

@Suite("Sessions")
struct SessionTests {
    @Test func sessionDeduplicatesKeepingOrder() {
        #expect(SessionState(assetIDs: ["a", "b", "a", "c", "b"]).assetIDs == ["a", "b", "c"])
    }

    @Test func disappearingAssetsKeepThePlace() {
        var s = SessionState(assetIDs: ["a", "b", "c", "d", "e"])
        s.position = 3 // on "d"
        s.outcomes = ["a": .keep, "b": .mark, "c": .skip]
        s.history = [SessionHistoryEntry(assetID: "b", outcome: .mark)]
        s.remove(["b", "e"])
        #expect(s.assetIDs == ["a", "c", "d"])
        #expect(s.currentID == "d")
        #expect(s.outcomes["b"] == nil)
        #expect(s.history.isEmpty)
    }

    @Test func removingCurrentAssetMovesToNext() {
        var s = SessionState(assetIDs: ["a", "b", "c"])
        s.position = 1
        s.remove(["b"])
        #expect(s.currentID == "c")
    }

    @Test func quick20IsFrozenDedupedUnreviewedAndCapped() {
        var ledger = ReviewLedger()
        ledger.decisions = ["r1": .keep, "m1": .marked]
        let candidates = ["r1", "a", "m1", "a", "b"] + (0..<30).map { "n\($0)" }
        let ids = SessionBuilder.quick(from: candidates, ledger: ledger, limit: 20, remainingQuota: nil)
        #expect(ids.count == 20)
        #expect(Set(ids).count == 20)
        #expect(!ids.contains("r1") && !ids.contains("m1"))
        #expect(ids.prefix(2) == ["a", "b"])
    }

    @Test func quick20ShrinksToRemainingAllowance() {
        let ids = SessionBuilder.quick(from: (0..<50).map(String.init), ledger: ReviewLedger(), limit: 20, remainingQuota: 7)
        #expect(ids.count == 7)
        #expect(SessionBuilder.quick(from: ["a"], ledger: ReviewLedger(), limit: 20, remainingQuota: 0).isEmpty)
    }

    @Test func quick20WithNothingEligibleIsEmpty() {
        var ledger = ReviewLedger()
        ledger.decisions = ["a": .keep, "b": .marked]
        #expect(SessionBuilder.quick(from: ["a", "b"], ledger: ledger, limit: 20, remainingQuota: nil).isEmpty)
    }
}

@Suite("Review store persistence") @MainActor
struct ReviewStoreTests {
    @Test func decisionsAndSessionPositionSurviveRelaunch() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        store.isPro = { true }
        let session = store.createSession(kind: .quick20, title: "Quick 20", assetIDs: ["a", "b", "c"])
        try store.apply(.keep, in: session)
        try store.apply(.mark, in: session)

        let relaunched = ReviewStore(context: ModelContext(container))
        #expect(relaunched.decision(for: "a") == .keep)
        #expect(relaunched.decision(for: "b") == .marked)
        let reloaded = try #require(relaunched.session(id: session.id))
        #expect(relaunched.state(of: reloaded).position == 2)
        #expect(relaunched.latestUnfinished()?.id == session.id)
    }

    @Test func forgetDropsDeletedAssetsFromQueueAndSessions() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        store.isPro = { true }
        let session = store.createSession(kind: .month, title: "Sept", assetIDs: ["a", "b", "c"])
        try store.apply(.mark, in: session)
        store.forget(["a"])
        #expect(store.pendingIDs.isEmpty)
        #expect(store.state(of: session).assetIDs == ["b", "c"])
        #expect(store.state(of: session).currentID == "b")
    }

    @Test func cancelledDeletionKeepsSelections() throws {
        // The view only calls forget() after .deleted; a cancelled/failed outcome leaves the queue as is.
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        store.isPro = { true }
        try store.decide(.marked, ids: ["a", "b"])
        let outcome = DeletionOutcome.cancelled
        if case .deleted = outcome { store.forget(["a", "b"]) }
        #expect(Set(store.pendingIDs) == ["a", "b"])
    }
}

@Suite("Review store incremental sync") @MainActor
struct ReviewStoreSyncTests {
    /// Persisted decision records, the cached queue and a fresh relaunch must all agree with the ledger.
    func expectInSync(_ store: ReviewStore, _ container: ModelContainer) throws {
        let records = try container.mainContext.fetch(FetchDescriptor<DecisionRecord>())
        let persisted = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, ReviewDecision(rawValue: $0.decisionRaw)) })
        #expect(persisted == store.ledger.decisions.mapValues { Optional($0) })
        #expect(Set(store.pendingIDs) == Set(store.ledger.pendingIDs))
        #expect(store.pendingIDs.count == store.ledger.pendingIDs.count)
        #expect(store.pendingCount == store.ledger.pendingIDs.count)
        let relaunched = ReviewStore(context: ModelContext(container))
        #expect(relaunched.ledger.decisions == store.ledger.decisions)
        // Same queue; items decided in one call share a timestamp, so only their relative order may differ.
        #expect(Set(relaunched.pendingIDs) == Set(store.pendingIDs))
    }

    @Test func ledgerReportsOnlyChangedDecisions() throws {
        var ledger = ReviewLedger()
        let first = try ledger.decide(.marked, for: ["a", "b", "a"], day: day, policy: policy, isPro: true)
        #expect(Set(first.map(\.assetID)) == ["a", "b"])
        #expect(first.allSatisfy { $0.previous == nil && $0.current == .marked })
        #expect(try ledger.decide(.marked, for: ["a"], day: day, policy: policy, isPro: true).isEmpty)
        #expect(ledger.unmark(["a", "c"]) == [DecisionChange(assetID: "a", previous: .marked, current: .keep)])
        #expect(ledger.forget(["b", "zz"]) == [DecisionChange(assetID: "b", previous: .marked, current: nil)])
        var session = SessionState(assetIDs: ["a", "x"])
        #expect(try ledger.apply(.keep, to: &session, day: day, policy: policy, isPro: true).isEmpty) // already kept
        #expect(try ledger.apply(.skip, to: &session, day: day, policy: policy, isPro: true).isEmpty)
        #expect(ledger.undo(in: &session).isEmpty)
        #expect(ledger.undo(in: &session).isEmpty) // "a" was kept before and after
        #expect(try ledger.apply(.mark, to: &session, day: day, policy: policy, isPro: true)
                == [DecisionChange(assetID: "a", previous: .keep, current: .marked)])
        #expect(ledger.undo(in: &session) == [DecisionChange(assetID: "a", previous: .marked, current: .keep)])
    }

    @Test func persistedRecordsMatchLedgerAfterEveryOperation() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        store.isPro = { true }
        let session = store.createSession(kind: .quick20, title: "Quick 20", assetIDs: ["a", "b", "c", "d"])

        try store.apply(.mark, in: session)
        try store.apply(.keep, in: session)
        try store.apply(.mark, in: session)
        try expectInSync(store, container)
        #expect(store.pendingIDs == ["a", "c"])

        store.undo(in: session) // c back to unreviewed
        try expectInSync(store, container)
        #expect(store.pendingIDs == ["a"])

        try store.decide(.marked, ids: ["b", "x", "y"])
        try expectInSync(store, container)
        #expect(store.pendingIDs.first == "a")
        #expect(store.pendingCount == 4)

        try store.decide(.marked, ids: ["a"]) // unchanged: keeps its place in the queue
        #expect(store.pendingIDs.first == "a")

        store.unmark(["a", "x", "nothing"])
        try expectInSync(store, container)
        #expect(store.decision(for: "a") == .keep)
        #expect(Set(store.pendingIDs) == ["b", "y"])

        store.forget(["b", "a", "missing"])
        try expectInSync(store, container)
        #expect(store.decision(for: "a") == nil)
        #expect(store.pendingIDs == ["y"])

        store.resetHistory()
        try expectInSync(store, container)
        #expect(store.pendingCount == 0)
    }

    @Test func undoRestoringAMarkMovesItToTheEndOfTheQueue() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        store.isPro = { true }
        try store.decide(.marked, ids: ["a"])
        let session = store.createSession(kind: .month, title: "Sept", assetIDs: ["a", "b"])
        try store.decide(.marked, ids: ["b"])
        try store.apply(.keep, in: session) // a: marked -> keep
        #expect(store.pendingIDs == ["b"])
        store.undo(in: session) // a: keep -> marked, decided now
        #expect(store.pendingIDs == ["b", "a"])
        try expectInSync(store, container)
    }

    @Test func dailyQuotaLogFollowsApplyAndUndo() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        let session = store.createSession(kind: .quick20, title: "Quick 20", assetIDs: ["a", "b"])
        try store.apply(.keep, in: session)
        try store.apply(.mark, in: session)
        #expect(store.usedToday == 2)
        store.undo(in: session)
        #expect(store.usedToday == 1)
        let relaunched = ReviewStore(context: ModelContext(container))
        #expect(relaunched.usedToday == 1)
    }

    @Test func cachedSessionStateTracksSavesAndResets() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = ReviewStore(context: container.mainContext)
        store.isPro = { true }
        let session = store.createSession(kind: .month, title: "Sept", assetIDs: ["a", "b", "c"])
        #expect(store.state(of: session).position == 0)
        func decoded() throws -> SessionState { try JSONDecoder().decode(SessionState.self, from: session.stateData) }

        try store.apply(.keep, in: session)
        #expect(store.state(of: session).position == 1)
        #expect(try store.state(of: session) == decoded())

        store.undo(in: session)
        #expect(store.state(of: session).position == 0)
        #expect(try store.state(of: session) == decoded())

        store.forget(["a"])
        #expect(store.state(of: session).assetIDs == ["b", "c"])
        #expect(try store.state(of: session) == decoded())

        // A write that bypasses the store (new data and timestamp) is picked up, not served stale.
        var external = try decoded()
        external.position = 2
        session.stateData = try JSONEncoder().encode(external)
        session.updatedAt = .now.addingTimeInterval(1)
        #expect(store.state(of: session).position == 2)

        store.resetHistory()
        let fresh = store.createSession(kind: .month, title: "Oct", assetIDs: ["z"])
        #expect(store.state(of: fresh).assetIDs == ["z"])
    }
}

@Suite("Deletion planning")
struct DeletionPlanTests {
    @Test func revalidationSeparatesMissingAndNotAllowed() {
        let plan = DeletionPlan.make(requested: ["a", "b", "c", "a", "d"], present: ["a": true, "c": false, "d": true])
        #expect(plan.deletable == ["a", "d"])
        #expect(plan.missing == ["b"])
        #expect(plan.notAllowed == ["c"])
    }

    @Test func nothingDeletableIsEmpty() {
        #expect(DeletionPlan.make(requested: ["x"], present: [:]).isEmpty)
    }
}
