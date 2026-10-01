import Foundation
import Testing
@testable import Shotsy

/// Synthetic scale checks for the pure algorithms. Not a substitute for measuring on a device with a real
/// large library (PhotoKit, Vision and thumbnail costs dominate there); see README → Performance.
@Suite("Scale benchmarks")
struct BenchmarkTests {
    @Test func similarityGroupingOf20kPhotos() {
        var rng = SystemRandomNumberGenerator()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photos: [AnalyzedPhoto] = (0..<20_000).map { i in
            let v = (0..<768).map { _ in Float.random(in: -1...1, using: &rng) }
            return AnalyzedPhoto(id: "p\(i)", date: base.addingTimeInterval(Double(i) * 20), vector: v,
                                 isFavorite: false, pixelWidth: 4032, pixelHeight: 3024, sharpness: 50)
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SimilarityGrouper.groups(photos) }
        print("BENCH similarity 20k photos x 768-d:", elapsed)
        #expect(elapsed < .seconds(60))
    }

    @Test func ledgerWith50kDecisions() throws {
        var ledger = ReviewLedger()
        for i in 0..<50_000 { ledger.decisions["a\(i)"] = i % 10 == 0 ? .marked : .keep }
        let ids = (0..<60_000).map { "a\($0)" }
        let clock = ContinuousClock()
        var quick: [String] = []
        let elapsed = clock.measure {
            quick = SessionBuilder.quick(from: ids, ledger: ledger, limit: 20, remainingQuota: nil)
            _ = ledger.pendingIDs.count
        }
        print("BENCH quick20 + pending over 50k decisions:", elapsed)
        #expect(quick.count == 20)
        #expect(elapsed < .seconds(2))
    }
}
