import UIKit

@MainActor
protocol KeyboardDocument: AnyObject {
    var before: String? { get }
    var after: String? { get }
    func setMarkedText(_ text: String, selectedRange: NSRange)
    func unmarkText()
    func insertText(_ text: String)
    func deleteBackward()
    func move(_ offset: Int)
}

@MainActor
final class ProxyDocument: KeyboardDocument {
    let proxy: UITextDocumentProxy
    init(_ proxy: UITextDocumentProxy) { self.proxy = proxy }
    var before: String? { proxy.documentContextBeforeInput }
    var after: String? { proxy.documentContextAfterInput }
    func setMarkedText(_ text: String, selectedRange: NSRange) { proxy.setMarkedText(text, selectedRange: selectedRange) }
    func unmarkText() { proxy.unmarkText() }
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
    func move(_ offset: Int) { proxy.adjustTextPosition(byCharacterOffset: offset) }
}

@MainActor
final class MarkedTextSession {
    private struct Context: Equatable { var before: String?; var after: String? }
    private let getDocument: () -> KeyboardDocument
    private var expected: Context?
    private var renderedText = ""
    private var renderedCaret = 0
    private(set) var hasMarkedText = false
    private(set) var isUpdating = false
    init(document: @escaping () -> KeyboardDocument) { getDocument = document }
    private func context(_ d: KeyboardDocument) -> Context { Context(before: d.before, after: d.after) }
    /// proxy の変更後に documentContextBeforeInput / AfterInput を読み直すのは
    /// ホストアプリとの往復になるため、キーボード拡張では目に見えて高くつく。
    /// スナップショットは「マーク付きテキストが生きていて、後の hostDidChange /
    /// finish が expected を参照する」場合にだけ必要なので、それ以外では読まない。
    /// snapshot を nil にすると「変更前の hasMarkedText」から自動判定する。
    private func update(snapshot: Bool? = nil, _ body: (KeyboardDocument) -> Void) {
        let shouldSnapshot = snapshot ?? hasMarkedText
        isUpdating = true
        let document = getDocument()
        body(document)
        if shouldSnapshot { expected = context(document) }
        isUpdating = false
    }
    func show(_ text: String, caret: Int) {
        if text.isEmpty {
            if hasMarkedText { update(snapshot: false) { $0.setMarkedText("", selectedRange: NSRange(location: 0, length: 0)); $0.unmarkText() } }
            forget()
            return
        }
        let position = min(max(0, caret), text.utf16.count)
        guard !hasMarkedText || text != renderedText || position != renderedCaret else { return }
        hasMarkedText = true; renderedText = text; renderedCaret = position
        update { $0.setMarkedText(text, selectedRange: NSRange(location: position, length: 0)) }
    }
    func commit(_ text: String) {
        let replace = hasMarkedText
        // 直後に forget() で expected を捨てるため、スナップショットは不要。
        update(snapshot: false) {
            if replace { $0.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0)); $0.unmarkText() }
            else { $0.insertText(text) }
        }
        forget()
    }
    func finish() {
        if hasMarkedText && expected == context(getDocument()) { update(snapshot: false) { $0.unmarkText() } }
        forget()
    }
    func insert(_ text: String) { update { $0.insertText(text) } }
    func deleteBackward() { update { $0.deleteBackward() } }
    func move(_ offset: Int) { update { $0.move(offset) } }
    func hostDidChange() -> Bool {
        guard hasMarkedText, !isUpdating, expected != context(getDocument()) else { return false }
        // Commit any surviving host mark without replacing text at the new selection.
        update { $0.unmarkText() }
        forget()
        return true
    }
    func forget() { hasMarkedText = false; renderedText = ""; renderedCaret = 0; expected = nil }
}
