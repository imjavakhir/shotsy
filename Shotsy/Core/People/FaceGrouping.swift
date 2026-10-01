import CoreGraphics
import CoreML
import Foundation

/// Turns an aligned face crop into an identity embedding. Detection (Vision) only finds faces;
/// recognizing the same person needs a separate, validated face-embedding model.
nonisolated protocol FaceEmbedder: Sendable {
    /// Model name + revision, stored with each embedding so a model change invalidates old vectors.
    var modelIdentifier: String { get }
    /// Square crop edge the model expects.
    var inputSide: Int { get }
    func embedding(for faceCrop: CGImage) async throws -> [Float]
}

nonisolated enum FaceEmbedderProvider {
    /// Resource name a validated Core ML model must use to be picked up (see README → People).
    static let modelResourceName = "ShotsyFaceEmbedder"

    /// No face-embedding model ships with Shotsy yet: none with verified commercial-redistribution rights for
    /// both code and weights was available within the zero-cost constraint. Returns nil, and the app offers
    /// manual tagging instead of pretending to group automatically.
    static func current() -> FaceEmbedder? {
        guard let url = Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else { return nil }
        return CoreMLFaceEmbedder(model: model)
    }
}

/// Adapter for a bundled Core ML model with one image input and one MultiArray output.
/// The model's own preprocessing (alignment, normalization) must be baked into the .mlmodel.
nonisolated final class CoreMLFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    private let model: MLModel
    let inputSide: Int
    let modelIdentifier: String

    init(model: MLModel) {
        self.model = model
        let input = model.modelDescription.inputDescriptionsByName.values.first
        inputSide = input?.imageConstraint?.pixelsWide ?? 112
        let meta = model.modelDescription.metadata
        modelIdentifier = [meta[.author] as? String, meta[.versionString] as? String, FaceEmbedderProvider.modelResourceName]
            .compactMap { $0 }.joined(separator: "/")
    }

    func embedding(for faceCrop: CGImage) async throws -> [Float] {
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
              let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else {
            throw CocoaError(.featureUnsupported)
        }
        let value = try MLFeatureValue(cgImage: faceCrop, constraint: constraint)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
        let output = try await model.prediction(from: provider)
        guard let name = output.featureNames.first, let array = output.featureValue(for: name)?.multiArrayValue else {
            throw CocoaError(.featureUnsupported)
        }
        return (0..<array.count).map { Float(truncating: array[$0]) }
    }
}

/// Conservative grouping of face embeddings. Pure and deterministic.
nonisolated enum FaceGrouper {
    struct Face: Sendable, Equatable {
        var id: UUID
        var embedding: [Float]
        /// Manual assignment always wins and is never changed by grouping.
        var manualPerson: UUID?
        var rejected: Set<UUID>
    }

    struct Assignment: Equatable, Sendable {
        var faceID: UUID
        /// Existing person, or nil to create a new group identified by `newGroup`.
        var person: UUID?
        var newGroup: Int?
    }

    /// - A face joins a group only if it's within `threshold` (cosine distance) of the group centroid AND of at
    ///   least half the group's members. This blocks "chaining" where a series of weak matches merges strangers.
    /// - Faces never join a person they were rejected from.
    /// - Singletons stay ungrouped (uncertain).
    /// The threshold must be tuned on real evaluation data for the chosen model; there's no universal value.
    static func group(_ faces: [Face], threshold: Float, minGroupSize: Int = 2) -> [Assignment] {
        struct Cluster {
            var person: UUID?
            var members: [Face]
            var centroid: [Float]
        }
        var clusters: [Cluster] = []
        // Seed with people the user already confirmed.
        let manual = Dictionary(grouping: faces.filter { $0.manualPerson != nil }, by: { $0.manualPerson! })
        for (person, members) in manual {
            clusters.append(Cluster(person: person, members: members, centroid: centroid(members.map(\.embedding))))
        }
        for face in faces where face.manualPerson == nil && !face.embedding.isEmpty {
            var best: (index: Int, distance: Float)?
            for (i, cluster) in clusters.enumerated() {
                if let p = cluster.person, face.rejected.contains(p) { continue }
                let d = VectorMath.cosineDistance(face.embedding, cluster.centroid)
                guard d < threshold else { continue }
                let close = cluster.members.filter { VectorMath.cosineDistance(face.embedding, $0.embedding) < threshold }.count
                guard close * 2 >= cluster.members.count else { continue }
                if best == nil || d < best!.distance { best = (i, d) }
            }
            if let best {
                clusters[best.index].members.append(face)
                clusters[best.index].centroid = centroid(clusters[best.index].members.map(\.embedding))
            } else {
                clusters.append(Cluster(person: nil, members: [face], centroid: face.embedding))
            }
        }
        var result: [Assignment] = []
        var groupNumber = 0
        for cluster in clusters {
            let autos = cluster.members.filter { $0.manualPerson == nil }
            if let person = cluster.person {
                result += autos.map { Assignment(faceID: $0.id, person: person, newGroup: nil) }
            } else if cluster.members.count >= minGroupSize {
                result += autos.map { Assignment(faceID: $0.id, person: nil, newGroup: groupNumber) }
                groupNumber += 1
            }
        }
        return result
    }

    static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count {
            for i in v.indices { sum[i] += v[i] }
        }
        return sum.map { $0 / Float(vectors.count) }
    }
}
