import XCTest
@testable import KeyboardConversion

/// The Swift GRU scorer must reproduce the PyTorch reference scores that
/// Prototype/lm/export_rerank.py exported (those in turn were verified
/// against an independent NumPy implementation: top-1 identical, max
/// score diff 2e-5). This guards the hand-ported GRU math.
final class RerankScorerTests: XCTestCase {
    private struct FixtureItem: Decodable {
        let candidates: [String]
        let expected: String
        let lm_sum: [Double]
    }

    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    func testScorerReproducesPyTorchRanking() throws {
        let scorer = try RerankScorer(
            weightsURL: repoURL("../Keyboard/rerank_weights.bin"),
            vocabURL: repoURL("../Keyboard/rerank_vocab.json"))
        let fixtureData = try Data(contentsOf: repoURL("rerank_fixture.json"))
        let fixture = try JSONDecoder().decode([FixtureItem].self, from: fixtureData)
        XCTAssertEqual(fixture.count, 104)

        var argmaxMatches = 0
        var top1Hits = 0
        var maxDiff = 0.0
        for item in fixture {
            let scores = scorer.score(item.candidates)
            XCTAssertEqual(scores.count, item.lm_sum.count)
            for (got, want) in zip(scores, item.lm_sum) {
                maxDiff = max(maxDiff, abs(Double(got) - want))
            }
            let swiftBest = scores.indices.max { scores[$0] < scores[$1] }!
            let referenceBest = item.lm_sum.indices.max { item.lm_sum[$0] < item.lm_sum[$1] }!
            if swiftBest == referenceBest { argmaxMatches += 1 }
            if item.candidates[swiftBest] == item.expected { top1Hits += 1 }
        }
        // Float summation order may flip a near-tie, never more than a couple.
        XCTAssertGreaterThanOrEqual(argmaxMatches, 102)
        XCTAssertLessThan(maxDiff, 0.05)
        // Reference top-1 is 0.865; the port must land in the same place.
        XCTAssertGreaterThanOrEqual(Double(top1Hits) / Double(fixture.count), 0.84)
    }
}
