import Foundation

// 定型文の登録中に、入力の宛先を実ドキュメントから差し替えるための KeyboardDocument。
//
// KeyboardViewController.documentOverride にこれを差すだけで、既存の変換エンジン
// （ローマ字入力→候補選択→確定）がそのままバッファへ書き込むようになる。
// 保存時は finalText を PhraseStore へ渡し、キャンセル時は丸ごと捨てる。

@MainActor
final class BufferDocument: KeyboardDocument {
    private(set) var buffer = TextBuffer()
    /// 表示更新用。displayText と表示カーソル位置（文字オフセット）が変わるたびに呼ばれる。
    var onChange: ((String, Int) -> Void)?

    var text: String { buffer.finalText() }

    // KeyboardDocument は before/after を「ホスト側の変化検出」に使う。
    // バッファはセッション経由でしか変化しないので、expected と常に一致する。
    var before: String? { buffer.displayText }
    var after: String? { "" }

    private func notify() {
        onChange?(buffer.displayText, buffer.displayCursorOffset)
    }

    /// 既存の定型文を編集するために、初期テキストを読み込む。
    func loadInitialText(_ text: String) {
        buffer.load(text)
        notify()
    }

    func setMarkedText(_ text: String, selectedRange: NSRange) {
        buffer.setMarked(text)
        notify()
    }

    func unmarkText() {
        buffer.unmark()
        notify()
    }

    func insertText(_ text: String) {
        buffer.insert(text)
        notify()
    }

    func deleteBackward() {
        buffer.deleteBackward()
        notify()
    }

    /// バッファ内のカーソル移動。TextBuffer が確定済みテキスト内の位置を持つので、
    /// 登録・編集中も既存のカーソル移動メニューがそのまま効く。
    func move(_ offset: Int) {
        buffer.moveCursor(offset)
        notify()
    }
}
