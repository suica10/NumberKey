import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion

/// ゲート付きタイポ補正の統合テスト。フィクスチャは Prototype 側の
/// キャリブレーション (gate_calibrate.py + gen_gate_fixture.py) から
/// 生成した typo_gate_fixture.json で、オフライン実測値は:
///   ゲート定数 (TypoCorrection.gateThresholdAvg=-3.2, marginSum=8) の
///   もとでタイポ回復率 0.479、正常入力の王座交代率 0.025 (n=119)。
/// Swift 側のスコア計算のポート誤差で数件は揺れるため、許容幅を持たせる。
final class TypoCorrectionTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Item: Decodable {
            let kana: String
            let romaji: String
            let typo_kana: String
            let expected: String
            let typo_kind: String
            let clean_lm_winner: String?
            let true_kana_in_variants: Bool
        }
        let items: [Item]
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("typo_gate_fixture.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// かな<->ローマ字とバリアント選択が Python 実装と一致すること。
    func testVariantGenerationParity() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThan(fixture.items.count, 100)
        var containmentAgreements = 0
        for item in fixture.items {
            XCTAssertEqual(TypoCorrection.kanaToRomaji(item.kana), item.romaji,
                           "kanaToRomaji mismatch: \(item.kana)")
            XCTAssertEqual(TypoCorrection.romajiToKana(item.romaji), item.kana,
                           "romajiToKana round-trip mismatch: \(item.romaji)")
            let variants = TypoCorrection.variantKanas(forKana: item.typo_kana)
            XCTAssertLessThanOrEqual(variants.count, TypoCorrection.variantCap)
            if variants.contains(item.kana) == item.true_kana_in_variants {
                containmentAgreements += 1
            }
        }
        // 予算境界の並び順差異で数件ずれることはあるが、ほぼ一致するはず。
        XCTAssertGreaterThanOrEqual(
            Double(containmentAgreements) / Double(fixture.items.count), 0.97,
            "variant containment parity too low: \(containmentAgreements)/\(fixture.items.count)")
    }

    /// 実サービス経由のゲート方針: タイポが回復し、正常入力を壊さない。
    func testGatedPolicyRecoversTyposWithoutDethroningClean() async throws {
        let fixture = try loadFixture()
        // SwiftPM テストでは重みが Bundle.main に無い (RerankScorer.shared
        // は nil) ので、リポジトリ内の重みを直接差し込む (本番経路は shared)。
        let keyboardDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Keyboard")
        ConversionService.scorerOverride = try RerankScorer(
            weightsURL: keyboardDir.appendingPathComponent("rerank_weights.bin"),
            vocabURL: keyboardDir.appendingPathComponent("rerank_vocab.json"))
        defer { ConversionService.scorerOverride = nil }
        let service = ConversionService()
        await service.warmUp()
        var generation = 0
        func topCandidate(_ kana: String) async -> String? {
            generation += 1
            var composition = ComposingText()
            composition.insertAtCursorPosition(kana, inputStyle: .direct)
            return await service.candidates(for: composition, generation: generation)?.first
        }
        var recovered = 0
        var dethroned = 0
        var cleanScored = 0
        for item in fixture.items {
            if await topCandidate(item.typo_kana) == item.expected {
                recovered += 1
            }
            if let winner = item.clean_lm_winner {
                cleanScored += 1
                if await topCandidate(item.kana) != winner {
                    dethroned += 1
                }
            }
        }
        let n = Double(fixture.items.count)
        let recovery = Double(recovered) / n
        let dethrone = Double(dethroned) / Double(cleanScored)
        // オフライン実測 (Python): recovery=0.479, dethrone=0.025。
        XCTAssertGreaterThanOrEqual(recovery, 0.35, "typo recovery collapsed: \(recovery)")
        XCTAssertGreaterThanOrEqual(recovery, 0.479 - 0.10,
                                    "typo recovery below calibrated band: \(recovery)")
        XCTAssertLessThanOrEqual(dethrone, 0.10, "clean dethrone too high: \(dethrone)")
        XCTAssertLessThanOrEqual(dethrone, 0.025 + 0.05,
                                 "clean dethrone above calibrated band: \(dethrone)")
    }
}
