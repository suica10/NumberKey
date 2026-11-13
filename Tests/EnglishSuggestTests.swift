import XCTest
@testable import PhraseStore

final class EnglishSuggestTests: XCTestCase {
    private let lexicon = EnglishLexicon(
        words: ["the", "thanks", "thank", "this", "that", "receive", "keyboard", "apple",
                "apply", "app", "hello", "world", "cat", "address", "occurred", "you"],
        frequencies: [222, 122, 130, 200, 210, 137, 118, 150, 140, 160, 170, 165, 90, 145, 100, 180])

    func testCompletionsAreFrequencyOrderedAndExcludeExactWord() {
        XCTAssertEqual(lexicon.completions(for: "th", limit: 3), ["the", "that", "this"])
        XCTAssertEqual(lexicon.completions(for: "app", limit: 3), ["apple", "apply"])
        XCTAssertTrue(lexicon.completions(for: "zzz", limit: 3).isEmpty)
    }

    func testCorrectionsCoverTranspositionDeletionInsertion() {
        XCTAssertEqual(lexicon.corrections(for: "teh", limit: 1), ["the"])
        XCTAssertEqual(lexicon.corrections(for: "adress", limit: 1), ["address"])
        XCTAssertEqual(lexicon.corrections(for: "recieve", limit: 1), ["receive"])
    }

    func testSuggestionsLeadWithTypedWord() {
        let valid = lexicon.suggestions(for: "app")
        XCTAssertEqual(valid.first, "app")
        XCTAssertTrue(valid.contains("apple"))
        let invalid = lexicon.suggestions(for: "teh")
        XCTAssertEqual(invalid.first, "teh")
        XCTAssertTrue(invalid.contains("the"))
        XCTAssertTrue(lexicon.suggestions(for: "a").isEmpty)
    }

    func testAutocorrectOnlyWhenConfident() {
        XCTAssertEqual(lexicon.autocorrect(for: "teh"), "the")
        XCTAssertEqual(lexicon.autocorrect(for: "adress"), "address")
        XCTAssertNil(lexicon.autocorrect(for: "the"))      // 辞書にある語は直さない
        XCTAssertNil(lexicon.autocorrect(for: "zqxj"))     // 近い候補が無ければ直さない
        XCTAssertNil(lexicon.autocorrect(for: "ap"))       // 短すぎる語は直さない
    }

    func testBundledWordlistParses() {
        let data = Data("apple\t150\nbanana\t120\n".utf8)
        let parsed = EnglishLexicon(data: data)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed!.contains("banana"))
        XCTAssertEqual(parsed!.frequency(of: "apple"), 150)
    }
}
