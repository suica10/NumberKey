import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion

/// Prototype-only harness: dumps the app's real candidate lists for the
/// evaluation sentences in Prototype/eval_sentences.json so an offline
/// reranker can be scored against them.
///
/// Runs only when both environment variables are set (the prototype-rerank
/// workflow sets them); skipped in normal test runs.
/// - PROTO_EVAL_JSON: absolute path to eval_sentences.json
/// - PROTO_DUMP_DIR:  directory to write candidates.json into
final class CandidateDumpTests: XCTestCase {
    func testDumpCandidates() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let evalPath = env["PROTO_EVAL_JSON"], let dumpDir = env["PROTO_DUMP_DIR"] else {
            throw XCTSkip("PROTO_EVAL_JSON / PROTO_DUMP_DIR not set")
        }
        let evalData = try Data(contentsOf: URL(fileURLWithPath: evalPath))
        let items = try XCTUnwrap(
            JSONSerialization.jsonObject(with: evalData) as? [[String: String]]
        )
        XCTAssertGreaterThan(items.count, 50, "eval set unexpectedly small")

        let service = ConversionService()
        await service.warmUp()

        var output: [[String: Any]] = []
        for item in items {
            guard let kana = item["kana"], let expected = item["expected"] else { continue }
            var composition = ComposingText()
            composition.insertAtCursorPosition(kana, inputStyle: .direct)
            let candidates = await service.candidates(for: composition)
            output.append([
                "kana": kana,
                "expected": expected,
                "convertTarget": composition.convertTarget,
                "candidates": candidates
            ])
        }

        let outDir = URL(fileURLWithPath: dumpDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("candidates.json"))
    }
}
