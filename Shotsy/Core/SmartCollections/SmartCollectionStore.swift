import Foundation
import SwiftData

struct SmartCollection: Identifiable, Hashable {
    var id: UUID
    var name: String
    var matchAll: Bool
    var rules: [SmartRule]
}

/// Saved live filters. Kept after Pro expires; only creating more than the free limit is gated.
@Observable
final class SmartCollectionStore {
    private let context: ModelContext
    private(set) var collections: [SmartCollection] = []

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        let records = (try? context.fetch(FetchDescriptor<SmartCollectionRecord>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        collections = records.map { r in
            SmartCollection(id: r.id, name: r.name, matchAll: r.matchAll,
                            rules: (try? JSONDecoder().decode([SmartRule].self, from: r.rulesData)) ?? [])
        }
    }

    func canCreate(isPro: Bool) -> Bool {
        isPro || collections.count < Policy.current.freeSmartCollections
    }

    func save(_ collection: SmartCollection) {
        let data = (try? JSONEncoder().encode(collection.rules)) ?? Data()
        let id = collection.id
        var d = FetchDescriptor<SmartCollectionRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let existing = try? context.fetch(d).first {
            existing.name = collection.name
            existing.matchAll = collection.matchAll
            existing.rulesData = data
        } else {
            context.insert(SmartCollectionRecord(id: collection.id, name: collection.name,
                                                 matchAll: collection.matchAll, rulesData: data,
                                                 sortIndex: collections.count))
        }
        try? context.save()
        reload()
    }

    func delete(_ collection: SmartCollection) {
        let id = collection.id
        try? context.delete(model: SmartCollectionRecord.self, where: #Predicate { $0.id == id })
        try? context.save()
        reload()
    }

    /// Evaluates off the main thread. `facts` and `context` are snapshots built by the caller.
    static func evaluate(_ collection: SmartCollection, facts: [AssetFacts], context: RuleContext) async -> SmartMatchResult {
        await Task.detached(priority: .userInitiated) {
            var matches: [String] = []
            var unknown = 0
            for a in facts {
                switch SmartRuleEngine.evaluate(collection.rules, matchAll: collection.matchAll, a, context) {
                case .yes: matches.append(a.id)
                case .unknown: unknown += 1
                case .no: break
                }
            }
            return SmartMatchResult(matches: matches, unknown: unknown)
        }.value
    }

    static let examples: [SmartCollection] = [
        SmartCollection(id: UUID(), name: String(localized: "Unreviewed this month"), matchAll: true,
                        rules: [.reviewStatus(.unreviewed), .newerThanDays(30)]),
        SmartCollection(id: UUID(), name: String(localized: "Screenshots older than 30 days"), matchAll: true,
                        rules: [.mediaType(.screenshot), .olderThanDays(30)]),
        SmartCollection(id: UUID(), name: String(localized: "Pinned receipts"), matchAll: true,
                        rules: [.pinned, .screenshotCategory(.receipts)]),
        SmartCollection(id: UUID(), name: String(localized: "Long videos"), matchAll: true,
                        rules: [.mediaType(.video), .videoLongerThan(seconds: 120)]),
    ]
}
