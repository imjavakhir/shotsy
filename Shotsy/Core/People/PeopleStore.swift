import Photos
import SwiftData
import SwiftUI

/// Background face detection + (when a validated model exists) embedding generation.
@ModelActor
actor PeopleWorker {
    func photosNeedingDetection(_ ids: [String]) -> [String] {
        let scanned = Set(((try? modelContext.fetch(FetchDescriptor<FaceRecord>())) ?? []).map(\.assetID))
        let done = scannedAssets()
        return ids.filter { !scanned.contains($0) && !done.contains($0) }
    }

    /// Assets scanned with no faces are remembered so they aren't re-scanned.
    private func scannedAssets() -> Set<String> {
        let key = "faces.none"
        var d = FetchDescriptor<IndexStateRecord>(predicate: #Predicate { $0.key.starts(with: key) })
        d.fetchLimit = 100_000
        return Set(((try? modelContext.fetch(d)) ?? []).map { String($0.key.dropFirst(key.count + 1)) })
    }

    func detect(_ ids: [String], embedder: FaceEmbedder?, progress: @Sendable (Int, Int) async -> Void) async {
        var done = 0
        for batch in ids.chunked(into: 16) {
            if Task.isCancelled { break }
            let result = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
            var list: [PHAsset] = []
            result.enumerateObjects { a, _, _ in list.append(a) }
            for asset in list {
                if Task.isCancelled { break }
                guard let image = ImageAnalyzer.localImage(for: asset, maxSide: 1024),
                      let faces = try? await ImageAnalyzer.detectFaces(image) else { done += 1; continue }
                if faces.isEmpty {
                    modelContext.insert(IndexStateRecord(key: "faces.none.\(asset.localIdentifier)",
                                                         version: PersistenceController.faceDetectorVersion))
                }
                for face in faces {
                    let record = FaceRecord(assetID: asset.localIdentifier,
                                            box: [face.box.minX, face.box.minY, face.box.width, face.box.height],
                                            detectorVersion: PersistenceController.faceDetectorVersion)
                    record.captureQuality = face.quality
                    if let embedder, let crop = FaceCrop.crop(image, box: face.box, side: embedder.inputSide),
                       let vector = try? await embedder.embedding(for: crop) {
                        record.embedding = VectorMath.data(from: vector)
                        record.embeddingModel = embedder.modelIdentifier
                    }
                    modelContext.insert(record)
                }
                done += 1
            }
            try? modelContext.save()
            await progress(done, ids.count)
        }
        try? modelContext.save()
    }
}

nonisolated enum FaceCrop {
    /// Square crop around a normalized (bottom-left origin) Vision box, with margin.
    static func crop(_ image: CGImage, box: CGRect, side: Int, margin: CGFloat = 0.25) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        let grow = max(rect.width, rect.height) * (1 + margin * 2)
        rect = CGRect(x: rect.midX - grow / 2, y: rect.midY - grow / 2, width: grow, height: grow)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = image.cropping(to: rect.integral) else { return nil }
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}

struct PersonSummary: Identifiable, Hashable {
    var id: UUID
    var name: String?
    var coverFace: FaceSnapshot?
    /// Distinct photos containing this person.
    var photoCount: Int
    var displayName: String { name ?? String(localized: "Unnamed") }
}

struct FaceSnapshot: Identifiable, Hashable {
    var id: UUID
    var assetID: String
    var box: CGRect?
    var personID: UUID?
    var isManual: Bool
}

/// People: local, user-controlled organization. Not identity verification. Off until the user enables it.
@Observable
final class PeopleStore {
    enum IndexPhase: Equatable { case off, idle, detecting(done: Int, total: Int), paused, complete }

    private let container: ModelContainer
    private let context: ModelContext
    private let worker: PeopleWorker
    private let library: PhotoLibrary
    private let settings: SettingsStore
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Every face as of the last reload. Corrections and grouping always reload, so person queries read this
    /// instead of fetching all faces again.
    @ObservationIgnored private var faceSnapshots: [FaceSnapshot] = []
    @ObservationIgnored private var loadedFaceCount = 0

    private(set) var phase: IndexPhase = .off
    private(set) var people: [PersonSummary] = []
    private(set) var unassignedFaces: [FaceSnapshot] = []
    private(set) var revision = 0
    /// nil: no validated face-embedding model is bundled, so automatic grouping is unavailable.
    let embedder: FaceEmbedder? = FaceEmbedderProvider.current()
    @ObservationIgnored var isPro: () -> Bool = { false }

    var automaticGroupingAvailable: Bool { embedder != nil }

    init(container: ModelContainer, library: PhotoLibrary, settings: SettingsStore) {
        self.container = container
        self.context = container.mainContext
        self.worker = PeopleWorker(modelContainer: container)
        self.library = library
        self.settings = settings
        reload()
    }

    // MARK: Indexing

    func startIfEnabled() {
        guard settings.peopleEnabled, library.access.canRead else { phase = .off; return }
        guard task == nil else { return }
        phase = .idle
        task = Task { [weak self] in
            await self?.runDetection()
            self?.task = nil
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        phase = .paused
    }

    func disable() {
        task?.cancel()
        task = nil
        settings.peopleEnabled = false
        phase = .off
    }

    private func runDetection() async {
        let canRead = library.access.canRead
        let ids = await BackgroundFetch.run { canRead ? BackgroundFetch.identifiers(in: BackgroundFetch.fetch(.photos)) : [] }
        let needed = await worker.photosNeedingDetection(ids)
        if !needed.isEmpty {
            phase = .detecting(done: 0, total: needed.count)
            await worker.detect(needed, embedder: embedder) { [weak self] done, total in
                await self?.reportDetection(done: done, total: total)
            }
        }
        if Task.isCancelled { return }
        if embedder != nil { autoGroup() }
        reload()
        phase = .complete
    }

    private func reportDetection(done: Int, total: Int) {
        phase = .detecting(done: done, total: total)
        // Detection only adds faces, so an unchanged count means there's nothing new to show.
        if done % 64 == 0, faceCount() != loadedFaceCount { reload() }
    }

    /// Runs only with a bundled, validated model. Free users get a preview limited by Policy.
    private func autoGroup() {
        guard embedder != nil else { return }
        var faces = allFaces().filter { $0.embedding != nil }
        if !isPro() {
            let allowed = Set(faces.map(\.assetID).uniqued().prefix(Policy.current.freePeoplePreviewPhotos))
            faces = faces.filter { allowed.contains($0.assetID) }
        }
        let input = faces.map { f in
            FaceGrouper.Face(id: f.id, embedding: VectorMath.floats(from: f.embedding!),
                             manualPerson: f.assignmentRaw == "manual" ? f.personID : nil,
                             rejected: Set(f.rejectedPersonIDs))
        }
        let assignments = FaceGrouper.group(input, threshold: 0.35)
        var newPeople: [Int: UUID] = [:]
        let byID = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        for a in assignments {
            guard let face = byID[a.faceID] else { continue }
            if let person = a.person {
                face.personID = person
            } else if let g = a.newGroup {
                let person = newPeople[g] ?? {
                    let p = PersonRecord(name: nil)
                    context.insert(p)
                    newPeople[g] = p.id
                    return p.id
                }()
                face.personID = person
            }
            face.assignmentRaw = "auto"
        }
        try? context.save()
    }

    // MARK: Queries

    private func allFaces() -> [FaceRecord] {
        (try? context.fetch(FetchDescriptor<FaceRecord>())) ?? []
    }

    private func faceCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<FaceRecord>())) ?? 0
    }

    func reload() {
        // Only what snapshots need; embeddings stay on disk.
        var d = FetchDescriptor<FaceRecord>()
        d.propertiesToFetch = [\.id, \.assetID, \.box, \.personID, \.assignmentRaw]
        let faces = (try? context.fetch(d)) ?? []
        let persons = (try? context.fetch(FetchDescriptor<PersonRecord>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let snapshots = faces.map(Self.snapshot)
        faceSnapshots = snapshots
        loadedFaceCount = faces.count
        let byPerson = Dictionary(grouping: snapshots.filter { $0.personID != nil }, by: { $0.personID! })
        people = persons.compactMap { p in
            let members = byPerson[p.id] ?? []
            guard !members.isEmpty else { return nil }
            let cover = members.first { $0.id == p.coverFaceID } ?? members.first
            return PersonSummary(id: p.id, name: p.name, coverFace: cover, photoCount: Set(members.map(\.assetID)).count)
        }
        unassignedFaces = snapshots.filter { $0.personID == nil && $0.box != nil }
        revision += 1
    }

    func faces(of person: UUID) -> [FaceSnapshot] {
        faceSnapshots.filter { $0.personID == person }
    }

    func assetIDs(of person: UUID) -> [String] {
        Array(Set(faces(of: person).map(\.assetID)))
    }

    /// Person → asset IDs, for Smart Collection rules and the Library filter.
    func assetMap() -> [UUID: Set<String>] {
        var map: [UUID: Set<String>] = [:]
        for f in faceSnapshots { if let p = f.personID { map[p, default: []].insert(f.assetID) } }
        return map
    }

    nonisolated private static func snapshot(_ f: FaceRecord) -> FaceSnapshot {
        let box = f.box.count == 4 ? CGRect(x: f.box[0], y: f.box[1], width: f.box[2], height: f.box[3]) : nil
        return FaceSnapshot(id: f.id, assetID: f.assetID, box: box, personID: f.personID,
                            isManual: f.assignmentRaw == "manual")
    }

    private func face(_ id: UUID) -> FaceRecord? {
        var d = FetchDescriptor<FaceRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func person(_ id: UUID) -> PersonRecord? {
        var d = FetchDescriptor<PersonRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Corrections (always allowed, even without Pro)

    @discardableResult
    func createPerson(named name: String?, faces faceIDs: [UUID]) -> UUID {
        let p = PersonRecord(name: name?.trimmedNonEmpty)
        context.insert(p)
        for id in faceIDs { assign(id, to: p.id, save: false) }
        p.coverFaceID = faceIDs.first
        commit()
        return p.id
    }

    /// "Who is this?" with a typed name: reuses the person who already has that name (ignoring case),
    /// so tagging the same person face by face never creates duplicates.
    @discardableResult
    func tag(_ faceIDs: [UUID], asNamed name: String?) -> UUID {
        if let wanted = name?.trimmedNonEmpty,
           let existing = people.first(where: { $0.name?.caseInsensitiveCompare(wanted) == .orderedSame }) {
            for id in faceIDs { assign(id, to: existing.id, save: false) }
            commit()
            return existing.id
        }
        return createPerson(named: name, faces: faceIDs)
    }

    /// Tags several faces at once.
    func assign(_ faceIDs: [UUID], to person: UUID) {
        for id in faceIDs { assign(id, to: person, save: false) }
        commit()
    }

    func assign(_ faceID: UUID, to person: UUID, save: Bool = true) {
        guard let f = face(faceID) else { return }
        f.personID = person
        f.assignmentRaw = "manual"
        f.rejectedPersonIDs.removeAll { $0 == person }
        if save { commit() }
    }

    func name(_ person: UUID, _ name: String) {
        self.person(person)?.name = name.trimmedNonEmpty
        commit()
    }

    func chooseCover(_ person: UUID, face: UUID) {
        self.person(person)?.coverFaceID = face
        commit()
    }

    /// "Not this person": unassigns and remembers the rejection so rescans never re-add it.
    func notThisPerson(_ faceID: UUID) {
        guard let f = face(faceID), let p = f.personID else { return }
        f.rejectedPersonIDs.append(p)
        f.personID = nil
        f.assignmentRaw = "manual"
        commit()
    }

    /// Merges `other` into `target`. Every face becomes a manual assignment to `target`.
    func merge(_ other: UUID, into target: UUID) {
        guard other != target else { return }
        for f in allFaces() where f.personID == other {
            f.personID = target
            f.assignmentRaw = "manual"
        }
        if let p = person(other) {
            if person(target)?.name == nil { person(target)?.name = p.name }
            context.delete(p)
        }
        commit()
    }

    /// Moves the selected faces to a new person.
    @discardableResult
    func split(_ faceIDs: [UUID], from person: UUID, newName: String?) -> UUID {
        for id in faceIDs { face(id)?.rejectedPersonIDs.append(person) }
        return createPerson(named: newName, faces: faceIDs)
    }

    /// "Add missing photo": tags a photo where no face was detected (or detection missed this person).
    func addPhoto(_ assetID: String, to person: UUID) {
        let f = FaceRecord(assetID: assetID, box: [], detectorVersion: PersistenceController.faceDetectorVersion)
        f.personID = person
        f.assignmentRaw = "manual"
        context.insert(f)
        commit()
    }

    func deletePerson(_ person: UUID) {
        for f in allFaces() where f.personID == person {
            f.personID = nil
            f.assignmentRaw = nil
            if f.box.isEmpty { context.delete(f) }
        }
        if let p = self.person(person) { context.delete(p) }
        commit()
    }

    /// Settings → Delete People data. Removes names, faces and embeddings. Photos are untouched.
    func deleteAllData() {
        task?.cancel()
        task = nil
        try? context.delete(model: FaceRecord.self)
        try? context.delete(model: PersonRecord.self)
        try? context.delete(model: IndexStateRecord.self, where: #Predicate { $0.key.starts(with: "faces.") })
        commit()
        phase = settings.peopleEnabled ? .idle : .off
    }

    func forget(_ assetIDs: Set<String>) {
        let ids = Array(assetIDs)
        try? context.delete(model: FaceRecord.self, where: #Predicate { ids.contains($0.assetID) })
        commit()
    }

    private func commit() {
        try? context.save()
        reload()
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
