import Accelerate
import Foundation

// Pure, testable analysis logic. No PhotoKit or Vision here.

/// Similarity tuning. These are heuristics for Vision feature-print vectors (revision 2, L2 distance),
/// chosen conservatively; they are suggestions, not facts. Re-tune with a labeled evaluation set.
nonisolated enum SimilarityTuning {
    /// Photos closer than this (and taken close in time) are grouped as "similar".
    static let similarDistance: Float = 0.42
    /// Closer than this with identical pixel dimensions → a duplicate *candidate* (still unverified).
    static let duplicateCandidateDistance: Float = 0.06
    /// Only compare photos taken within this window of each other (bounds the work; no all-pairs).
    static let timeWindow: TimeInterval = 10 * 60
    /// Max neighbors compared per photo inside the window.
    static let maxNeighbors = 40
    /// Laplacian variance below this (384 px grayscale) → blurry candidate.
    static let blurThreshold: Double = 22
}

nonisolated struct AnalyzedPhoto: Sendable, Equatable {
    var id: String
    var date: Date
    var vector: [Float]
    var isFavorite: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var sharpness: Double?

    var pixelCount: Int { pixelWidth * pixelHeight }
}

nonisolated struct SimilarGroup: Sendable, Identifiable, Equatable {
    var ids: [String]
    var suggestedKeeper: String
    var reason: KeeperReason
    /// True when every pair is a near-identical candidate with the same dimensions (needs verification).
    var isDuplicateCandidate: Bool

    var id: String { ids.sorted().joined(separator: "|") }
}

nonisolated enum KeeperReason: String, Sendable {
    case favorite, higherResolution, sharper, earliest

    var text: LocalizedStringResource {
        switch self {
        case .favorite: "Already a favorite"
        case .higherResolution: "Higher resolution"
        case .sharper: "Looks sharpest"
        case .earliest: "Taken first"
        }
    }
}

nonisolated enum VectorMath {
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return vDSP.distanceSquared(a, b).squareRoot()
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        let dot = vDSP.dot(a, b)
        let na = vDSP.sumOfSquares(a), nb = vDSP.sumOfSquares(b)
        guard na > 0, nb > 0 else { return .infinity }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

nonisolated enum SimilarityGrouper {
    /// Groups photos that are visually close *and* taken close together in time.
    /// Cost is O(n · maxNeighbors) after sorting by date, never all-pairs.
    static func groups(_ photos: [AnalyzedPhoto], protectFavorites: Bool = true) -> [SimilarGroup] {
        let sorted = photos.filter { !$0.vector.isEmpty }.sorted { $0.date < $1.date }
        guard sorted.count > 1 else { return [] }
        var parent = Array(sorted.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var minDistance: [Int: Float] = [:]
        for i in sorted.indices {
            var j = i + 1
            var compared = 0
            while j < sorted.count, compared < SimilarityTuning.maxNeighbors,
                  sorted[j].date.timeIntervalSince(sorted[i].date) <= SimilarityTuning.timeWindow {
                let d = VectorMath.distance(sorted[i].vector, sorted[j].vector)
                if d < SimilarityTuning.similarDistance {
                    let a = find(i), b = find(j)
                    if a != b { parent[b] = a }
                    let dupe = d < SimilarityTuning.duplicateCandidateDistance
                        && sorted[i].pixelWidth == sorted[j].pixelWidth
                        && sorted[i].pixelHeight == sorted[j].pixelHeight
                    minDistance[i] = min(minDistance[i] ?? .infinity, dupe ? -1 : d)
                    minDistance[j] = min(minDistance[j] ?? .infinity, dupe ? -1 : d)
                }
                j += 1
                compared += 1
            }
        }
        var buckets: [Int: [Int]] = [:]
        for i in sorted.indices { buckets[find(i), default: []].append(i) }
        return buckets.values
            .filter { $0.count > 1 }
            .map { members in
                let items = members.map { sorted[$0] }
                let (keeper, reason) = suggestKeeper(items)
                let allDupes = members.allSatisfy { (minDistance[$0] ?? .infinity) < 0 }
                    && Set(items.map { "\($0.pixelWidth)x\($0.pixelHeight)" }).count == 1
                return SimilarGroup(ids: items.map(\.id), suggestedKeeper: keeper, reason: reason,
                                    isDuplicateCandidate: allDupes)
            }
            .sorted { $0.ids.count > $1.ids.count }
    }

    /// Favorite first, then resolution, then sharpness, then the earliest shot. Always overridable.
    static func suggestKeeper(_ items: [AnalyzedPhoto]) -> (String, KeeperReason) {
        if let fav = items.first(where: \.isFavorite) { return (fav.id, .favorite) }
        let maxPixels = items.map(\.pixelCount).max() ?? 0
        let biggest = items.filter { $0.pixelCount == maxPixels }
        if biggest.count < items.count, let best = biggest.first { return (best.id, .higherResolution) }
        let sharp = items.compactMap { item in item.sharpness.map { (item, $0) } }
        if sharp.count == items.count, let best = sharp.max(by: { $0.1 < $1.1 }),
           best.1 > (sharp.map(\.1).min() ?? 0) * 1.15 {
            return (best.0.id, .sharper)
        }
        let earliest = items.min { $0.date < $1.date } ?? items[0]
        return (earliest.id, .earliest)
    }

    /// Default selection for a group: everything except the keeper, minus favorites when protected.
    /// Never selects every member.
    static func defaultSelection(for group: SimilarGroup, favorites: Set<String>, protectFavorites: Bool) -> Set<String> {
        var selection = Set(group.ids)
        selection.remove(group.suggestedKeeper)
        if protectFavorites { selection.subtract(favorites) }
        if selection.count >= group.ids.count, let first = group.ids.first { selection.remove(first) }
        return selection
    }
}

// MARK: - Blur

nonisolated enum BlurMetric {
    /// Variance of the 4-neighbour Laplacian over an 8-bit grayscale image. Higher = sharper.
    static func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let c = Int(gray[row + x])
                let l = Int(gray[row + x - 1]) + Int(gray[row + x + 1])
                    + Int(gray[row - width + x]) + Int(gray[row + width + x]) - 4 * c
                let v = Double(l)
                sum += v
                sumSq += v * v
                n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}

// MARK: - Duplicate verification

/// Hash of one original resource (photo, paired Live Photo video, RAW, adjustment data, ...).
nonisolated struct ResourceFingerprint: Hashable, Sendable {
    var type: Int
    var uti: String
    var sha256: String
}

nonisolated enum DuplicateVerification {
    enum Result: Equatable, Sendable {
        /// Groups whose complete original resource sets are byte-identical.
        case verified([[String]])
    }

    /// Two assets are exact duplicates only if every original resource (including RAW/JPEG pairs,
    /// Live Photo videos and edit data) matches byte-for-byte. Assets whose resources could not be read
    /// are left out (they stay "similar / unverified").
    static func verifiedGroups(_ fingerprints: [String: [ResourceFingerprint]?]) -> [[String]] {
        var buckets: [[ResourceFingerprint]: [String]] = [:]
        for (id, prints) in fingerprints {
            guard let prints, !prints.isEmpty else { continue }
            let key = prints.sorted { ($0.type, $0.uti, $0.sha256) < ($1.type, $1.uti, $1.sha256) }
            buckets[key, default: []].append(id)
        }
        return buckets.values.filter { $0.count > 1 }.map { $0.sorted() }
    }
}

// MARK: - Screenshot classification

nonisolated enum ScreenshotCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case receipts, tickets, recipes, shopping, references, other

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .receipts: "Receipts"
        case .tickets: "Tickets"
        case .recipes: "Recipes"
        case .shopping: "Shopping"
        case .references: "References"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .receipts: "receipt"
        case .tickets: "ticket"
        case .recipes: "fork.knife"
        case .shopping: "bag"
        case .references: "bookmark"
        case .other: "square.dashed"
        }
    }
}

nonisolated struct ClassificationResult: Equatable, Sendable {
    /// `.other` when confidence is insufficient.
    var category: ScreenshotCategory
    var confidence: Double
}

/// Conservative keyword/layout rules on recognized text. English keywords only for now; other
/// languages fall back to Other rather than guessing.
nonisolated enum ScreenshotClassifier {
    static let minimumScore = 3.0
    static let minimumMargin = 1.5

    static let rules: [ScreenshotCategory: [(String, Double)]] = [
        .receipts: [("subtotal", 3), ("total", 1.5), ("tax", 1.5), ("receipt", 3), ("order #", 2), ("order number", 2),
                    ("paid", 1), ("payment", 1), ("visa", 1), ("mastercard", 1), ("amount", 1), ("invoice", 2.5),
                    ("transaction", 1.5), ("change due", 2), ("tip", 0.5)],
        .tickets: [("boarding pass", 4), ("boarding", 2), ("gate", 1.5), ("seat", 1.5), ("flight", 2), ("ticket", 2.5),
                   ("admit", 2), ("row", 0.5), ("departure", 2), ("arrival", 1), ("booking reference", 3),
                   ("confirmation code", 2), ("platform", 1), ("terminal", 1), ("section", 0.5), ("event", 0.5)],
        .recipes: [("ingredients", 4), ("tbsp", 2), ("tsp", 2), ("tablespoon", 2), ("teaspoon", 2), ("cup", 1),
                   ("preheat", 3), ("oven", 1.5), ("bake", 1.5), ("serves", 1.5), ("servings", 1.5), ("minced", 1.5),
                   ("chopped", 1.5), ("simmer", 2), ("stir", 1), ("recipe", 3), ("prep time", 2.5)],
        .shopping: [("add to cart", 4), ("add to bag", 4), ("buy now", 3), ("in stock", 2.5), ("out of stock", 2.5),
                    ("free shipping", 2.5), ("free delivery", 2), ("size", 1), ("color", 0.5), ("wishlist", 2),
                    ("checkout", 2), ("sale", 1), ("reviews", 1), ("price", 1)],
        .references: [("http", 1.5), ("www.", 1.5), (".com", 1), ("wikipedia", 3), ("chapter", 1.5), ("article", 1.5),
                      ("definition", 2), ("address", 1), ("notes", 1), ("how to", 1.5), ("step", 0.5)],
    ]

    static func classify(_ text: String) -> ClassificationResult {
        let lower = text.lowercased()
        guard lower.count >= 12 else { return ClassificationResult(category: .other, confidence: 0) }
        var scores: [ScreenshotCategory: Double] = [:]
        for (category, keywords) in rules {
            var score = 0.0
            for (word, weight) in keywords where lower.contains(word) { score += weight }
            scores[category] = score
        }
        // Layout cue: many currency amounts suggests a receipt.
        let money = lower.matches(of: /[$€£¥]\s?\d+[.,]\d{2}|\d+[.,]\d{2}\s?[$€£¥]/).count
        if money >= 3 { scores[.receipts, default: 0] += 2 }
        if money >= 1 { scores[.shopping, default: 0] += 0.5 }
        // Long prose with no stronger signal reads like a reference.
        let words = lower.split(whereSeparator: \.isWhitespace).count
        if words > 90 { scores[.references, default: 0] += 1.5 }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= minimumScore else {
            return ClassificationResult(category: .other, confidence: 0)
        }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard best.value - runnerUp >= minimumMargin else {
            return ClassificationResult(category: .other, confidence: 0)
        }
        let confidence = min(1, (best.value - runnerUp) / 8 + best.value / 20)
        return ClassificationResult(category: best.key, confidence: confidence)
    }

    /// Links found in text. Shown as buttons only; never opened or fetched automatically.
    static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return detector.matches(in: text, range: range)
            .compactMap { $0.url?.absoluteString }
            .filter { $0.hasPrefix("http") && seen.insert($0).inserted }
    }

    /// The category the UI shows: an explicit user correction always wins over a suggestion.
    static func effectiveCategory(userCategory: ScreenshotCategory?, suggested: ScreenshotCategory?,
                                  suggestionsEnabled: Bool) -> ScreenshotCategory? {
        if let userCategory { return userCategory }
        return suggestionsEnabled ? suggested : nil
    }
}
