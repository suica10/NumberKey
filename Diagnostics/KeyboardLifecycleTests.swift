import XCTest
import UIKit

@MainActor
final class MockDocument: KeyboardDocument {
    var text = NSMutableString(string: "")
    var cursor = 0
    var marked: NSRange?
    var onWrite: (() -> Void)?
    var before: String? { text.substring(to: cursor) }
    var after: String? { text.substring(from: cursor) }
    func setMarkedText(_ value: String, selectedRange: NSRange) {
        let range = marked ?? NSRange(location: cursor, length: 0)
        text.replaceCharacters(in: range, with: value)
        marked = NSRange(location: range.location, length: value.utf16.count)
        cursor = range.location + selectedRange.location
        onWrite?()
    }
    func unmarkText() { marked = nil; onWrite?() }
    func insertText(_ value: String) {
        let range = marked ?? NSRange(location: cursor, length: 0)
        text.replaceCharacters(in: range, with: value)
        cursor = range.location + value.utf16.count; marked = nil
        onWrite?()
    }
    func deleteBackward() {
        guard cursor > 0 else { return }
        let range = text.rangeOfComposedCharacterSequence(at: cursor - 1)
        text.deleteCharacters(in: range); cursor = range.location; marked = nil
        onWrite?()
    }
    func move(_ offset: Int) { cursor = min(text.length, max(0, cursor + offset)); onWrite?() }
}

final class KeyboardLifecycleTests: XCTestCase {
    @MainActor
    private func keyboard() -> (KeyboardViewController, MockDocument) {
        let controller = KeyboardViewController()
        let document = MockDocument()
        let defaults = UserDefaults(suiteName: "layout-tests-" + UUID().uuidString)!
        controller.settings = KeyboardSettings(defaults: defaults)
        controller.documentOverride = document
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 300)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        return (controller, document)
    }
    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor
    private func key(_ id: String, _ controller: KeyboardViewController) throws -> UIButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id || $0.accessibilityLabel == id })
    }
    /// 文字キーは touchDown で確定する設計 (KeyboardCanvas)。touchUpInside を
    /// 送っても発火しないので、文字キーのタップは touchDown で送る。
    /// 候補選択や削除キーは従来どおり touchUpInside。
    @MainActor
    private func tapCharacter(_ id: String, _ controller: KeyboardViewController) throws {
        try key(id, controller).sendActions(for: .touchDown)
    }
    /// 変換候補のように非同期で現れるキーを待つ。変換はデバウンス+actor の
    /// 非同期処理なので、テスト側で主ランループを回して完了を待つ必要がある。
    @MainActor
    private func waitForKey(_ id: String, _ controller: KeyboardViewController, timeout: TimeInterval = 10) throws -> UIButton {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = descendants(controller.view).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == id || $0.accessibilityLabel == id }) {
                return found
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return try key(id, controller)
    }
    @MainActor
    func testControllerLoadsAndSurvivesRepeatedPresentation() throws {
        let (controller, _) = keyboard()
        for _ in 0..<3 {
            controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
            controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
        }
        XCTAssertNotNil(try key("次のキーボード", controller))
        XCTAssertEqual(descendants(controller.view).filter { $0.accessibilityIdentifier == "q" }.count, 1)
        let strings = descendants(controller.view).compactMap { ($0 as? UILabel)?.text }
        XCTAssertFalse(strings.contains { $0.contains("スペースで") || $0.contains("ローマ字入力") || $0.contains("キーボード設定") })
    }
    @MainActor
    func testReferenceGeometryAndScreenshot() throws {
        let (controller, _) = keyboard()
        let one = try key("1", controller), q = try key("q", controller), space = try key("日本語入力", controller)
        let enter = try key("改行", controller)
        XCTAssertEqual(one.bounds.width, q.bounds.width, accuracy: 0.5)
        XCTAssertEqual(one.bounds.height, 38, accuracy: 0.5)
        // 本体行は純正キーボード準拠: 402pt 幅でキー高 43pt / 行ピッチ 54pt。
        // 数字行は純正に無い補助行として従来の 38pt を保つ (上の検証)。
        XCTAssertEqual(q.bounds.height, 43, accuracy: 0.5)
        let a = try key("a", controller)
        XCTAssertEqual(a.frame.minY - q.frame.minY, 54, accuracy: 0.5)
        // 着せ替えパレット (KeyboardAppearance) が SRGB で色を持つため、期待値も SRGB で表す。
        // 値そのものは従来どおり (白 / 0.38 グレー)。
        XCTAssertEqual(one.titleColor(for: .normal), UIColor(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(one.backgroundColor, UIColor(red: 0.38, green: 0.38, blue: 0.38, alpha: 1))
        XCTAssertGreaterThan(space.bounds.width, one.bounds.width * 4)
        // 改行キーの幅は下段の重み [120,110,100,460,100,242] から決まり、
        // 単位キーの約2.31倍が現行レイアウトの設計値。旧基準の2.5倍は
        // 重み調整前の期待値だったため、設計値に合わせて 2.2 倍で担保する。
        XCTAssertGreaterThan(enter.bounds.width, one.bounds.width * 2.2)
        let canvas = try XCTUnwrap(descendants(controller.view).first { $0 is KeyboardCanvas })
        // 候補バー常時表示 (34pt) のため、キャンバスは 34pt 下から始まるのが現行の設計値。
        XCTAssertEqual(canvas.frame.minY, 34, accuracy: 0.5)
        canvas.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { canvas.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = "NumberKey-reference-layout"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testJapaneseIsMarkedInHostAndCommitsWithoutDuplication() throws {
        let (controller, document) = keyboard()
        document.onWrite = { [weak controller] in controller?.textDidChange(nil) }
        for letter in ["k", "a", "n", "a"] { try tapCharacter(letter, controller) }
        controller.textDidChange(nil)
        XCTAssertEqual(document.text as String, "かな")
        XCTAssertNotNil(document.marked)
        // CI シミュレータでは初回変換の辞書ロード (LOUDS の mmap/ページイン)
        // が数十秒かかることがあるため、候補待ちは長めに取る。本番は
        // キーボード表示時に warmUp 済みで、この遅延はテスト環境固有。
        try waitForKey("candidate.カナ", controller, timeout: 90).sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text as String, "カナ")
        XCTAssertNil(document.marked)
    }
    @MainActor
    func testDeletingCompositionPreservesExistingHostText() throws {
        let (controller, document) = keyboard()
        document.insertText("ABC")
        try tapCharacter("k", controller)
        try tapCharacter("a", controller)
        XCTAssertEqual(document.text as String, "ABCか")
        try key("削除", controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text as String, "ABC")
        XCTAssertNil(document.marked)
    }
    @MainActor
    func testExternalCursorChangeDoesNotOverwriteHostText() throws {
        let (controller, document) = keyboard()
        try tapCharacter("k", controller)
        try tapCharacter("a", controller)
        document.unmarkText()
        document.insertText("X")
        controller.textDidChange(nil)
        try tapCharacter("s", controller)
        try tapCharacter("a", controller)
        XCTAssertEqual(document.text as String, "かXさ")
    }
}
