import XCTest
@testable import KeyboardConversion

/// The Swift context scorer must reproduce the PyTorch reference scores
/// exported by lm3/scripts/export_rerank3.py (span-avg logprob with the
/// context priming the GRU). The export itself was verified against an
/// independent NumPy implementation reading only the exported files
/// (dev/test top-1 identical to PyTorch). This guards the hand-ported
/// priming + span scoring.
final class ContextRerankScorerTests: XCTestCase {
    private struct FixtureItem: Decodable {
        let context: String
        let candidates: [String]
        let expected: String
        let avg: [Double]
    }

    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    func testContextScorerReproducesPyTorchScores() throws {
        let scorer = try ContextRerankScorer(
            weightsURL: repoURL("../Keyboard/rerank3_weights.bin"),
            vocabURL: repoURL("../Keyboard/rerank3_vocab.json"))
        let fixtureData = try Data(contentsOf: repoURL("rerank3_fixture.json"))
        let fixture = try JSONDecoder().decode([FixtureItem].self, from: fixtureData)
        XCTAssertEqual(fixture.count, 40)

        var argmaxMatches = 0
        var maxDiff = 0.0
        for item in fixture {
            let scores = scorer.score(item.candidates, context: item.context)
            XCTAssertEqual(scores.count, item.avg.count)
            for (got, want) in zip(scores, item.avg) {
                maxDiff = max(maxDiff, abs(Double(got) - want))
            }
            let swiftBest = scores.indices.max { scores[$0] < scores[$1] }!
            let referenceBest = item.avg.indices.max { item.avg[$0] < item.avg[$1] }!
            if swiftBest == referenceBest { argmaxMatches += 1 }
        }
        // Float summation order may flip a near-tie, never more than a couple.
        XCTAssertGreaterThanOrEqual(argmaxMatches, 38)
        XCTAssertLessThan(maxDiff, 0.05)
    }
}
