import Foundation
import SwiftData

/// Screenshot Inbox metadata. Labels, pins and category corrections are local Shotsy metadata,
/// never Apple Photos categories. Corrections live in the main store and survive rescans.
@Observable
final class ScreenshotStore {
    private let context: ModelContext
    private(set) var revision = 0

    init(context: ModelContext) {
        self.context = context
    }

    func meta(for id: String) -> ScreenshotMeta? {
        var d = FetchDescriptor<ScreenshotMeta>(predicate: #Predicate { $0.assetID == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func index(for id: String) -> ScreenshotIndexRecord? {
        var d = FetchDescriptor<ScreenshotIndexRecord>(predicate: #Predicate { $0.assetID == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func allMeta() -> [String: ScreenshotMeta] {
        let all = (try? context.fetch(FetchDescriptor<ScreenshotMeta>())) ?? []
        return Dictionary(all.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func allIndex() -> [String: ScreenshotIndexRecord] {
        let all = (try? context.fetch(FetchDescriptor<ScreenshotIndexRecord>())) ?? []
        return Dictionary(all.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func metaOrNew(_ id: String) -> ScreenshotMeta {
        if let m = meta(for: id) { return m }
        let m = ScreenshotMeta(assetID: id)
        context.insert(m)
        return m
    }

    /// Explicit correction. `nil` returns the screenshot to suggestions.
    func setCategory(_ category: ScreenshotCategory?, for ids: [String]) {
        for id in ids {
            let m = metaOrNew(id)
            m.userCategoryRaw = category?.rawValue
            m.updatedAt = .now
        }
        save()
    }

    func addLabel(_ label: String, to ids: [String]) {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        for id in ids {
            let m = metaOrNew(id)
            if !m.labels.contains(clean) { m.labels.append(clean) }
            m.updatedAt = .now
        }
        save()
    }

    func removeLabel(_ label: String, from id: String) {
        guard let m = meta(for: id) else { return }
        m.labels.removeAll { $0 == label }
        save()
    }

    func setPinned(_ pinned: Bool, for ids: [String]) {
        for id in ids { metaOrNew(id).isPinned = pinned }
        save()
    }

    var allLabels: [String] {
        let all = (try? context.fetch(FetchDescriptor<ScreenshotMeta>())) ?? []
        return Array(Set(all.flatMap(\.labels))).sorted()
    }

    /// OCR text search (Pro). Case- and diacritic-insensitive, fully on device.
    func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let d = FetchDescriptor<ScreenshotIndexRecord>(predicate: #Predicate { $0.text.localizedStandardContains(q) })
        return ((try? context.fetch(d)) ?? []).map(\.assetID)
    }

    func indexedCount() -> Int {
        let version = PersistenceController.ocrVersion
        return (try? context.fetchCount(FetchDescriptor<ScreenshotIndexRecord>(
            predicate: #Predicate { $0.ocrVersion >= version && !$0.failed }))) ?? 0
    }

    private func save() {
        try? context.save()
        revision += 1
    }

    // MARK: Background reads

    // Every change above is saved right away, so a fresh context on the same container sees what the main one does.

    /// Metadata and index state for every screenshot, read on a background context. OCR text is not loaded.
    func snapshot() async -> ScreenshotSnapshot {
        let container = context.container
        return await BackgroundFetch.run { Self.makeSnapshot(in: ModelContext(container)) }
    }

    /// `search(_:)` on a background context.
    func searchInBackground(_ query: String) async -> [String] {
        let container = context.container
        return await BackgroundFetch.run { Self.search(query, in: ModelContext(container)) }
    }

    nonisolated private static func makeSnapshot(in context: ModelContext) -> ScreenshotSnapshot {
        var snapshot = ScreenshotSnapshot()
        for m in (try? context.fetch(FetchDescriptor<ScreenshotMeta>())) ?? [] where snapshot.meta[m.assetID] == nil {
            snapshot.meta[m.assetID] = .init(userCategory: m.userCategoryRaw.flatMap(ScreenshotCategory.init(rawValue:)),
                                             labels: m.labels, isPinned: m.isPinned)
        }
        var d = FetchDescriptor<ScreenshotIndexRecord>()
        d.propertiesToFetch = [\.assetID, \.ocrVersion, \.suggestedCategoryRaw, \.failed]
        let version = PersistenceController.ocrVersion
        for r in (try? context.fetch(d)) ?? [] where snapshot.index[r.assetID] == nil {
            snapshot.index[r.assetID] = .init(suggested: r.suggestedCategoryRaw.flatMap(ScreenshotCategory.init(rawValue:)),
                                              failed: r.failed)
            if r.ocrVersion >= version && !r.failed { snapshot.indexedCount += 1 }
        }
        return snapshot
    }

    nonisolated private static func search(_ query: String, in context: ModelContext) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var d = FetchDescriptor<ScreenshotIndexRecord>(predicate: #Predicate { $0.text.localizedStandardContains(q) })
        d.propertiesToFetch = [\.assetID]
        return ((try? context.fetch(d)) ?? []).map(\.assetID)
    }
}

/// Value copy of the screenshot metadata and index, safe to build off the main thread.
nonisolated struct ScreenshotSnapshot: Sendable {
    struct Meta: Sendable {
        var userCategory: ScreenshotCategory?
        var labels: [String]
        var isPinned: Bool
    }

    struct Index: Sendable {
        var suggested: ScreenshotCategory?
        var failed: Bool
    }

    var meta: [String: Meta] = [:]
    var index: [String: Index] = [:]
    /// Same as `ScreenshotStore.indexedCount()`.
    var indexedCount = 0

    /// Same as `ScreenshotStore.allLabels`.
    var labels: [String] { Array(Set(meta.values.flatMap(\.labels))).sorted() }

    func category(of id: String, suggestionsEnabled: Bool) -> ScreenshotCategory? {
        ScreenshotClassifier.effectiveCategory(userCategory: meta[id]?.userCategory, suggested: index[id]?.suggested,
                                               suggestionsEnabled: suggestionsEnabled)
    }
}
