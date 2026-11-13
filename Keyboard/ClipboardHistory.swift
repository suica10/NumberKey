import Foundation

/// クリップボード履歴の保存（キーボード拡張自身の UserDefaults）。
/// 定型文と同じく、再署名で壊れないよう App Group は使わない。
/// UIPasteboard の読み取りは呼び出し側（VC）が行い、文字列だけを渡す。
final class ClipboardHistoryStore {
    static let storageKey = "clipboard.history.v1"
    static let maxItems = 30
    static let maxLength = 1000

    private let defaults: UserDefaults
    private(set) var items: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    func reload() {
        items = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    /// 新しいクリップボード内容を先頭に記録する。空白のみ・長すぎるものは
    /// 記録しない。既にある同じ内容は先頭へ移動する（重複させない）。
    func record(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxLength else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > Self.maxItems { items = Array(items.prefix(Self.maxItems)) }
        persist()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        defaults.set(items, forKey: Self.storageKey)
    }
}
