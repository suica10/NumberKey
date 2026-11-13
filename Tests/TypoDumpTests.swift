import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion

/// Prototype-only harness for the typo-correction measurement: for each
/// item of Prototype/typo_fixture.json, dumps the app's candidate lists for
/// the typo'd input, for every 1-edit variant of the typo'd input, and for
/// every 1-edit variant of the clean input (the over-correction control),
/// so the offline scorer in Prototype/lm/typo_eval.py can pool them.
///
/// Runs only when both environment variables are set (the prototype-typo
/// workflow sets them); skipped in normal test runs.
/// - TYPO_FIXTURE_JSON: absolute path to typo_fixture.json
/// - PROTO_DUMP_DIR:    directory to write typo_dump.json into
final class TypoDumpTests: XCTestCase {
    func testDumpTypoCandidates() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["TYPO_FIXTURE_JSON"], let dumpDir = env["PROTO_DUMP_DIR"] else {
            throw XCTSkip("TYPO_FIXTURE_JSON / PROTO_DUMP_DIR not set")
        }
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let items = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [[String: Any]]
        )
        XCTAssertGreaterThan(items.count, 50, "typo fixture unexpectedly small")

        let outDir = URL(fileURLWithPath: dumpDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("typo_dump.json")

        let service = ConversionService()
        await service.warmUp()

        // Memoize conversions across the whole run: ~19k compositions, and
        // variant sets overlap between the typo and clean lists of an item.
        var cache: [String: [String]] = [:]
        func convert(_ kana: String) async -> [String] {
            if let hit = cache[kana] { return hit }
            var composition = ComposingText()
            composition.insertAtCursorPosition(kana, inputStyle: .direct)
            let candidates = await service.candidates(for: composition)
            cache[kana] = candidates
            return candidates
        }

        var output: [[String: Any]] = []
        for (index, item) in items.enumerated() {
            guard let kana = item["kana"] as? String,
                  let typoKana = item["typo_kana"] as? String,
                  let expected = item["expected"] as? String
            else { continue }
            let variants = item["variants"] as? [String] ?? []
            let cleanVariants = item["clean_variants"] as? [String] ?? []

            // One bad item must not lose the whole dump.
            var typoCandidates: [String] = []
            var variantCandidates: [String: [String]] = [:]
            var cleanVariantCandidates: [String: [String]] = [:]
            do {
                typoCandidates = await convert(typoKana)
                for variant in variants {
                    variantCandidates[variant] = await convert(variant)
                }
                for variant in cleanVariants {
                    cleanVariantCandidates[variant] = await convert(variant)
                }
            } catch {
                // ConversionService.candidates does not throw today; keep the
                // guard so a future failure degrades to a partial item.
                print("TypoDump: item \(index) failed: \(error)")
            }
            output.append([
                "kana": kana,
                "typo_kana": typoKana,
                "expected": expected,
                "typo_candidates": typoCandidates,
                "variant_candidates": variantCandidates,
                "clean_variant_candidates": cleanVariantCandidates
            ])

            // Flush periodically so a CI timeout still leaves a usable dump.
            if index % 20 == 19 || index == items.count - 1 {
                let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: outURL)
                print("TypoDump: flushed \(output.count) items, cache size \(cache.count)")
            }
        }
        XCTAssertEqual(output.count, items.count, "some fixture items were skipped")
    }
}
