import Foundation
import Photos
import SwiftData

/// Background indexing on its own model context. Processes small batches, saves as it goes
/// (so progress survives interruption), and checks for cancellation between items.
@ModelActor
actor AnalysisWorker {
    struct Progress: Sendable {
        var done: Int
        var total: Int
        var unavailable: Int
    }

    /// Items that failed or had no local data during this launch. They're retried on the next launch,
    /// not on every library change or return to the app.
    private var failedThisLaunch = Set<String>()

    // MARK: Photo analysis (similarity + blur)

    /// IDs among `ids` that still need analysis at the current version (new, changed, or outdated).
    func photosNeedingAnalysis(_ items: [(id: String, modified: Date?)]) -> [String] {
        let records = (try? modelContext.fetch(FetchDescriptor<AnalysisRecord>())) ?? []
        var current: [String: (Int, Date?)] = [:]
        for r in records { current[r.assetID] = (r.version, r.assetModifiedAt) }
        return items.compactMap { item in
            if failedThisLaunch.contains(item.id) { return nil }
            guard let (version, modified) = current[item.id] else { return item.id }
            if version < PersistenceController.analysisVersion { return item.id }
            if let m = item.modified, let old = modified, m > old { return item.id }
            return nil
        }
    }

    func analyzePhotos(_ ids: [String], progress: @Sendable (Progress) async -> Void) async {
        var done = 0, unavailable = 0
        for batch in ids.chunked(into: 24) {
            if Task.isCancelled { break }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
            var list: [PHAsset] = []
            assets.enumerateObjects { a, _, _ in list.append(a) }
            for asset in list {
                if Task.isCancelled { break }
                let record = record(for: asset.localIdentifier)
                record.version = PersistenceController.analysisVersion
                record.assetModifiedAt = asset.modificationDate
                record.analyzedAt = .now
                if let image = ImageAnalyzer.localImage(for: asset, maxSide: 384) {
                    record.unavailable = false
                    if let vector = await ImageAnalyzer.featureVectorForScan(image), !vector.isEmpty {
                        record.featurePrint = VectorMath.data(from: vector)
                    } else {
                        // Vision failed (e.g. no inference context): retry on the next launch.
                        record.version = 0
                        failedThisLaunch.insert(asset.localIdentifier)
                    }
                    record.sharpness = ImageAnalyzer.sharpness(image)
                } else {
                    record.unavailable = true
                    unavailable += 1
                }
                done += 1
            }
            try? modelContext.save()
            await progress(Progress(done: done, total: ids.count, unavailable: unavailable))
        }
        try? modelContext.save()
    }

    /// Returns how many videos got a new size.
    @discardableResult
    func measureVideos(_ ids: [String]) async -> Int {
        let known = Set(((try? modelContext.fetch(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.videoBytes != nil }))) ?? []).map(\.assetID))
        let todo = ids.filter { !known.contains($0) && !failedThisLaunch.contains($0) }
        guard !todo.isEmpty else { return 0 }
        var measured = 0
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: todo, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        for asset in list {
            if Task.isCancelled { break }
            if let bytes = await ImageAnalyzer.localVideoBytes(for: asset) {
                let record = record(for: asset.localIdentifier)
                record.videoBytes = bytes
                record.assetModifiedAt = asset.modificationDate
                measured += 1
            } else {
                // iCloud-only video: no local file to measure until it's downloaded.
                failedThisLaunch.insert(asset.localIdentifier)
            }
        }
        try? modelContext.save()
        return measured
    }

    private func record(for id: String) -> AnalysisRecord {
        var descriptor = FetchDescriptor<AnalysisRecord>(predicate: #Predicate { $0.assetID == id })
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let record = AnalysisRecord(assetID: id, version: PersistenceController.analysisVersion)
        modelContext.insert(record)
        return record
    }

    // MARK: Screenshot OCR

    func screenshotsNeedingOCR(_ ids: [String]) -> [String] {
        let version = PersistenceController.ocrVersion
        let done = Set(((try? modelContext.fetch(FetchDescriptor<ScreenshotIndexRecord>(
            predicate: #Predicate { $0.ocrVersion >= version }))) ?? []).map(\.assetID))
        return ids.filter { !done.contains($0) && !failedThisLaunch.contains($0) }
    }

    func recognizeScreenshots(_ ids: [String], progress: @Sendable (Progress) async -> Void) async {
        var done = 0, unavailable = 0
        for batch in ids.chunked(into: 12) {
            if Task.isCancelled { break }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
            var list: [PHAsset] = []
            assets.enumerateObjects { a, _, _ in list.append(a) }
            for asset in list {
                if Task.isCancelled { break }
                let id = asset.localIdentifier
                var descriptor = FetchDescriptor<ScreenshotIndexRecord>(predicate: #Predicate { $0.assetID == id })
                descriptor.fetchLimit = 1
                let record = (try? modelContext.fetch(descriptor).first) ?? {
                    let r = ScreenshotIndexRecord(assetID: id, ocrVersion: 0)
                    modelContext.insert(r)
                    return r
                }()
                record.assetModifiedAt = asset.modificationDate
                if let image = ImageAnalyzer.localImage(for: asset, maxSide: 1600),
                   let result = try? await ImageAnalyzer.recognizeText(image) {
                    record.text = result.text
                    record.links = ScreenshotClassifier.links(in: result.text)
                    let classification = ScreenshotClassifier.classify(result.text)
                    record.suggestedCategoryRaw = classification.category.rawValue
                    record.confidence = classification.confidence
                    record.failed = false
                    record.ocrVersion = PersistenceController.ocrVersion
                } else {
                    // Not available offline or OCR failed; retried on the next launch.
                    record.failed = true
                    failedThisLaunch.insert(id)
                    unavailable += 1
                }
                done += 1
            }
            try? modelContext.save()
            await progress(Progress(done: done, total: ids.count, unavailable: unavailable))
        }
    }

    // MARK: Results

    func analyzedPhotos(ids: [String: (Date, Bool, Int, Int)]) -> [AnalyzedPhoto] {
        let records = (try? modelContext.fetch(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.featurePrint != nil }))) ?? []
        return records.compactMap { r in
            guard let meta = ids[r.assetID], let data = r.featurePrint else { return nil }
            return AnalyzedPhoto(id: r.assetID, date: meta.0, vector: VectorMath.floats(from: data),
                                 isFavorite: meta.1, pixelWidth: meta.2, pixelHeight: meta.3, sharpness: r.sharpness)
        }
    }

    func sharpness(for ids: Set<String>) -> [String: Double] {
        let records = (try? modelContext.fetch(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.sharpness != nil }))) ?? []
        var result: [String: Double] = [:]
        for r in records where ids.contains(r.assetID) { result[r.assetID] = r.sharpness }
        return result
    }

    func videoBytes() -> [String: Int64] {
        let records = (try? modelContext.fetch(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.videoBytes != nil }))) ?? []
        var result: [String: Int64] = [:]
        for r in records { result[r.assetID] = r.videoBytes }
        return result
    }

    func counts() -> (analyzed: Int, unavailable: Int, failed: Int) {
        let analyzed = (try? modelContext.fetchCount(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.featurePrint != nil }))) ?? 0
        let unavailable = (try? modelContext.fetchCount(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.unavailable }))) ?? 0
        let failed = (try? modelContext.fetchCount(FetchDescriptor<AnalysisRecord>(
            predicate: #Predicate { $0.featurePrint == nil && !$0.unavailable && $0.videoBytes == nil }))) ?? 0
        return (analyzed, unavailable, failed)
    }

    func forget(_ ids: Set<String>) {
        let list = Array(ids)
        try? modelContext.delete(model: AnalysisRecord.self, where: #Predicate { list.contains($0.assetID) })
        try? modelContext.delete(model: ScreenshotIndexRecord.self, where: #Predicate { list.contains($0.assetID) })
        try? modelContext.save()
    }

    func clearAll() {
        try? modelContext.delete(model: AnalysisRecord.self)
        try? modelContext.delete(model: ScreenshotIndexRecord.self)
        try? modelContext.save()
    }
}

extension Array {
    nonisolated func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
