import Foundation
import SwiftData

// Two stores:
//  • Main store (backed up with the device): review decisions, sessions, quota log, user corrections,
//    smart collections, compression jobs.
//  • Derived store (excluded from backup, rebuildable): analysis results, OCR text, face observations,
//    people. Keeps sensitive derived data on this device, per the local-only promise.
// Photos stays the source of truth for media and album membership; only identifiers are stored.

enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        mainModels + derivedModels
    }

    static var mainModels: [any PersistentModel.Type] {
        [DecisionRecord.self, SessionRecord.self, DailyReviewRecord.self, ScreenshotMeta.self,
         SmartCollectionRecord.self, CompressionJobRecord.self]
    }

    static var derivedModels: [any PersistentModel.Type] {
        [AnalysisRecord.self, ScreenshotIndexRecord.self, FaceRecord.self, PersonRecord.self, IndexStateRecord.self]
    }

    // MARK: Main store

    @Model final class DecisionRecord {
        @Attribute(.unique) var assetID: String
        var decisionRaw: String
        var decidedAt: Date

        init(assetID: String, decision: ReviewDecision, decidedAt: Date = .now) {
            self.assetID = assetID
            self.decisionRaw = decision.rawValue
            self.decidedAt = decidedAt
        }
    }

    @Model final class SessionRecord {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var title: String
        /// JSON-encoded `SessionState` (frozen IDs, position, outcomes, undo history).
        var stateData: Data
        var monthKey: String?
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?

        init(id: UUID = UUID(), kind: SessionKind, title: String, state: Data, monthKey: String?) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.title = title
            self.stateData = state
            self.monthKey = monthKey
            self.createdAt = .now
            self.updatedAt = .now
        }
    }

    @Model final class DailyReviewRecord {
        @Attribute(.unique) var dayKey: String
        var assetIDs: [String]

        init(dayKey: String, assetIDs: [String]) {
            self.dayKey = dayKey
            self.assetIDs = assetIDs
        }
    }

    /// User-owned screenshot organization. Survives rescans and model updates.
    @Model final class ScreenshotMeta {
        @Attribute(.unique) var assetID: String
        /// Explicit correction; wins over any suggestion.
        var userCategoryRaw: String?
        var labels: [String]
        var isPinned: Bool
        var updatedAt: Date

        init(assetID: String) {
            self.assetID = assetID
            self.labels = []
            self.isPinned = false
            self.updatedAt = .now
        }
    }

    @Model final class SmartCollectionRecord {
        @Attribute(.unique) var id: UUID
        var name: String
        var matchAll: Bool
        /// JSON-encoded `[SmartRule]`.
        var rulesData: Data
        var createdAt: Date
        var sortIndex: Int

        init(id: UUID = UUID(), name: String, matchAll: Bool, rulesData: Data, sortIndex: Int) {
            self.id = id
            self.name = name
            self.matchAll = matchAll
            self.rulesData = rulesData
            self.createdAt = .now
            self.sortIndex = sortIndex
        }
    }

    /// Persistent job record so an interrupted export never imports twice.
    @Model final class CompressionJobRecord {
        @Attribute(.unique) var id: UUID
        var sourceAssetID: String
        var presetRaw: String
        var stateRaw: String
        var tempFileName: String?
        var outputAssetID: String?
        var sourceBytes: Int64?
        var outputBytes: Int64?
        var errorMessage: String?
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID = UUID(), sourceAssetID: String, presetRaw: String, stateRaw: String) {
            self.id = id
            self.sourceAssetID = sourceAssetID
            self.presetRaw = presetRaw
            self.stateRaw = stateRaw
            self.createdAt = .now
            self.updatedAt = .now
        }
    }

    // MARK: Derived store

    @Model final class AnalysisRecord {
        @Attribute(.unique) var assetID: String
        var version: Int
        /// Archived `VNFeaturePrintObservation` for similarity.
        var featurePrint: Data?
        /// Variance of the Laplacian on a 512 px grayscale thumbnail. Higher = sharper.
        var sharpness: Double?
        /// Measured local file size for videos, if known without downloading.
        var videoBytes: Int64?
        var assetModifiedAt: Date?
        var analyzedAt: Date
        /// Thumbnail wasn't available locally (cloud-only, not downloaded).
        var unavailable: Bool

        init(assetID: String, version: Int) {
            self.assetID = assetID
            self.version = version
            self.analyzedAt = .now
            self.unavailable = false
        }
    }

    @Model final class ScreenshotIndexRecord {
        @Attribute(.unique) var assetID: String
        var ocrVersion: Int
        /// Recognized text. Private: never logged or sent anywhere.
        var text: String
        var links: [String]
        var suggestedCategoryRaw: String?
        var confidence: Double
        var failed: Bool
        var assetModifiedAt: Date?

        init(assetID: String, ocrVersion: Int) {
            self.assetID = assetID
            self.ocrVersion = ocrVersion
            self.text = ""
            self.links = []
            self.confidence = 0
            self.failed = false
        }
    }

    @Model final class PersonRecord {
        @Attribute(.unique) var id: UUID
        /// User-chosen name. Never looked up externally.
        var name: String?
        var coverFaceID: UUID?
        var createdAt: Date

        init(id: UUID = UUID(), name: String?) {
            self.id = id
            self.name = name
            self.createdAt = .now
        }
    }

    /// One detected face in one asset. A group photo has several.
    @Model final class FaceRecord {
        @Attribute(.unique) var id: UUID
        var assetID: String
        /// Normalized Vision bounding box (origin bottom-left): x, y, width, height. Empty for manual whole-photo tags.
        var box: [Double]
        var personID: UUID?
        /// "auto" (from grouping) or "manual" (user assigned). Manual always wins.
        var assignmentRaw: String?
        /// People the user said this is not ("Not this person").
        var rejectedPersonIDs: [UUID]
        var embedding: Data?
        var embeddingModel: String?
        var captureQuality: Double?
        var detectorVersion: Int

        init(id: UUID = UUID(), assetID: String, box: [Double], detectorVersion: Int) {
            self.id = id
            self.assetID = assetID
            self.box = box
            self.rejectedPersonIDs = []
            self.detectorVersion = detectorVersion
        }
    }

    @Model final class IndexStateRecord {
        @Attribute(.unique) var key: String
        var version: Int
        var lastRun: Date?

        init(key: String, version: Int) {
            self.key = key
            self.version = version
        }
    }
}

enum ShotsyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    /// Add a stage here for every new schema version. Derived models can be dropped and rebuilt,
    /// but user corrections (ScreenshotMeta, FaceRecord manual assignments, PersonRecord names) must migrate.
    static var stages: [MigrationStage] { [] }
}

typealias DecisionRecord = SchemaV1.DecisionRecord
typealias SessionRecord = SchemaV1.SessionRecord
typealias DailyReviewRecord = SchemaV1.DailyReviewRecord
typealias ScreenshotMeta = SchemaV1.ScreenshotMeta
typealias SmartCollectionRecord = SchemaV1.SmartCollectionRecord
typealias CompressionJobRecord = SchemaV1.CompressionJobRecord
typealias AnalysisRecord = SchemaV1.AnalysisRecord
typealias ScreenshotIndexRecord = SchemaV1.ScreenshotIndexRecord
typealias PersonRecord = SchemaV1.PersonRecord
typealias FaceRecord = SchemaV1.FaceRecord
typealias IndexStateRecord = SchemaV1.IndexStateRecord

nonisolated enum PersistenceController {
    /// Bump when analysis output changes; stale records are recomputed, user corrections are kept.
    static let analysisVersion = 1
    static let ocrVersion = 1
    static let faceDetectorVersion = 1

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let main: ModelConfiguration
        let derived: ModelConfiguration
        if inMemory {
            main = ModelConfiguration("Main", schema: Schema(SchemaV1.mainModels), isStoredInMemoryOnly: true)
            derived = ModelConfiguration("Derived", schema: Schema(SchemaV1.derivedModels), isStoredInMemoryOnly: true)
        } else {
            let dir = try storeDirectory()
            main = ModelConfiguration("Main", schema: Schema(SchemaV1.mainModels), url: dir.appendingPathComponent("Main.store"))
            let derivedDir = try derivedDirectory()
            derived = ModelConfiguration("Derived", schema: Schema(SchemaV1.derivedModels),
                                         url: derivedDir.appendingPathComponent("Derived.store"))
        }
        return try ModelContainer(for: schema, migrationPlan: ShotsyMigrationPlan.self,
                                  configurations: [main, derived])
    }

    static func storeDirectory() throws -> URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Shotsy", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Derived data lives in its own folder, excluded from iCloud/device backups.
    static func derivedDirectory() throws -> URL {
        var url = try storeDirectory().appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
}

extension SessionRecord {
    /// Title in the current language. Month and Quick 20 titles are rebuilt from data rather than
    /// using the string saved at creation, so they follow language changes.
    var displayTitle: String {
        switch SessionKind(rawValue: kindRaw) {
        case .quick20:
            return String(localized: "Quick 20")
        case .month:
            guard let key = monthKey, key != "undated" else { return title }
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2,
                  let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return title }
            return LibraryIndex.monthTitle(date)
        default:
            return title
        }
    }
}
