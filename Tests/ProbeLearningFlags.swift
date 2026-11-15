import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion

/// 一時プローブ (Phase 1 / joyo ペナルティ不発の切り分け):
/// ConversionService.fullInputCandidates と同一のオプションで実変換器に
/// 問い合わせ、製品経路と同じフィルタ (inputable / 全文消費 / 重複除去) を
/// 通した上位候補について text と isLearningTarget をダンプする。
/// penaltyExempt は learningCandidates (= isLearningTarget が立った候補の
/// 集合) から作られるため、このフラグが常用外候補に立っていれば
/// ペナルティが免除されてしまう。意図的に XCTFail し、失敗ログから回収する。
final class ProbeLearningFlags: XCTestCase {
    private func dumpFlags(romaji: String, label: String) -> [String] {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var composition = ComposingText()
        composition.insertAtCursorPosition(romaji, inputStyle: .roman2kana)
        let memoryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeLearningFlags-\(label)", isDirectory: true)
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        // fullInputCandidates と同一の RequestOptions。
        let results = converter.requestCandidates(composition, options: .init(
            N_best: 4,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryDir,
            sharedContainerURL: memoryDir,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "NumberKey 0.3.2")
        ))
        var lines = ["LEARNTARGET_PROBE input=\(label) target=\(composition.convertTarget) raw_main=\(results.mainResults.count)"]
        var seen = Set<String>()
        var rank = 0
        for candidate in results.mainResults {
            // fullInputCandidates と同一のフィルタ。
            guard candidate.inputable, !candidate.text.isEmpty else { continue }
            var remainder = composition
            remainder.prefixComplete(composingCount: candidate.composingCount)
            guard remainder.isEmpty, seen.insert(candidate.text).inserted else { continue }
            lines.append("LEARNTARGET_PROBE \(label) rank=\(rank) text=\(candidate.text) isLearningTarget=\(candidate.isLearningTarget)")
            rank += 1
            if rank >= 12 { break }
        }
        lines.append("LEARNTARGET_PROBE input=\(label) filtered_count=\(rank)")
        return lines
    }

    func testProbeLearningFlags() {
        var lines: [String] = []
        lines += dumpFlags(romaji: "kuruma", label: "kuruma")
        lines += dumpFlags(romaji: "a", label: "a")
        XCTFail(lines.joined(separator: "\n"))
    }
}
