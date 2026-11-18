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

    func testStoreDefaultsToIndustrialAndSNS() {
        let store = DictionaryPackStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled(.industrial))
        XCTAssertTrue(store.isEnabled(.sns))
        XCTAssertFalse(store.isEnabled(.anime))
        XCTAssertFalse(store.isEnabled(.company))
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

    // MARK: - v0.3.31: 設定の App Group 共有と移行

    private func makeExtraDefaults() -> (UserDefaults, String) {
        let name = "DictionaryPacksTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testStoreMigratesLegacyExtensionSettingsOnFirstRead() {
        let (shared, sharedName) = makeExtraDefaults()
        let (legacy, legacyName) = makeExtraDefaults()
        defer {
            shared.removePersistentDomain(forName: sharedName)
            legacy.removePersistentDomain(forName: legacyName)
        }
        // 0.3.30 までの拡張ローカル設定: ユーザーは SNS を OFF、アニメを ON にしていた。
        legacy.set(["anime", "industrial"], forKey: "dictionaryPacks.enabled.v2")
        let store = DictionaryPackStore(defaults: shared, legacyDefaults: legacy)
        XCTAssertTrue(store.isEnabled(.anime))
        XCTAssertTrue(store.isEnabled(.industrial))
        XCTAssertFalse(store.isEnabled(.sns))
        // 共有先へ写っているので、移行元なしでも同じ値が読める。
        let reloaded = DictionaryPackStore(defaults: shared)
        XCTAssertTrue(reloaded.isEnabled(.anime))
        XCTAssertFalse(reloaded.isEnabled(.sns))
    }

    func testStoreDoesNotOverwriteSharedSettingsWithLegacy() {
        let (shared, sharedName) = makeExtraDefaults()
        let (legacy, legacyName) = makeExtraDefaults()
        defer {
            shared.removePersistentDomain(forName: sharedName)
            legacy.removePersistentDomain(forName: legacyName)
        }
        shared.set(["industrial", "sns"], forKey: "dictionaryPacks.enabled.v2")
        legacy.set(["anime"], forKey: "dictionaryPacks.enabled.v2")
        let store = DictionaryPackStore(defaults: shared, legacyDefaults: legacy)
        XCTAssertTrue(store.isEnabled(.industrial))
        XCTAssertTrue(store.isEnabled(.sns))
        XCTAssertFalse(store.isEnabled(.anime))
    }

    func testStorePicksUpChangesWrittenThroughAnotherInstance() {
        let appSide = DictionaryPackStore(defaults: defaults)
        let keyboardSide = DictionaryPackStore(defaults: defaults)
        appSide.setEnabled(.anime, true)
        XCTAssertTrue(keyboardSide.isEnabled(.anime))
        appSide.setEnabled(.sns, false)
        XCTAssertFalse(keyboardSide.isEnabled(.sns))
    }

    // MARK: - v0.3.31: SNS の先頭固定

    private func makePinningLibrary() -> DictionaryPackLibrary {
        DictionaryPackLibrary { id in
            switch id {
            case .industrial: return DictionaryPackData.parse(Data("りぷ\tリプ用治具\nめんとり\t面取り\n".utf8))
            case .sns: return DictionaryPackData.parse(Data("りぷ\tリプ\nりぷ\tリプ欄\n".utf8))
            case .anime: return DictionaryPackData.parse(Data("りぷ\tリプ星人\n".utf8))
            default: return DictionaryPackData()
            }
        }
    }

    func testPinnedSurfacesAreSNSOnlyAndAppendedExcludeSNS() {
        let library = makePinningLibrary()
        let store = DictionaryPackStore(defaults: defaults)
        XCTAssertEqual(library.pinnedSurfaces(forKana: "りぷ", store: store), ["リプ", "リプ欄"])
        XCTAssertEqual(library.appendedSurfaces(forKana: "りぷ", store: store), ["リプ用治具"])
        store.setEnabled(.anime, true)
        XCTAssertEqual(library.appendedSurfaces(forKana: "りぷ", store: store), ["リプ用治具", "リプ星人"])
        store.setEnabled(.sns, false)
        XCTAssertEqual(library.pinnedSurfaces(forKana: "りぷ", store: store), [])
    }

    func testMergingPacksPinsSNSToHead() {
        // 本体候補に SNS 表記が混ざっていても先頭へ寄せ、他のパックは
        // 先頭候補の直後に入る。
        let merged = DictionaryPackLibrary.mergingPacks(
            into: ["変換A", "リプ", "変換B"],
            pinned: ["リプ", "リプ欄"],
            appended: ["面取り"])
        XCTAssertEqual(merged, ["リプ", "リプ欄", "変換A", "面取り", "変換B"])
    }

    func testMergingPacksPromotesAppendedBehindTopCandidate() {
        // 実例 (2026-11-18 実機報告): とよた の候補で会社名パックの
        // トヨタ自動車 が変換ノイズの後ろ (5番手) に埋もれた。
        // パック表記は先頭候補の直後 (2番手) に来ること。
        let merged = DictionaryPackLibrary.mergingPacks(
            into: ["預た", "toyota", "杜預他", "とよた"],
            pinned: [], appended: ["トヨタ自動車"])
        XCTAssertEqual(merged, ["預た", "トヨタ自動車", "toyota", "杜預他", "とよた"])
    }

    func testMergingPacksPullsUpExistingCandidate() {
        // パック表記が本体候補の下位にあっても差し込み位置へ引き上げる。
        let merged = DictionaryPackLibrary.mergingPacks(
            into: ["変換A", "変換B", "トヨタ自動車"], pinned: [], appended: ["トヨタ自動車"])
        XCTAssertEqual(merged, ["変換A", "トヨタ自動車", "変換B"])
    }

    func testMergingPacksAppendedWithEmptyCandidates() {
        let merged = DictionaryPackLibrary.mergingPacks(
            into: [], pinned: [], appended: ["面取り"])
        XCTAssertEqual(merged, ["面取り"])
    }

    // MARK: - 会社名パック (同梱 TSV の実データ検証)

    func testCompanyPackBundledData() throws {
        XCTAssertEqual(DictionaryPackID.company.displayName, "会社名")
        XCTAssertEqual(DictionaryPackID.company.resourceName, "dictionary_company")
        XCTAssertFalse(DictionaryPackID.company.defaultEnabled)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Keyboard/dictionary_company.tsv")
        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // 全行が 読み<TAB>表記 で、読みはひらがなのみ (英字読みはパターン扱いに
        // なるため、会社名パックでは混ぜない)。
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            XCTAssertEqual(parts.count, 2, "TSV 形式でない行: \(line)")
            XCTAssertTrue(parts[0].allSatisfy { !$0.isASCII }, "読みがひらがなでない: \(line)")
        }
        let pack = DictionaryPackData.parse(data)
        XCTAssertEqual(pack.surfaces(forKana: "とよた"), ["トヨタ自動車"])
        XCTAssertEqual(pack.surfaces(forKana: "そにー"), ["ソニーグループ"])
        XCTAssertEqual(pack.surfaces(forKana: "にっさん"), ["日産自動車"])
        // 日経225 全銘柄 + 主要な非上場・エクストラを収録する規模であること。
        XCTAssertGreaterThanOrEqual(text.split(separator: "\n").count, 250)
    }

    func testMergingPacksDedupesAppendedAgainstCandidates() {
        // 先頭候補と重なるパック表記はそのまま先頭に残り、残りのパック
        // 表記はその直後に入る (重複は作らない)。
        let merged = DictionaryPackLibrary.mergingPacks(
            into: ["面取り", "変換A"], pinned: [], appended: ["面取り", "ネジ"])
        XCTAssertEqual(merged, ["面取り", "ネジ", "変換A"])
    }
}
