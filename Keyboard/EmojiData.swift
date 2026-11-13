import Foundation

// 絵文字パネルのデータ（Foundation のみ、テスト可能に保つ）。
// カタログは Unicode 公式の emoji-test.txt から生成した emoji_data.txt
// （カテゴリ<TAB>スペース区切りの絵文字。生成は scripts/build_emoji_data.py）。

enum EmojiCatalog {
    struct Category: Equatable {
        let name: String
        let emojis: [String]
    }

    static func parse(_ data: Data) -> [Category] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Category(name: String(parts[0]), emojis: parts[1].split(separator: " ").map(String.init))
        }
    }

    static func loadBundled() -> [Category] {
        guard let url = Bundle(for: EmojiBundleAnchor.self).url(forResource: "emoji_data", withExtension: "txt"),
              let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }
}

/// 最近使った絵文字。拡張ローカルの UserDefaults に新しい順で保持する。
final class RecentEmojiStore {
    static let maxItems = 24
    private let defaults: UserDefaults
    private let key = "emoji.recents.v1"
    private(set) var items: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.stringArray(forKey: key) ?? []
    }

    func record(_ emoji: String) {
        items.removeAll { $0 == emoji }
        items.insert(emoji, at: 0)
        items = Array(items.prefix(Self.maxItems))
        defaults.set(items, forKey: key)
    }
}

private final class EmojiBundleAnchor {}
