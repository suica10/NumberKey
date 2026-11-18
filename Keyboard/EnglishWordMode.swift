import Foundation

/// B案 (英単語モード) の状態遷移だけを切り出した部品。UIKit も ComposingText も
/// 知らないので、打鍵列レベルの検証を SwiftPM テストで回せる
/// (Tests/EnglishWordModeTests)。
///
/// 使い方: 日本語モードのローマ字打鍵ごとに handleKey を呼ぶ。
/// .insertDirect が返ればその文字列を .direct で組成へ入れ、
/// .passThrough なら通常のローマ字入力として処理する (その際、モード解除の
/// 副作用だけが済んでいる)。
struct EnglishWordMode {
    private(set) var isActive = false

    enum Decision: Equatable {
        case insertDirect(String)
        case passThrough
    }

    mutating func reset() { isActive = false }

    /// 英単語を閉じるべきか。現在の綴りが英単語として成立しているか、
    /// 大文字だけの略語で辞書の接頭辞として続きが無い場合に閉じる。
    func shouldClose(currentRaw: String, lexicon: EnglishLexicon?) -> Bool {
        guard currentRaw.count >= 2, let lexicon else { return false }
        if lexicon.isKnownWord(currentRaw.lowercased()) { return true }
        if currentRaw == currentRaw.uppercased(),
           lexicon.completions(for: currentRaw.lowercased(), limit: 1).isEmpty {
            return true
        }
        return false
    }

    /// - Parameters:
    ///   - compositionIsEmpty: この打鍵を受ける直前の組成が空か。
    ///   - currentRaw: 組成から復元した生のローマ字入力 (この打鍵を含まない)。
    mutating func handleKey(_ text: String, shifted: Bool, capsLocked: Bool,
                            compositionIsEmpty: Bool, currentRaw: String,
                            lexicon: EnglishLexicon?) -> Decision {
        if isActive {
            // 組成が空になっていたらモードは終わっている (削除し切り等は
            // 呼び出し側でも解除するが、ここでも安全に倒す)。
            guard !compositionIsEmpty else { isActive = false; return .passThrough }
            // 単語の区切り: Shift も Caps も無い打鍵で、ここまでの綴りが英単語
            // として成立している (または続きの無い大文字略語である) 場合は
            // 英単語を閉じ、この打鍵から日本語に戻す (「OKだった」の流れ)。
            if !shifted && !capsLocked
                && shouldClose(currentRaw: currentRaw, lexicon: lexicon) {
                isActive = false
                return .passThrough
            }
            return .insertDirect(shifted || capsLocked ? text.uppercased() : text)
        }
        // 開始条件: 組成が空で、Shift (または Caps) を伴う英字。
        guard compositionIsEmpty, shifted || capsLocked else { return .passThrough }
        isActive = true
        return .insertDirect(text.uppercased())
    }
}
