import XCTest
@testable import PhraseStore

final class PhraseStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PhraseStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAddAndReload() {
        let store = PhraseStore(defaults: defaults, legacyPhrases: { [] })
        XCTAssertTrue(store.add("よろしくお願いします。"))
        XCTAssertTrue(store.add("確認しました。"))
        XCTAssertEqual(store.phrases, ["よろしくお願いします。", "確認しました。"])
        let reloaded = PhraseStore(defaults: defaults)
        XCTAssertEqual(reloaded.phrases, store.phrases)
    }

    func testValidationAndLimits() {
        let store = PhraseStore(defaults: defaults, legacyPhrases: { [] })
        XCTAssertFalse(store.add(""))
        XCTAssertFalse(store.add("   "))
        XCTAssertFalse(store.add(String(repeating: "あ", count: 101)))
        XCTAssertFalse(store.add("改行\nを含む"))
        for i in 0..<PhraseBook.maxCount {
            XCTAssertTrue(store.add("定型文\(i)"))
        }
        XCTAssertFalse(store.add("21件目"))
        XCTAssertEqual(store.phrases.count, PhraseBook.maxCount)
    }

    func testUpdateAndRemove() {
        let store = PhraseStore(defaults: defaults, legacyPhrases: { [] })
        XCTAssertTrue(store.add("ひとつ目"))
        XCTAssertTrue(store.add("ふたつ目"))
        XCTAssertTrue(store.update(at: 1, "差し替え"))
        XCTAssertEqual(store.phrases, ["ひとつ目", "差し替え"])
        XCTAssertFalse(store.update(at: 0, ""))
        store.remove(at: 0)
        XCTAssertEqual(store.phrases, ["差し替え"])
    }

    func testSeedPhrasesOnFreshInstall() {
        let store = PhraseStore(defaults: defaults)
        XCTAssertEqual(store.phrases, PhraseStore.seedPhrases)
    }

    func testLegacyImportRunsOnce() {
        var legacyCalls = 0
        let legacy: () -> [String]? = {
            legacyCalls += 1
            return ["旧アプリで登録した文", ""]
        }
        let store = PhraseStore(defaults: defaults, legacyPhrases: legacy)
        XCTAssertEqual(store.phrases, ["旧アプリで登録した文"])
        let second = PhraseStore(defaults: defaults, legacyPhrases: legacy)
        XCTAssertEqual(second.phrases, ["旧アプリで登録した文"])
        XCTAssertEqual(legacyCalls, 1)
    }

    func testMoveReordersAndPersists() {
        let store = PhraseStore(defaults: defaults, legacyPhrases: { ["a", "b", "c"] })
        store.move(from: 2, to: 0)
        XCTAssertEqual(store.phrases, ["c", "a", "b"])
        store.move(from: 0, to: 2)
        XCTAssertEqual(store.phrases, ["a", "b", "c"])
        store.move(from: 1, to: 1)
        store.move(from: 9, to: 0)
        XCTAssertEqual(store.phrases, ["a", "b", "c"])
        let reloaded = PhraseStore(defaults: defaults, legacyPhrases: { nil })
        XCTAssertEqual(reloaded.phrases, ["a", "b", "c"])
    }

    func testTextBufferMarkedFlow() {
        var buffer = TextBuffer()
        buffer.setMarked("にほんご")
        XCTAssertEqual(buffer.displayText, "にほんご")
        buffer.unmark()
        XCTAssertEqual(buffer.displayText, "にほんご")
        buffer.insert("、")
        buffer.setMarked("とうきょう")
        XCTAssertEqual(buffer.finalText(), "にほんご、とうきょう")
        buffer.deleteBackward()
        XCTAssertEqual(buffer.displayText, "にほんご、とうきょ")
        buffer.unmark()
        buffer.deleteBackward()
        XCTAssertEqual(buffer.displayText, "にほんご、とうき")
        XCTAssertFalse(buffer.isEmpty)
    }
}
