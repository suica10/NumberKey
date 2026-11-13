import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion

final class ConversionTests: XCTestCase {
    func testRomanInputAndDeletion() {
        var c = ComposingText()
        c.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        XCTAssertEqual(c.convertTarget, "にほんご")
        c.deleteBackwardFromCursorPosition(count: 1)
        XCTAssertEqual(c.convertTarget, "にほん")
    }

    func testSmallTsuAndContractedSounds() {
        var c = ComposingText()
        c.insertAtCursorPosition("gakkou", inputStyle: .roman2kana)
        XCTAssertEqual(c.convertTarget, "がっこう")
        c = ComposingText()
        c.insertAtCursorPosition("kyou", inputStyle: .roman2kana)
        XCTAssertEqual(c.convertTarget, "きょう")
    }

    func testJapaneseDictionaryAndEmptyInput() async {
        let service = ConversionService()
        var c = ComposingText()
        c.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        let results = await service.candidates(for: c, generation: 1) ?? []
        XCTAssertTrue(results.contains("日本語"), "Dictionary was not bundled or the converter API changed: \(results)")
        XCTAssertEqual(Set(results).count, results.count)
        let empty = await service.candidates(for: ComposingText(), generation: 2)
        XCTAssertTrue(empty?.isEmpty == true)
    }

    func testConsecutiveRequests() async {
        let service = ConversionService()
        var first = ComposingText()
        first.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        _ = await service.candidates(for: first, generation: 1)
        var second = ComposingText()
        second.insertAtCursorPosition("toukyou", inputStyle: .roman2kana)
        let results = await service.candidates(for: second, generation: 2) ?? []
        XCTAssertTrue(results.contains("東京"), "Unexpected results after changing composition: \(results)")
    }

    func testStaleGenerationIsSkipped() async {
        let service = ConversionService()
        var c = ComposingText()
        c.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        _ = await service.candidates(for: c, generation: 5)
        // 世代が古いリクエストは変換自体を省いて nil を返す。
        let stale = await service.candidates(for: c, generation: 3)
        XCTAssertNil(stale)
    }
}
