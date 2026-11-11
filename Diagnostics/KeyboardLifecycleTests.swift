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
        let one = try key("1", controller), q = try key("q", controller), space = try key("スペース", controller)
        let enter = try key("改行", controller)
        XCTAssertEqual(one.bounds.width, q.bounds.width, accuracy: 0.5)
        XCTAssertEqual(one.bounds.height, 38, accuracy: 0.5)
        XCTAssertGreaterThan(space.bounds.width, one.bounds.width * 5)
        XCTAssertGreaterThan(enter.bounds.width, one.bounds.width * 2.5)
        let canvas = try XCTUnwrap(descendants(controller.view).first { $0 is KeyboardCanvas })
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { canvas.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = "NumberKey-reference-layout"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testJapaneseIsMarkedInHostAndCommitsWithoutDuplication() throws {
        let (controller, document) = keyboard()
        document.onWrite = { [weak controller] in controller?.textDidChange(nil) }
        for letter in ["k", "a", "n", "a"] { try key(letter, controller).sendActions(for: .touchUpInside) }
        controller.textDidChange(nil)
        XCTAssertEqual(document.text as String, "かな")
        XCTAssertNotNil(document.marked)
        try key("candidate.カナ", controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text as String, "カナ")
        XCTAssertNil(document.marked)
    }
    @MainActor
    func testDeletingCompositionPreservesExistingHostText() throws {
        let (controller, document) = keyboard()
        document.insertText("ABC")
        try key("k", controller).sendActions(for: .touchUpInside)
        try key("a", controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text as String, "ABCか")
        try key("削除", controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text as String, "ABC")
        XCTAssertNil(document.marked)
    }
    @MainActor
    func testExternalCursorChangeDoesNotOverwriteHostText() throws {
        let (controller, document) = keyboard()
        try key("k", controller).sendActions(for: .touchUpInside)
        try key("a", controller).sendActions(for: .touchUpInside)
        document.unmarkText()
        document.insertText("X")
        controller.textDidChange(nil)
        try key("s", controller).sendActions(for: .touchUpInside)
        try key("a", controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text as String, "かXさ")
    }
    @MainActor
    func testLayoutImportFromAppAndInvalidData() throws {
        let (controller, _) = keyboard()
        var layout = LayoutSettings.defaults
        layout.rows[0].swapAt(0, 1)
        XCTAssertTrue(controller.applyLayoutString(layout.exportString()))
        XCTAssertEqual(controller.settings.snapshot.rows[0][0], "2")
        XCTAssertFalse(controller.applyLayoutString("unrelated clipboard contents"))
        layout.rows[0] = ["1"]
        XCTAssertNil(LayoutSettings.decode(layout.exportString()))
    }
}
