import XCTest
@testable import KeyboardConversion

/// 常用漢字ボーナス (ビルド60、61 で強化) のゲート:
/// 1. 字種リストの健全性 (常用 2,136 / 人名用 863、出典 KANJIDIC2)
/// 2. 既存104件フィクスチャで top-1 が現行 0.865 (=90/104)、top-3 が
///    1.000 (=104/104) を下回らない
/// 3. 常用ケース (joyo_fixture.json): 常用外の漢字が沈み、正解が常用外を
///    含むケースでも致命的に沈まない。「くるま → 車 1位」(ビルド61) を含む
/// 4. JoyoKanji.shared が埋め込みフォールバックで必ず読み込めること
///    (ビルド60 実機で調整が無効化された事象の回帰防止)
final class JoyoKanjiTests: XCTestCase {
    private struct FixtureItem: Decodable {
        let candidates: [String]
        let expected: String
        let lm_sum: [Double]
    }
    private struct JoyoFixtureItem: Decodable {
        let kana: String
        let candidates: [String]
        let expected: String
        let lm_sum: [Double]
        /// 調整後に許容する expected の最低順位 (1始まり)。
        let maxRankAfter: Int
    }

    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    private func loadJoyoText() throws -> String {
        try String(contentsOf: repoURL("../Keyboard/joyo_kanji.txt"), encoding: .utf8)
    }

    func testKanjiListSanity() throws {
        let lines = try loadJoyoText().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, 2136, "常用漢字表は 2,136 字")
        XCTAssertEqual(lines[1].count, 863, "人名用漢字は 863 字")
        let joyo = JoyoKanji(text: try loadJoyoText())
        XCTAssertEqual(joyo.allowed.count, 2136 + 863)
        // スポットチェック: 亜は常用、噂は人名用、婀・痾・䳸は範囲外。
        XCTAssertEqual(joyo.adjustment(for: "亜"), JoyoKanji.bonus)
        XCTAssertEqual(joyo.adjustment(for: "噂"), JoyoKanji.bonus)
        XCTAssertEqual(joyo.adjustment(for: "婀"), -JoyoKanji.penaltyPerKanji)
        XCTAssertEqual(joyo.adjustment(for: "痾"), -JoyoKanji.penaltyPerKanji)
        XCTAssertEqual(joyo.adjustment(for: "䳸"), -JoyoKanji.penaltyPerKanji)
        // 漢字を含まない候補は中立、学習候補はペナルティ対象外。
        XCTAssertEqual(joyo.adjustment(for: "あ"), 0)
        XCTAssertEqual(joyo.adjustment(for: "婀", penaltyExempt: true), 0)
    }

    func testFixtureTop1DoesNotDegrade() throws {
        let joyo = JoyoKanji(text: try loadJoyoText())
        let fixtureData = try Data(contentsOf: repoURL("rerank_fixture.json"))
        let fixture = try JSONDecoder().decode([FixtureItem].self, from: fixtureData)
        XCTAssertEqual(fixture.count, 104)
        var hits = 0
        var top3 = 0
        for item in fixture {
            let scores = item.lm_sum.map { Float($0) }
            let order = joyoAdjustedOrder(candidates: item.candidates, scores: scores, joyo: joyo, penaltyExempt: [])
            let rank = order.firstIndex { item.candidates[$0] == item.expected }.map { $0 + 1 }
            if rank == 1 { hits += 1 }
            if let rank, rank <= 3 { top3 += 1 }
        }
        XCTAssertGreaterThanOrEqual(hits, 90, "top-1 は現行 0.865 (90/104) を下回らないこと: \(hits)/104")
        XCTAssertEqual(top3, 104, "top-3 は現行 1.000 (104/104) を下回らないこと: \(top3)/104")
    }

    /// ビルド60 の実機では JoyoKanji.shared の読み込み失敗で調整が丸ごと
    /// 無効化された (候補順が無調整の LM 順と一致)。shared は埋め込み
    /// リストを最終フォールバックに持つため、どの環境でも必ず使えること。
    func testSharedFallsBackToEmbeddedList() {
        let shared = JoyoKanji.shared
        XCTAssertNotNil(shared)
        XCTAssertEqual(shared?.allowed.count, 2136 + 863)
        let embedded = JoyoKanji(text: JoyoKanji.embeddedList)
        XCTAssertEqual(embedded.allowed.count, 2136 + 863)
        XCTAssertEqual(embedded.adjustment(for: "車"), JoyoKanji.bonus)
        XCTAssertEqual(embedded.adjustment(for: "俥"), -JoyoKanji.penaltyPerKanji)
        XCTAssertEqual(embedded.adjustment(for: "輅"), -JoyoKanji.penaltyPerKanji)
    }

    func testJoyoCases() throws {
        let joyo = JoyoKanji(text: try loadJoyoText())
        let fixtureData = try Data(contentsOf: repoURL("joyo_fixture.json"))
        let fixture = try JSONDecoder().decode([JoyoFixtureItem].self, from: fixtureData)
        XCTAssertFalse(fixture.isEmpty)
        for item in fixture {
            let scores = item.lm_sum.map { Float($0) }
            let plain = joyoAdjustedOrder(candidates: item.candidates, scores: scores, joyo: nil, penaltyExempt: [])
            let adjusted = joyoAdjustedOrder(candidates: item.candidates, scores: scores, joyo: joyo, penaltyExempt: [])
            let rankBefore = plain.firstIndex { item.candidates[$0] == item.expected }.map { $0 + 1 }
            let rankAfter = adjusted.firstIndex { item.candidates[$0] == item.expected }.map { $0 + 1 }
            XCTAssertNotNil(rankBefore)
            XCTAssertNotNil(rankAfter)
            if let rankAfter, let rankBefore {
                XCTAssertLessThanOrEqual(rankAfter, item.maxRankAfter,
                    "\(item.kana): expected \(item.expected) の調整後順位 \(rankAfter) (前 \(rankBefore)) が許容 \(item.maxRankAfter) を超えた")
            }
        }
    }
}
