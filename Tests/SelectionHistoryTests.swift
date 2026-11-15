import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion
@testable import PhraseStore

/// 選択履歴の先頭固定 (ビルド65、ユーザーの要望「一度変換した文字は
/// 左から並べれない？」) の検証。単体のストアだけでなく、製品経路
/// (実変換器 + 実LM + ConversionService.candidates → 辞書パック統合 →
/// 履歴適用という VC と同じ段取り) を通して確認する。VC の commit が
/// 行う記録は SelectionHistoryStore.record(reading:choice:) そのもの
/// で、読みは候補生成に使った convertTarget を渡す。
final class SelectionHistoryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SelectionHistoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    private func makeScorer() throws -> RerankScorer {
        try RerankScorer(
            weightsURL: repoURL("../Keyboard/rerank_weights.bin"),
            vocabURL: repoURL("../Keyboard/rerank_vocab.json"))
    }

    private func teijiComposition() -> ComposingText {
        var composition = ComposingText()
        composition.insertAtCursorPosition("teiji", inputStyle: .roman2kana)
        return composition
    }

    /// (a) ていじ で 定時 を一度確定すると、次回の ていじ 変換では
    /// LM の順位 (実機では 定時 は4番目) に関わらず 定時 が先頭に来る。
    func testCommittedChoicePinsToHeadThroughService() async throws {
        ConversionService.scorerOverride = try makeScorer()
        defer { ConversionService.scorerOverride = nil }
        let store = SelectionHistoryStore(defaults: defaults)
        let service = ConversionService()
        let composition = teijiComposition()

        let baseline = await service.candidates(for: composition, generation: 1) ?? []
        XCTAssertTrue(baseline.contains("定時"), "前提: 定時 が候補に無い: \(baseline)")
        XCTAssertNotEqual(baseline.first, "定時", "前提: 素の LM 順では 定時 は先頭でない: \(baseline)")

        // VC の commit(learn: true) が行う記録そのもの。
        store.record(reading: composition.convertTarget, choice: "定時")

        // VC の候補統合と同じ段取り: サービス結果 → パック統合 → 履歴 (最終段)。
        let rerun = await service.candidates(for: composition, generation: 2) ?? []
        let merged = DictionaryPackLibrary.mergingPacks(into: rerun, pinned: [], appended: [])
        let final = SelectionHistoryStore.applyingHistory(
            store.choices(for: composition.convertTarget), to: merged)
        XCTAssertEqual(final.first, "定時", "一度確定した 定時 が先頭に来ること: \(final)")
        XCTAssertEqual(Array(final.dropFirst()), merged.filter { $0 != "定時" },
                       "先頭以外は元の順序を保つこと: \(final)")
    }

    /// 優先順位: 履歴は SNS の先頭固定よりも前に来る。
    func testHistoryBeatsSNSPinning() {
        let store = SelectionHistoryStore(defaults: defaults)
        store.record(reading: "ていじ", choice: "定時")
        let merged = DictionaryPackLibrary.mergingPacks(
            into: ["提示", "定時"], pinned: ["SNS表記"], appended: ["末尾表記"])
        XCTAssertEqual(merged, ["SNS表記", "提示", "定時", "末尾表記"])
        let final = SelectionHistoryStore.applyingHistory(store.choices(for: "ていじ"), to: merged)
        XCTAssertEqual(final, ["定時", "SNS表記", "提示", "末尾表記"])
    }

    /// (b) 2つ目の異なる選択を確定すると、新しい順 (直近が先) で並ぶ。
    func testSecondChoiceUpdatesRecencyOrder() async throws {
        ConversionService.scorerOverride = try makeScorer()
        defer { ConversionService.scorerOverride = nil }
        let store = SelectionHistoryStore(defaults: defaults)
        let service = ConversionService()
        let composition = teijiComposition()

        store.record(reading: composition.convertTarget, choice: "定時")
        store.record(reading: composition.convertTarget, choice: "提示")
        XCTAssertEqual(store.choices(for: composition.convertTarget), ["提示", "定時"])

        let rerun = await service.candidates(for: composition, generation: 1) ?? []
        let final = SelectionHistoryStore.applyingHistory(
            store.choices(for: composition.convertTarget), to: rerun)
        XCTAssertEqual(Array(final.prefix(2)), ["提示", "定時"],
                       "履歴の新しい順に先頭へ並ぶこと: \(final)")
    }

    /// (c) 記録の無い読みでは候補順は変わらない。
    func testUnknownReadingLeavesOrderUnchanged() async throws {
        ConversionService.scorerOverride = try makeScorer()
        defer { ConversionService.scorerOverride = nil }
        let store = SelectionHistoryStore(defaults: defaults)
        let service = ConversionService()
        let composition = teijiComposition()

        store.record(reading: "べつのよみ", choice: "定時")
        XCTAssertEqual(store.choices(for: composition.convertTarget), [])
        let baseline = await service.candidates(for: composition, generation: 1) ?? []
        let final = SelectionHistoryStore.applyingHistory(
            store.choices(for: composition.convertTarget), to: baseline)
        XCTAssertEqual(final, baseline)
        XCTAssertEqual(SelectionHistoryStore.applyingHistory([], to: baseline), baseline)
    }

    /// (d) 記録済み候補が今回の変換器出力に無い場合は注入しない。
    func testRecordedCandidateAbsentIsNotInjected() async throws {
        ConversionService.scorerOverride = try makeScorer()
        defer { ConversionService.scorerOverride = nil }
        let store = SelectionHistoryStore(defaults: defaults)
        let service = ConversionService()
        let composition = teijiComposition()

        let ghost = "この候補は変換器から出ない"
        store.record(reading: composition.convertTarget, choice: ghost)
        let baseline = await service.candidates(for: composition, generation: 1) ?? []
        XCTAssertFalse(baseline.contains(ghost))
        let final = SelectionHistoryStore.applyingHistory(
            store.choices(for: composition.convertTarget), to: baseline)
        XCTAssertEqual(final, baseline, "実在しない候補を注入しないこと: \(final)")
    }

    /// 1つの読みに保持するのは直近3件まで (古いものから落ちる)。
    func testChoicesPerReadingCappedAtThree() {
        let store = SelectionHistoryStore(defaults: defaults)
        for choice in ["候補1", "候補2", "候補3", "候補4"] {
            store.record(reading: "よみ", choice: choice)
        }
        XCTAssertEqual(store.choices(for: "よみ"), ["候補4", "候補3", "候補2"])
        // 同じ候補の再記録は複製せず先頭へ繰り上がるだけ。
        store.record(reading: "よみ", choice: "候補3")
        XCTAssertEqual(store.choices(for: "よみ"), ["候補3", "候補4", "候補2"])
    }

    /// 読みの総数は上限までで、古い読みから捨てる。
    func testReadingsCappedWithLRUEviction() {
        let store = SelectionHistoryStore(defaults: defaults)
        let total = SelectionHistoryStore.maxReadings + 5
        for index in 0..<total {
            store.record(reading: "よみ\(index)", choice: "候補\(index)")
        }
        XCTAssertEqual(store.choices(for: "よみ0"), [], "最も古い読みは捨てられること")
        XCTAssertEqual(store.choices(for: "よみ\(total - 1)"), ["候補\(total - 1)"])
    }

    /// 保存は UserDefaults 経由でインスタンスをまたいで残る。
    func testHistoryPersistsAcrossStoreInstances() {
        SelectionHistoryStore(defaults: defaults).record(reading: "ていじ", choice: "定時")
        let reopened = SelectionHistoryStore(defaults: defaults)
        XCTAssertEqual(reopened.choices(for: "ていじ"), ["定時"])
    }
}
