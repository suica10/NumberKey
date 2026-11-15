import Foundation

// MARK: - 選択履歴 (先頭固定)
//
// ユーザーが一度確定した候補を、同じ読みの次回変換で候補列の先頭に
// 並べる (ユーザーの要望: 「一度変換した文字は左から並べれない？」)。
//
// 変換器側の学習 (ConversionService.learn) は従来どおり別に働くが、
// その効果は後段の LM リランクで押し戻され得る。履歴の固定は
// リランク・常用調整・辞書パック統合のすべてが終わった最終段で
// 行い、優先順位は 履歴 > SNS 先頭固定 > その他 とする。
//
// 保存するのは「読み (変換対象のかな文字列そのもの) → 確定した候補」
// の対だけで、ホスト側のテキストや前後の文脈は一切読まない・送らない。
// 保存先は辞書パック設定と同じ App Group の共有 UserDefaults
// (端末内のみ、ネットワーク送信なし)。

final class SelectionHistoryStore {
    private static let storageKey = "selectionHistory.v1"
    /// App Group (DictionaryPackStore / PurchaseFlags と一致させること)。
    private static let appGroupIdentifier = "group.jp.onejpkey.NumberKey"
    /// 1つの読みに保持する候補の上限 (新しい順)。
    static let maxChoicesPerReading = 3
    /// 保持する読みの総数の上限。記録の新しい順に保持し、古いものから捨てる。
    static let maxReadings = 500

    private let defaults: UserDefaults

    /// - Parameter defaults: 読み書き先。`nil` なら App Group の共有
    ///   スイート (取得できなければ .standard にフォールバック)。
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
    }

    // 保存形式: [[String]]。各要素は [読み, 第1候補, 第2候補, ...] で、
    // 要素 (読み) の並びも候補の並びも「記録が新しい順」。
    private func load() -> [[String]] {
        guard let raw = defaults.array(forKey: Self.storageKey) else { return [] }
        return raw.compactMap { $0 as? [String] }
    }

    private func save(_ entries: [[String]]) {
        defaults.set(entries, forKey: Self.storageKey)
    }

    /// 確定を記録する。同じ読み・同じ候補の再記録は順位の更新だけになる。
    func record(reading: String, choice: String) {
        guard !reading.isEmpty, !choice.isEmpty else { return }
        var entries = load()
        var choices: [String] = []
        if let index = entries.firstIndex(where: { $0.first == reading }) {
            choices = Array(entries.remove(at: index).dropFirst())
        }
        choices.removeAll { $0 == choice }
        choices.insert(choice, at: 0)
        choices = Array(choices.prefix(Self.maxChoicesPerReading))
        entries.insert([reading] + choices, at: 0)
        if entries.count > Self.maxReadings {
            entries = Array(entries.prefix(Self.maxReadings))
        }
        save(entries)
    }

    /// 読みに対する記録済み候補 (新しい順)。記録が無ければ空。
    func choices(for reading: String) -> [String] {
        guard let entry = load().first(where: { $0.first == reading }) else { return [] }
        return Array(entry.dropFirst())
    }

    /// 履歴候補を候補列の先頭へ寄せる (VC の候補統合の最終段)。
    /// 候補列に実在する候補だけを動かし、履歴にあっても変換器が今回
    /// 出していない候補は注入しない。履歴が無い・該当が無ければ
    /// 入力の順序をそのまま返す。
    static func applyingHistory(_ choices: [String], to candidates: [String]) -> [String] {
        guard !choices.isEmpty, !candidates.isEmpty else { return candidates }
        var head: [String] = []
        for choice in choices where candidates.contains(choice) && !head.contains(choice) {
            head.append(choice)
        }
        guard !head.isEmpty else { return candidates }
        return head + candidates.filter { !head.contains($0) }
    }
}
