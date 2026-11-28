import XCTest
@testable import PhraseStore

final class PasteTextTests: XCTestCase {
    // MARK: - sanitized

    func testSanitizedNormalizesLineEndings() {
        XCTAssertEqual(PasteText.sanitized("a\r\nb\rc\nd"), "a\nb\nc\nd")
    }

    func testSanitizedDropsControlCharactersExceptNewline() {
        XCTAssertEqual(PasteText.sanitized("a\u{0}b\u{7}c\nd\u{1B}"), "abc\nd")
        // タブも制御文字として落とす（従来の pasteIntoCapture と同じ規則）。
        XCTAssertEqual(PasteText.sanitized("a\tb"), "ab")
    }

    func testSanitizedKeepsOrdinaryText() {
        XCTAssertEqual(PasteText.sanitized("こんにちは、世界！"), "こんにちは、世界！")
        XCTAssertEqual(PasteText.sanitized("https://example.com/path?q=1"), "https://example.com/path?q=1")
        XCTAssertEqual(PasteText.sanitized(""), "")
    }

    // MARK: - preview

    func testPreviewFoldsNewlinesAndTrims() {
        XCTAssertEqual(PasteText.preview("  abc\ndef  "), "abc def")
        XCTAssertEqual(PasteText.preview("1行目\n2行目です"), "1行目 2行目です")
    }

    func testPreviewTruncatesLongText() {
        XCTAssertEqual(PasteText.preview("123456789012"), "123456789012")
        XCTAssertEqual(PasteText.preview("1234567890123"), "123456789012…")
        XCTAssertEqual(PasteText.preview("あいうえおかきくけこさしす"), "あいうえおかきくけこさし…")
    }

    func testPreviewRespectsMaxLength() {
        XCTAssertEqual(PasteText.preview("abcdef", maxLength: 3), "abc…")
        XCTAssertEqual(PasteText.preview("abc", maxLength: 3), "abc")
    }
}
