import Foundation

/// 常用漢字ボーナス (ビルド60)。
///
/// 背景: 変換器+LM の候補順では、噫・鑰・䳸・婀・痾 のような常用外の
/// 漢字が上位に来ることがある (ユーザー報告 2026-11-14)。LM は文の
/// 自然さで順位付けしており、字種の常用性は見ていない。そこでリランク段で
/// 字種による小さなスコア調整を加える:
/// - 候補内の漢字がすべて常用漢字表 (2,136字) + 人名用漢字 (863字) の
///   範囲内 → ボーナス
/// - 常用・人名用以外の漢字を含む候補 → その字数ぶんペナルティ
/// - 漢字を含まない候補 (かな・英数・記号のみ) → 中立
/// - 学習候補 (過去にユーザーが選んだもの) はペナルティ対象外
///
/// 字種リスト (Keyboard/joyo_kanji.txt) の出典は KANJIDIC2 (EDRDG) の
/// grade 分類: 常用 = grade 1–6, 8 (2,136字を検証済み)、人名用 =
/// grade 9, 10 (863字)。大きさは Prototype の評価で決定した
/// (既存104件フィクスチャの top-1 を下げない範囲で常用ケースが改善する値)。
/// リストが読めなければ shared は nil になり、呼び出し側は調整なしの
/// 従来順にフォールバックする (RerankScorer と同じ安全弁)。
final class JoyoKanji {
    static let shared: JoyoKanji? = {
        guard let url = Bundle.main.url(forResource: "joyo_kanji", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return JoyoKanji(text: text)
    }()

    /// 常用・人名用のみで構成される候補へのボーナス (LM の log-prob 尺度)。
    static let bonus: Float = 1.5
    /// 常用外漢字 1 字あたりのペナルティ。LM の語彙に無い漢字は unk 化して
    /// 短い候補ほど不当に高いスコア (-15.69 付近の plateau) を得るため、
    /// 「あ」の実測でその差 (~4.2) を超える 4.5 とした。既存104件
    /// フィクスチャの top-1 は B/P の広い範囲で不変 (90/104) なことも
    /// あわせて確認済み。
    static let penaltyPerKanji: Float = 4.5

    /// 常用+人名用の許可集合 (Unicode スカラ値)。
    let allowed: Set<UInt32>

    init(text: String) {
        var set = Set<UInt32>()
        for scalar in text.unicodeScalars where JoyoKanji.isKanji(scalar.value) {
            set.insert(scalar.value)
        }
        allowed = set
    }

    /// 字種判定の対象とする漢字ブロック。々 (U+3005) などの繰り返し記号は
    /// 対象外 (中立) — 人々・時々 のような常用語を誤って罰しないため。
    static func isKanji(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2EBEF).contains(value)
            || (0x2F800...0x2FA1F).contains(value)
    }

    /// 候補文字列 1 件へのスコア加算量。
    func adjustment(for candidate: String, penaltyExempt: Bool = false) -> Float {
        var sawKanji = false
        var outsideCount = 0
        for scalar in candidate.unicodeScalars where JoyoKanji.isKanji(scalar.value) {
            sawKanji = true
            if !allowed.contains(scalar.value) { outsideCount += 1 }
        }
        guard sawKanji else { return 0 }
        if outsideCount == 0 { return JoyoKanji.bonus }
        return penaltyExempt ? 0 : -JoyoKanji.penaltyPerKanji * Float(outsideCount)
    }
}

/// LM スコアに常用漢字ボーナスを加えた最終順位 (候補のインデックス列)。
/// 同点は元の順序を保つ安定ソート。joyo が nil のときは素の LM 順。
func joyoAdjustedOrder(candidates: [String], scores: [Float], joyo: JoyoKanji?, penaltyExempt: Set<String>) -> [Int] {
    guard let joyo else {
        return candidates.indices.sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
    }
    let adjusted = candidates.indices.map { i in
        scores[i] + joyo.adjustment(for: candidates[i], penaltyExempt: penaltyExempt.contains(candidates[i]))
    }
    return candidates.indices.sorted { a, b in
        adjusted[a] != adjusted[b] ? adjusted[a] > adjusted[b] : a < b
    }
}
