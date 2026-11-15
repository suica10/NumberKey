import Foundation

/// クリップボード履歴の保存（App Group の共有 UserDefaults）。
/// 共有拡張（Share Extension）からの追記をキーボード側で読めるよう、
/// 以前のキーボード拡張自身の UserDefaults から App Group へ移した。
/// 旧保存先に履歴が残っていれば、初回に一度だけ引き継ぐ。
/// UIPasteboard の読み取りは呼び出し側（VC）が行い、文字列だけを渡す。
final class ClipboardHistoryStore {
    static let storageKey = "clipboard.history.v1"
    static let migrationKey = "clipboard.history.migratedToAppGroup.v1"
    static let appGroupIdentifier = "group.jp.onejpkey.NumberKey"
    static let maxItems = 30
    static let maxLength = 1000

    private let defaults: UserDefaults
    private(set) var items: [String] = []

    /// 通常の初期化。App Group が使えれば共有側を使い、旧保存先
    /// （拡張自身の UserDefaults.standard）から一度だけ移行する。
    /// App Group が使えない環境では従来どおり .standard にフォールバックする。
    convenience init() {
        if let suite = UserDefaults(suiteName: Self.appGroupIdentifier) {
            Self.migrateIfNeeded(from: .standard, to: suite)
            self.init(defaults: suite)
        } else {
            self.init(defaults: .standard)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    /// 旧保存先の履歴を App Group 側へ一度だけコピーする。
    /// 旧保存先にキー自体が無い場合は何もしない（フラグも立てない）。
    /// 共有拡張など別プロセスの空の保存先から先に呼ばれても、
    /// キーボード側の履歴を取りこぼさないための配慮。
    /// 移行フラグを立てるため、後で履歴を全削除しても復活しない。
    /// App Group 側に既に履歴がある場合は上書きしない。
    static func migrateIfNeeded(from legacy: UserDefaults, to shared: UserDefaults) {
        guard legacy !== shared, !shared.bool(forKey: migrationKey) else { return }
        guard let old = legacy.stringArray(forKey: storageKey) else { return }
        if shared.stringArray(forKey: storageKey) == nil {
            shared.set(old, forKey: storageKey)
        }
        shared.set(true, forKey: migrationKey)
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
