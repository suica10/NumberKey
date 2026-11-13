import XCTest
@testable import PhraseStore

final class EmojiDataTests: XCTestCase {
    func testCatalogParse() {
        let data = Data("顔\t😀 😁\n旗\t🇯🇵 🇺🇸\n".utf8)
        let categories = EmojiCatalog.parse(data)
        XCTAssertEqual(categories.count, 2)
        XCTAssertEqual(categories[0].name, "顔")
        XCTAssertEqual(categories[0].emojis, ["😀", "😁"])
        XCTAssertEqual(categories[1].emojis, ["🇯🇵", "🇺🇸"])
    }

    func testRecentsDedupeAndCap() {
        let defaults = UserDefaults(suiteName: "EmojiDataTests-\(UUID().uuidString)")!
        let store = RecentEmojiStore(defaults: defaults)
        store.record("😀")
        store.record("🎉")
        store.record("😀")
        XCTAssertEqual(store.items, ["😀", "🎉"])
        for index in 0..<30 { store.record("e\(index)") }
        XCTAssertEqual(store.items.count, RecentEmojiStore.maxItems)
        XCTAssertEqual(RecentEmojiStore(defaults: defaults).items, store.items)
    }

    func testRecentsPruneDropsUnknown() {
        let defaults = UserDefaults(suiteName: "EmojiDataTests-\(UUID().uuidString)")!
        let store = RecentEmojiStore(defaults: defaults)
        store.record("😀")
        store.record("🫝")
        store.retainOnly(valid: ["😀", "🎉"])
        XCTAssertEqual(store.items, ["😀"])
        XCTAssertEqual(RecentEmojiStore(defaults: defaults).items, ["😀"])
    }
}
