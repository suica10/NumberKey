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
}
