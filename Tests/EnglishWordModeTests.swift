import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import PhraseStore

/// 打鍵列レベルの検証: VC の insert() の日本語ローマ字経路を模したハーネスで
/// キーを流し、組成 (convertTarget) と英単語モードの遷移を照合する。
/// 実機でしか分からなかった「Shift開始で続けて打つと化ける」類を CI で潰す。
final class EnglishWordModeTests: XCTestCase {
    // 補助セットの "ok" / "pdf" は辞書に無くても既知語になる。
    private let lexicon = EnglishLexicon(
        words: ["hello", "sake", "the", "world"],
        frequencies: [30, 10, 40, 20])

    /// VC の打鍵処理のうち、日本語モードのローマ字キーに関する部分の模倣。
    /// Shift のトグルとワンショット解除も VC と同じ規則にしている。
    private struct Harness {
        var composition = ComposingText()
        var tracker = EnglishWordMode()
        var shifted = false
        var capsLocked = false
        let lexicon: EnglishLexicon

        mutating func tapShift() {
            shifted.toggle()
            capsLocked = false
        }

        mutating func type(_ text: String) {
            switch tracker.handleKey(text, shifted: shifted, capsLocked: capsLocked,
                                     compositionIsEmpty: composition.isEmpty,
                                     currentRaw: rawRomaji(), lexicon: lexicon) {
            case .insertDirect(let typed):
                composition.insertAtCursorPosition(typed, inputStyle: .direct)
            case .passThrough:
                composition.insertAtCursorPosition(text.lowercased(), inputStyle: .roman2kana)
            }
            if shifted && !capsLocked { shifted = false }
        }

        func rawRomaji() -> String {
            var result = ""
            for element in composition.input {
                switch element.piece {
                case .character(let character): result.append(character)
                case .key(_, let input, _): result.append(input)
                case .compositionSeparator: break
                }
            }
            return result
        }
    }

    private func makeHarness() -> Harness { Harness(lexicon: lexicon) }

    /// B案の本命: Shift+O、Shift+K と大文字で打ち始め、そのまま だった を
    /// 続けると「OKだった」が一息で組成できる (2026-11-18 の実機報告の再現)。
    func testShiftBothLettersThenJapaneseContinues() {
        var h = makeHarness()
        h.tapShift(); h.type("o")
        h.tapShift(); h.type("k")
        XCTAssertTrue(h.tracker.isActive)
        XCTAssertEqual(h.composition.convertTarget, "OK")
        for ch in ["d", "a", "t", "t", "a"] { h.type(ch) }
        XCTAssertEqual(h.composition.convertTarget, "OKだった")
        XCTAssertFalse(h.tracker.isActive)
    }

    /// 先頭だけ Shift の場合は「Okだった」になる (閉じ判定は ok で効く)。
    func testOneShotShiftFirstLetterOnly() {
        var h = makeHarness()
        h.tapShift(); h.type("o")
        h.type("k")
        XCTAssertTrue(h.tracker.isActive)
        for ch in ["d", "a", "t", "t", "a"] { h.type(ch) }
        XCTAssertEqual(h.composition.convertTarget, "Okだった")
        XCTAssertFalse(h.tracker.isActive)
    }

    /// Caps 中の大文字略語は、続きの無い綴りなら次の小文字打鍵で閉じる。
    func testCapsLockAbbreviationCloses() {
        var h = makeHarness()
        h.capsLocked = true
        for ch in ["x", "y", "z"] { h.type(ch) }
        XCTAssertEqual(h.composition.convertTarget, "XYZ")
        h.capsLocked = false
        h.type("d")
        XCTAssertFalse(h.tracker.isActive)
        h.type("a")
        XCTAssertEqual(h.composition.convertTarget, "XYZだ")
    }

    /// 小文字で一息に打つ流れは英単語モードに入らない (A案の候補昇格で拾う
    /// 領域)。現行挙動の記録: 組成は「おkだった」になる。
    func testLowercaseStreamNeverEntersMode() {
        var h = makeHarness()
        for ch in ["o", "k", "d", "a", "t", "t", "a"] { h.type(ch) }
        XCTAssertFalse(h.tracker.isActive)
        XCTAssertEqual(h.composition.convertTarget, "おkだった")
    }

    /// A案: 「ok」は読みに未変換ローマ字が残るので英字候補が先頭に来る。
    func testLowercaseOkExtrasPromotedToFront() {
        let (merged, extras) = lexicon.insertingExtras(
            into: ["御k", "おk", "尾k"], raw: "ok", kana: "おk")
        XCTAssertEqual(extras, ["ok", "Ok", "OK"])
        XCTAssertEqual(merged, ["ok", "Ok", "OK", "御k", "おk", "尾k"])
    }

    /// 完全にかな変換できる英単語 (sake→さけ) は先頭を奪わない (2番手)。
    func testFullyConvertibleWordNotHijacked() {
        let (merged, extras) = lexicon.insertingExtras(
            into: ["酒", "さけ", "佐久"], raw: "sake", kana: "さけ")
        XCTAssertEqual(extras, ["sake", "Sake"])
        XCTAssertEqual(merged, ["酒", "sake", "Sake", "さけ", "佐久"])
    }

    /// 分割候補: 小文字で一息に打った「okdatta」でも OKだった に到達できる。
    func testSegmentedExtrasForOkDatta() {
        let extras = lexicon.segmentedExtras(raw: "okdatta", kana: "おkだった", tailKana: kanaOf)
        XCTAssertEqual(extras, ["okだった", "Okだった", "OKだった"])
    }

    func testSegmentedExtrasForPdfMiru() {
        let extras = lexicon.segmentedExtras(raw: "pdfmiru", kana: "pdfみる", tailKana: kanaOf)
        XCTAssertEqual(extras, ["pdfみる", "Pdfみる", "PDFみる"])
    }

    /// 完全にかな変換できる日本語では分割候補は出ない (日本語変換を奪わない)。
    func testSegmentedExtrasBlockedWhenConversionIsClean() {
        XCTAssertEqual(lexicon.segmentedExtras(raw: "ashita", kana: "あした", tailKana: kanaOf), [])
        XCTAssertEqual(lexicon.segmentedExtras(raw: "okashi", kana: "おかし", tailKana: kanaOf), [])
    }

    /// ハーネスで実際に打った組成からでも分割候補が組み立てられる。
    func testLowercaseStreamSegmentedExtrasReachOkDatta() {
        var h = makeHarness()
        for ch in ["o", "k", "d", "a", "t", "t", "a"] { h.type(ch) }
        let extras = lexicon.segmentedExtras(
            raw: h.rawRomaji(), kana: h.composition.convertTarget, tailKana: kanaOf)
        XCTAssertTrue(extras.contains("OKだった"), "extras: \(extras)")
    }

    private func kanaOf(_ romaji: String) -> String? {
        var c = ComposingText()
        c.insertAtCursorPosition(romaji, inputStyle: .roman2kana)
        return c.convertTarget
    }

    /// モードは Shift/Caps + 組成が空のときだけ始まる。
    func testModeRequiresShiftAndEmptyComposition() {
        var tracker = EnglishWordMode()
        XCTAssertEqual(
            tracker.handleKey("o", shifted: false, capsLocked: false,
                              compositionIsEmpty: true, currentRaw: "", lexicon: lexicon),
            .passThrough)
        XCTAssertFalse(tracker.isActive)
        XCTAssertEqual(
            tracker.handleKey("o", shifted: true, capsLocked: false,
                              compositionIsEmpty: false, currentRaw: "か", lexicon: lexicon),
            .passThrough)
        XCTAssertFalse(tracker.isActive)
    }

    /// 組成が空のまま打鍵が来たらモードは解除されて通常入力に戻る。
    func testEmptyCompositionDeactivatesMode() {
        var tracker = EnglishWordMode()
        XCTAssertEqual(
            tracker.handleKey("o", shifted: true, capsLocked: false,
                              compositionIsEmpty: true, currentRaw: "", lexicon: lexicon),
            .insertDirect("O"))
        XCTAssertTrue(tracker.isActive)
        XCTAssertEqual(
            tracker.handleKey("k", shifted: false, capsLocked: false,
                              compositionIsEmpty: true, currentRaw: "", lexicon: lexicon),
            .passThrough)
        XCTAssertFalse(tracker.isActive)
    }
}
