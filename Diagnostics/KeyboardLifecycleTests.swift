import XCTest
import UIKit

final class KeyboardLifecycleTests: XCTestCase {
    @MainActor
    func testControllerLoadsAndSurvivesRepeatedPresentation() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 350)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(buttons(in: controller.view).contains { $0.accessibilityLabel == "次のキーボード" })
        XCTAssertTrue(buttons(in: controller.view).contains { $0.accessibilityIdentifier == "1" })
        for _ in 0..<3 {
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }
        let keys = buttons(in: controller.view)
        XCTAssertEqual(keys.filter { $0.accessibilityIdentifier == "q" }.count, 1)
        XCTAssertEqual(keys.filter { $0.accessibilityIdentifier == "1" }.count, 1)
    }

    @MainActor
    func testSettingsAndKeyboardCanBeRebuilt() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        for _ in 0..<3 {
            let gear = try XCTUnwrap(buttons(in: controller.view).first { $0.accessibilityLabel == "キーボード設定" })
            gear.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            let done = try XCTUnwrap(buttons(in: controller.view).first { $0.accessibilityLabel == "完了" })
            done.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
        }
        XCTAssertEqual(buttons(in: controller.view).filter { $0.accessibilityIdentifier == "q" }.count, 1)
    }

    @MainActor
    private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}
