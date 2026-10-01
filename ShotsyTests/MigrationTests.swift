import Foundation
import SwiftData
import Testing
@testable import Shotsy

@Suite("SwiftData migration")
struct MigrationTests {
    /// A 1.0 store (SchemaV1, with People data in the derived store) opens with the current schema,
    /// keeps user data and analysis results, and loses only the People entities and their index rows.
    @Test func v1StoreWithPeopleDataOpensWithV2() throws {
        let base = URL.temporaryDirectory.appendingPathComponent("MigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            let configurations = try PersistenceController.configurations(
                main: SchemaV1.mainModels, derived: SchemaV1.derivedModels, directory: base)
            let v1 = try ModelContainer(for: Schema(versionedSchema: SchemaV1.self), configurations: configurations)
            let context = ModelContext(v1)
            context.insert(SchemaV1.DecisionRecord(assetID: "a", decision: .marked))
            context.insert(SchemaV1.ScreenshotMeta(assetID: "s"))
            context.insert(SchemaV1.AnalysisRecord(assetID: "a", version: 1))
            let person = SchemaV1.PersonRecord(name: "Ana")
            context.insert(person)
            let face = SchemaV1.FaceRecord(assetID: "a", box: [0.1, 0.1, 0.2, 0.2], detectorVersion: 1)
            face.personID = person.id
            context.insert(face)
            context.insert(SchemaV1.IndexStateRecord(key: "faces.none.b", version: 1))
            context.insert(SchemaV1.IndexStateRecord(key: "other.key", version: 1))
            try context.save()
        }

        let v2 = try PersistenceController.makeContainer(directory: base)
        let context = ModelContext(v2)
        #expect(try context.fetch(FetchDescriptor<DecisionRecord>()).map(\.assetID) == ["a"])
        #expect(try context.fetch(FetchDescriptor<ScreenshotMeta>()).map(\.assetID) == ["s"])
        // Derived data survived, so the store was migrated rather than recreated.
        #expect(try context.fetch(FetchDescriptor<AnalysisRecord>()).map(\.assetID) == ["a"])
        #expect(try context.fetch(FetchDescriptor<IndexStateRecord>()).map(\.key) == ["other.key"])

        // Opening again (second launch) is a no-op.
        let again = try PersistenceController.makeContainer(directory: base)
        #expect(try ModelContext(again).fetchCount(FetchDescriptor<DecisionRecord>()) == 1)
    }
}
