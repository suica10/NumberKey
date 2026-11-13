import Foundation

// 定型文の登録中に、入力の宛先を実ドキュメントから差し替えるための KeyboardDocument。
//
// KeyboardViewController.documentOverride にこれを差すだけで、既存の変換エンジン
// （ローマ字入力→候補選択→確定）がそのままバッファへ書き込むようになる。
// 保存時は finalText を PhraseStore へ渡し、キャンセル時は丸ごと捨てる。

@MainActor
final class BufferDocument: KeyboardDocument {
    private(set) var buffer = TextBuffer()
    /// 表示更新（候補ストリップのラベル）用。displayText が変わるたびに呼ばれる。
    var onChange: ((String) -> Void)?

    var text: String { buffer.finalText() }

    // KeyboardDocument は before/after を「ホスト側の変化検出」に使う。
    // バッファはセッション経由でしか変化しないので、expected と常に一致する。
    var before: String? { buffer.displayText }
    var after: String? { "" }

    func setMarkedText(_ text: String, selectedRange: NSRange) {
        buffer.setMarked(text)
        onChange?(buffer.displayText)
    }

    func unmarkText() {
        buffer.unmark()
        onChange?(buffer.displayText)
    }

    func insertText(_ text: String) {
        buffer.insert(text)
        onChange?(buffer.displayText)
    }

    func deleteBackward() {
        buffer.deleteBackward()
        onChange?(buffer.displayText)
    }

    /// バッファ内のカーソル移動は未対応（登録中の編集は末尾への追記と削除のみ）。
    func move(_ offset: Int) {}
}
