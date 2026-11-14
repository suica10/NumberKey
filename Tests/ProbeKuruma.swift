import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion

/// 一時プローブ (ビルド61測定用): 「くるま」の実変換器候補 + 実LMスコアを
/// ダンプする。意図的に XCTFail し、失敗ログから値を回収する。
final class ProbeKuruma: XCTestCase {
    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    func testProbeKuruma() async throws {
        let scorer = try RerankScorer(
            weightsURL: repoURL("../Keyboard/rerank_weights.bin"),
            vocabURL: repoURL("../Keyboard/rerank_vocab.json"))

        // 変換器の素の順 (scorer 無し → top をそのまま返す)
        let plainService = ConversionService()
        var c0 = ComposingText()
        c0.insertAtCursorPosition("kuruma", inputStyle: .roman2kana)
        let top = await plainService.candidates(for: c0, generation: 1) ?? []

        let scores = scorer.score(top)

        // 本番経路 (scorerOverride + JoyoKanji.shared はテスト環境では nil)
        ConversionService.scorerOverride = scorer
        let service = ConversionService()
        var c1 = ComposingText()
        c1.insertAtCursorPosition("kuruma", inputStyle: .roman2kana)
        let final = await service.candidates(for: c1, generation: 1) ?? []
        ConversionService.scorerOverride = nil

        // 意図した順 (repo の joyo_kanji.txt を直接読んだ JoyoKanji で調整)
        let joyoText = try String(contentsOf: repoURL("../Keyboard/joyo_kanji.txt"), encoding: .utf8)
        let joyo = JoyoKanji(text: joyoText)
        let intended = joyoAdjustedOrder(candidates: top, scores: scores, joyo: joyo, penaltyExempt: [])
            .map { top[$0] }

        var lines = ["KURUMA_PROBE shared_nil=\(JoyoKanji.shared == nil) top_count=\(top.count)"]
        for (i, cand) in top.enumerated() {
            lines.append("KURUMA_PROBE cand \(i) \(cand) \(String(format: "%.4f", scores[i])) adj \(String(format: "%.2f", joyo.adjustment(for: cand)))")
        }
        lines.append("KURUMA_PROBE final_service=\(final.joined(separator: " / "))")
        lines.append("KURUMA_PROBE intended=\(intended.joined(separator: " / "))")
        XCTFail(lines.joined(separator: "\n"))
    }
}
