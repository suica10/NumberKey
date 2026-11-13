import Foundation

/// タイポ補正 (トリガーゲート付きフォールバック) のバリアント生成。
///
/// 方式は Prototype/lm/gen_typo_fixture.py の移植: ユーザーが打った
/// ローマ字の1編集 (隣接キー置換・転置・削除・隣接挿入) バリアントを
/// 生成し、かなに戻してそれぞれ変換し、候補をプールして LM に選ばせる。
/// 実測 (Prototype/lm/typo_eval.py, gate_calibrate.py): 補正なしでは
/// タイポ入力の top-1 は 0.000、プール+LM で 0.505 まで回復する一方、
/// 無条件にプールすると正常入力の勝者を 27.4% 倒してしまう。だから
/// 実運用は「通常変換の勝者の LM スコアが低いときだけ発動し、プールの
/// 最良がマージン以上上回ったときだけ差し替える」ゲート付きにする。
/// ゲート定数は gate_calibrate.py のスイープで決めた値 (下記)。
enum TypoCorrection {
    /// ゲート: 勝者の lm_avg (1トークンあたり対数尤度) がこの値未満の
    /// ときだけ補正を試す。キャリブレーション (gate_calibrate.py の
    /// 拡張スイープ, n=119): この閾値と下記マージンの組で、タイポ回復率
    /// 0.479 / 正常入力の王座交代率 0.025 (交代は全て元々誤っていた
    /// 勝者に対してで、正解の勝者を壊した例は 0/90)。
    static let gateThresholdAvg: Float = -3.2
    /// 差し替えマージン: プール最良の lm_sum が勝者の lm_sum をこの差
    /// 以上上回ったときだけ差し替える。キャリブレーション済みの値。
    static let marginSum: Float = 8.0

    /// バリアント総数上限と種類別予算 (キャリブレーションと一致)。
    /// 挿入復元は組み合わせが爆発するので最後・最小に予算化する。
    static let variantCap = 120
    static let budgets: [(kind: String, cap: Int)] = [("sub", 56), ("trans", 16), ("del", 16), ("ins", 32)]

    /// LM の avg スコアの分母 (RerankScorer の教師 forcing トークン数:
    /// 先頭に <bos>、末尾に <eos>、文字列は 62 スカラーで打ち切り)。
    static func tokenCount(of text: String) -> Int {
        min(text.unicodeScalars.count, 62) + 1
    }

    // MARK: - かな <-> ローマ字 (AzooKey 式綴り、gen_typo_fixture.py と同一)

    private static let kanaRomajiPairs: [(String, String)] = [
        ("あ", "a"), ("い", "i"), ("う", "u"), ("え", "e"), ("お", "o"),
        ("か", "ka"), ("き", "ki"), ("く", "ku"), ("け", "ke"), ("こ", "ko"),
        ("さ", "sa"), ("し", "shi"), ("す", "su"), ("せ", "se"), ("そ", "so"),
        ("た", "ta"), ("ち", "chi"), ("つ", "tsu"), ("て", "te"), ("と", "to"),
        ("な", "na"), ("に", "ni"), ("ぬ", "nu"), ("ね", "ne"), ("の", "no"),
        ("は", "ha"), ("ひ", "hi"), ("ふ", "fu"), ("へ", "he"), ("ほ", "ho"),
        ("ま", "ma"), ("み", "mi"), ("む", "mu"), ("め", "me"), ("も", "mo"),
        ("や", "ya"), ("ゆ", "yu"), ("よ", "yo"),
        ("ら", "ra"), ("り", "ri"), ("る", "ru"), ("れ", "re"), ("ろ", "ro"),
        ("わ", "wa"), ("を", "wo"), ("ん", "n"),
        ("が", "ga"), ("ぎ", "gi"), ("ぐ", "gu"), ("げ", "ge"), ("ご", "go"),
        ("ざ", "za"), ("じ", "ji"), ("ず", "zu"), ("ぜ", "ze"), ("ぞ", "zo"),
        ("だ", "da"), ("ぢ", "di"), ("づ", "du"), ("で", "de"), ("ど", "do"),
        ("ば", "ba"), ("び", "bi"), ("ぶ", "bu"), ("べ", "be"), ("ぼ", "bo"),
        ("ぱ", "pa"), ("ぴ", "pi"), ("ぷ", "pu"), ("ぺ", "pe"), ("ぽ", "po"),
        ("ぁ", "la"), ("ぃ", "li"), ("ぅ", "lu"), ("ぇ", "le"), ("ぉ", "lo"),
        ("ゎ", "lwa"), ("ー", "-"),
        ("きゃ", "kya"), ("きゅ", "kyu"), ("きょ", "kyo"),
        ("しゃ", "sha"), ("しゅ", "shu"), ("しょ", "sho"),
        ("ちゃ", "cha"), ("ちゅ", "chu"), ("ちょ", "cho"),
        ("にゃ", "nya"), ("にゅ", "nyu"), ("にょ", "nyo"),
        ("ひゃ", "hya"), ("ひゅ", "hyu"), ("ひょ", "hyo"),
        ("みゃ", "mya"), ("みゅ", "myu"), ("みょ", "myo"),
        ("りゃ", "rya"), ("りゅ", "ryu"), ("りょ", "ryo"),
        ("ぎゃ", "gya"), ("ぎゅ", "gyu"), ("ぎょ", "gyo"),
        ("じゃ", "ja"), ("じゅ", "ju"), ("じょ", "jo"),
        ("ぢゃ", "dya"), ("ぢゅ", "dyu"), ("ぢょ", "dyo"),
        ("びゃ", "bya"), ("びゅ", "byu"), ("びょ", "byo"),
        ("ぴゃ", "pya"), ("ぴゅ", "pyu"), ("ぴょ", "pyo"),
    ]
    private static let kanaToRomajiMap: [String: String] = Dictionary(uniqueKeysWithValues: kanaRomajiPairs)
    private static let romajiToKanaMap: [String: String] = {
        var map: [String: String] = [:]
        for (kana, roma) in kanaRomajiPairs where map[roma] == nil {
            map[roma] = kana // 最勝ち (綴りの重複は "n" のみ)
        }
        return map
    }()

    private static func token(_ chars: [Character], _ start: Int, _ length: Int) -> String? {
        guard start >= 0, start + length <= chars.count else { return nil }
        return String(chars[start ..< start + length])
    }

    static func kanaToRomaji(_ kana: String) -> String? {
        let chars = Array(kana)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "っ" {
                // 次トークンの頭文字を重ねる。次のトークンが無ければ失敗。
                let next = token(chars, i + 1, 2).flatMap { kanaToRomajiMap[$0] }
                    ?? token(chars, i + 1, 1).flatMap { kanaToRomajiMap[$0] }
                guard let nextRomaji = next, let first = nextRomaji.first,
                      !"aiueon-".contains(first) else { return nil }
                out.append(first)
                i += 1
                continue
            }
            if let tok = token(chars, i, 2), let roma = kanaToRomajiMap[tok] {
                out += roma
                i += 2
                continue
            }
            if let tok = token(chars, i, 1), let roma = kanaToRomajiMap[tok] {
                out += roma
                i += 1
                continue
            }
            return nil
        }
        return out
    }

    static func romajiToKana(_ roma: String) -> String? {
        let chars = Array(roma)
        var out = ""
        var i = 0
        while i < chars.count {
            // 促音: 同じ子音の連続 (nn と母音は除く) は「っ」。
            if i + 1 < chars.count, chars[i] == chars[i + 1], !"aiueon".contains(chars[i]) {
                out += "っ"
                i += 1
                continue
            }
            var matched: (tok: String, kana: String)?
            for length in [3, 2, 1] {
                if let tok = token(chars, i, length), let kana = romajiToKanaMap[tok] {
                    matched = (tok, kana)
                    break
                }
            }
            guard let (tok, kana) = matched else { return nil }
            // 単独の "n" は母音・y の前では曖昧 (ん と な行の境界) なので失敗。
            if tok == "n", i + 1 < chars.count, "aiueoy".contains(chars[i + 1]) {
                return nil
            }
            out += kana
            i += tok.count
        }
        return out
    }

    // MARK: - 1編集バリアント (QWERTY 隣接)

    private static let adjacency: [Character: String] = [
        "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh",
        "u": "yihj", "i": "uojk", "o": "ipkl", "p": "ol",
        "a": "qwsz", "s": "awedzx", "d": "serfcx", "f": "drtgcv", "g": "ftyhvb",
        "h": "gyujbn", "j": "huiknm", "k": "jiolm", "l": "kop",
        "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb", "b": "vghn",
        "n": "bhjm", "m": "njk", "-": "p",
    ]

    private static func edits(_ roma: String) -> (subs: [String], dels: [String], trans: [String], inss: [String]) {
        let chars = Array(roma)
        var subs: [String] = [], dels: [String] = [], trans: [String] = [], inss: [String] = []
        for i in chars.indices {
            for a in adjacency[chars[i]] ?? "" {
                var c = chars
                c[i] = a
                subs.append(String(c))
            }
            var d = chars
            d.remove(at: i)
            dels.append(String(d))
            if i + 1 < chars.count {
                var t = chars
                t.swapAt(i, i + 1)
                trans.append(String(t))
            }
        }
        // 挿入復元: 落ちたキーは両隣のキーの近くにあるはずなので、
        // ギャップの左右の隣接文字の近傍を候補にする。
        for gap in 0 ... chars.count {
            var letters = Set<Character>()
            if gap > 0 { letters.formUnion(adjacency[chars[gap - 1]] ?? "") }
            if gap < chars.count { letters.formUnion(adjacency[chars[gap]] ?? "") }
            for a in letters.sorted() {
                var c = chars
                c.insert(a, at: gap)
                inss.append(String(c))
            }
        }
        return (subs, dels, trans, inss)
    }

    /// 入力かなに対するバリアントかな一覧 (種類別予算付き、総数上限あり)。
    /// キャリブレーション (gate_calibrate.py) と同じ選択規則。
    static func variantKanas(forKana kana: String) -> [String] {
        guard let roma = kanaToRomaji(kana) else { return [] }
        let e = edits(roma)
        let own = romajiToKana(roma)
        func kanaSet(_ variants: [String]) -> Set<String> {
            var set = Set<String>()
            for v in variants {
                if let k = romajiToKana(v) { set.insert(k) }
            }
            if let own { set.remove(own) }
            return set
        }
        let sets: [String: Set<String>] = [
            "sub": kanaSet(e.subs), "trans": kanaSet(e.trans),
            "del": kanaSet(e.dels), "ins": kanaSet(e.inss),
        ]
        var selected: [String] = []
        var seen = Set<String>()
        var leftover: [String: [String]] = [:]
        for (kind, cap) in budgets {
            let list = (sets[kind] ?? []).subtracting(seen).sorted()
            leftover[kind] = Array(list.dropFirst(cap))
            for v in list.prefix(cap) where seen.insert(v).inserted {
                selected.append(v)
            }
        }
        for kind in ["ins", "sub", "trans", "del"] {
            for v in leftover[kind] ?? [] {
                if selected.count >= variantCap { break }
                if seen.insert(v).inserted { selected.append(v) }
            }
            if selected.count >= variantCap { break }
        }
        return selected
    }
}
