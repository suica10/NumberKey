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

    func testEnglishCandidatesForRomajiInput() {
        XCTAssertEqual(lexicon.englishCandidates(forRomaji: "apple"), ["apple", "Apple"])
        XCTAssertEqual(lexicon.englishCandidates(forRomaji: "fusion"), ["fusion"])
        XCTAssertEqual(lexicon.englishCandidates(forRomaji: "a"), [])
        XCTAssertEqual(lexicon.englishCandidates(forRomaji: "あい"), [])
    }

    func testSupplementaryWordsCountAsKnown() {
        XCTAssertTrue(lexicon.isKnownWord("ok"))       // 補助セット
        XCTAssertTrue(lexicon.isKnownWord("apple"))    // 本体辞書 (テスト用)
        XCTAssertFalse(lexicon.isKnownWord("fusion"))
        XCTAssertEqual(lexicon.englishCandidates(forRomaji: "ok"), ["ok", "Ok", "OK"])
    }

    func testPromoteEnglishCandidateOnlyWithUnconvertedRomaji() {
        // 未変換のローマ字が残り、英単語として成立する綴りは先頭に出す
        XCTAssertTrue(lexicon.shouldPromoteEnglishCandidate(raw: "ok", kana: "おk"))
        XCTAssertTrue(lexicon.shouldPromoteEnglishCandidate(raw: "pdf", kana: "pdf"))
        XCTAssertTrue(lexicon.shouldPromoteEnglishCandidate(raw: "usb", kana: "うsb"))
        // 完全にかな変換できる綴りは日本語変換を奪わない
        XCTAssertFalse(lexicon.shouldPromoteEnglishCandidate(raw: "sake", kana: "さけ"))
        // 末尾 n の保留 (かん等) は日本語側
        XCTAssertFalse(lexicon.shouldPromoteEnglishCandidate(raw: "kan", kana: "かn"))
        // 未変換が残っても、英単語でなくローマ字として成立しうる綴りは対象外
        XCTAssertFalse(lexicon.shouldPromoteEnglishCandidate(raw: "dat", kana: "だt"))
        // ローマ字として成立し得ない綴り (母音なし) は英字とみなす
        XCTAssertTrue(lexicon.shouldPromoteEnglishCandidate(raw: "mrk", kana: "mrk"))
    }

    func testBundledWordlistParses() {
        let data = Data("apple\t150\nbanana\t120\n".utf8)
        let parsed = EnglishLexicon(data: data)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed!.contains("banana"))
        XCTAssertEqual(parsed!.frequency(of: "apple"), 150)
    }
}
