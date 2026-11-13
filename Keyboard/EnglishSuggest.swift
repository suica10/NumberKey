import Foundation

// 英語入力の補完・自動修正エンジン（Foundation のみ、テスト可能に保つ）。
//
// 単語リストは AOSP LatinIME の英語辞書から生成した english_words.txt
// （"word<TAB>freq"、freq は 0–255 の頻度。生成は scripts/build_english_wordlist.py）。
//
// 補完はソート済み配列の二分探索、修正候補は「1編集の生成＋辞書照合」で出す。
// 距離2の探索は候補数が二乗になるため、自動修正の最終判断でのみ長さ制限付きで行う。

struct EnglishLexicon {
    let words: [String]
    let frequencies: [Int]
    private let frequencyMap: [String: Int]

    init(words unsortedWords: [String], frequencies unsortedFrequencies: [Int]) {
        let pairs = zip(unsortedWords, unsortedFrequencies).sorted { $0.0 < $1.0 }
        words = pairs.map { $0.0 }
        frequencies = pairs.map { $0.1 }
        var map: [String: Int] = [:]
        map.reserveCapacity(words.count)
        for (word, frequency) in pairs { map[word] = frequency }
        frequencyMap = map
    }

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var parsedWords: [String] = []
        var parsedFrequencies: [Int] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let frequency = Int(parts[1]) else { continue }
            parsedWords.append(String(parts[0]))
            parsedFrequencies.append(frequency)
        }
        guard !parsedWords.isEmpty else { return nil }
        self.init(words: parsedWords, frequencies: parsedFrequencies)
    }

    /// キーボード拡張のバンドルから同梱の単語リストを読む。取れなければ nil（機能オフ）。
    static func loadBundled() -> EnglishLexicon? {
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: "english_words", withExtension: "txt"),
              let data = try? Data(contentsOf: url) else { return nil }
        return EnglishLexicon(data: data)
    }

    func contains(_ word: String) -> Bool { frequencyMap[word] != nil }

    func frequency(of word: String) -> Int { frequencyMap[word] ?? 0 }

    /// prefix で始まる単語を頻度順に返す（prefix 自身は除く）。
    func completions(for prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid] < prefix { low = mid + 1 } else { high = mid }
        }
        // 接頭辞の範囲を走査しながら上位 limit 件だけを保持する。全件を集めて
        // ソートすると、短い接頭辞では毎打鍵で数千件規模の処理になってしまう。
        var top: [(String, Int)] = []
        top.reserveCapacity(limit + 1)
        var index = low
        while index < words.count, words[index].hasPrefix(prefix) {
            if words[index] != prefix {
                let frequency = frequencies[index]
                if top.count < limit {
                    top.append((words[index], frequency))
                } else if let weakest = top.indices.min(by: { top[$0].1 < top[$1].1 }), frequency > top[weakest].1 {
                    top[weakest] = (words[index], frequency)
                }
            }
            index += 1
        }
        return top.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// 編集距離1の生成候補のうち辞書にあるものを頻度順に返す。
    func corrections(for word: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var found: [(String, Int)] = []
        for candidate in Self.edits1(word) where candidate != word {
            if let frequency = frequencyMap[candidate] { found.append((candidate, frequency)) }
        }
        found.sort { $0.1 > $1.1 }
        return found.prefix(limit).map { $0.0 }
    }

    /// 候補バーの並び: 入力した単語そのもの（確定用）を先頭に、
    /// 単語が辞書に無ければ修正候補、続いて補完。
    func suggestions(for word: String, limit: Int = 6) -> [String] {
        guard word.count >= 2 else { return [] }
        var result = [word]
        if !contains(word) {
            result += corrections(for: word, limit: 2)
        }
        for completion in completions(for: word, limit: limit) where !result.contains(completion) {
            result.append(completion)
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    /// 日本語モードで打たれたローマ字に対する英字候補。
    /// 入力そのままを常に出し、英単語として成立する場合は先頭大文字も出す。
    func englishCandidates(forRomaji raw: String) -> [String] {
        guard raw.count >= 2, raw.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) else { return [] }
        var result = [raw]
        if contains(raw) {
            result.append(raw.prefix(1).uppercased() + String(raw.dropFirst()))
        }
        return result
    }

    /// スペース確定時に置き換えてよい確信がある場合だけ修正先を返す。
    /// 辞書にある単語・短すぎる単語は対象外。距離2は頻度が非常に高い語に限る。
    func autocorrect(for word: String) -> String? {
        guard word.count >= 3, !contains(word) else { return nil }
        if let best = corrections(for: word, limit: 1).first, frequency(of: best) >= 50 {
            return best
        }
        guard word.count <= 7 else { return nil }
        var best: (String, Int)?
        for middle in Self.edits1(word) {
            for candidate in Self.edits1(middle) where candidate != word {
                guard let frequency = frequencyMap[candidate], frequency >= 120 else { continue }
                if best == nil || frequency > best!.1 { best = (candidate, frequency) }
            }
        }
        return best?.0
    }

    /// 削除・転置・置換・挿入による編集距離1の文字列すべて。
    private static func edits1(_ word: String) -> Set<String> {
        let letters = Array("abcdefghijklmnopqrstuvwxyz'")
        let chars = Array(word)
        var result = Set<String>()
        for i in chars.indices {
            var deleted = chars
            deleted.remove(at: i)
            result.insert(String(deleted))
            if i + 1 < chars.count {
                var swapped = chars
                swapped.swapAt(i, i + 1)
                result.insert(String(swapped))
            }
            for letter in letters {
                var replaced = chars
                replaced[i] = letter
                result.insert(String(replaced))
                var inserted = chars
                inserted.insert(letter, at: i)
                result.insert(String(inserted))
            }
        }
        for letter in letters {
            result.insert(word + String(letter))
        }
        return result
    }
}

private final class BundleAnchor {}
