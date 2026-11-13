import XCTest
@testable import PhraseStore

final class DictionaryPacksTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DictionaryPacksTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testParseKanaEntriesKeepOrderAndDedupe() {
        let tsv = "めんとり\t面取り\nすし\t寿司\nすし\t鮨\nすし\t寿司\n"
        let pack = DictionaryPackData.parse(Data(tsv.utf8))
        XCTAssertEqual(pack.surfaces(forKana: "めんとり"), ["面取り"])
        XCTAssertEqual(pack.surfaces(forKana: "すし"), ["寿司", "鮨"])
        XCTAssertEqual(pack.surfaces(forKana: "そば"), [])
    }

    func testParsePatternsAndCompletions() {
        let tsv = "OP\tOP\nOVA\tOVA\n6000\t6000\n"
        let pack = DictionaryPackData.parse(Data(tsv.utf8))
        XCTAssertEqual(pack.patternCompletions(forTyped: "op"), ["OP"])
        XCTAssertEqual(pack.patternCompletions(forTyped: "ov"), ["OVA"])
        XCTAssertEqual(pack.patternCompletions(forTyped: "OP"), [])
        XCTAssertEqual(pack.patternCompletions(forTyped: "o"), [])
    }

    func testStoreDefaultsToIndustrialOnly() {
        let store = DictionaryPackStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled(.industrial))
        XCTAssertFalse(store.isEnabled(.anime))
        XCTAssertFalse(store.isEnabled(.oshikatsuCommon))
        XCTAssertFalse(store.isEnabled(.oshikatsuMale))
        XCTAssertFalse(store.isEnabled(.oshikatsuFemale))
    }

    func testStoreTogglePersists() {
        let store = DictionaryPackStore(defaults: defaults)
        store.setEnabled(.anime, true)
        store.setEnabled(.industrial, false)
        let reloaded = DictionaryPackStore(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled(.anime))
        XCTAssertFalse(reloaded.isEnabled(.industrial))
    }

    func testLibraryLoadsOnlyEnabledPacksAndCaches() {
        var loadCount: [DictionaryPackID: Int] = [:]
        let library = DictionaryPackLibrary { id in
            loadCount[id, default: 0] += 1
            switch id {
            case .industrial: return DictionaryPackData.parse(Data("めんとり\t面取り\n".utf8))
            case .anime: return DictionaryPackData.parse(Data("めんとり\t麺取り\n".utf8))
            default: return DictionaryPackData()
            }
        }
        let store = DictionaryPackStore(defaults: defaults)
        XCTAssertEqual(library.surfaces(forKana: "めんとり", store: store), ["面取り"])
        XCTAssertEqual(library.surfaces(forKana: "めんとり", store: store), ["面取り"])
        XCTAssertEqual(loadCount[.industrial], 1)
        XCTAssertNil(loadCount[.anime])
        store.setEnabled(.anime, true)
        // パック順 (industrial → anime) に集め、重複は先勝ち。
        XCTAssertEqual(library.surfaces(forKana: "めんとり", store: store), ["面取り", "麺取り"])
    }
}
