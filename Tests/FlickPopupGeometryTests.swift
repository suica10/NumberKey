import XCTest
@testable import PhraseStore

/// フリック十字ポップアップの配置計算の単体テスト。
/// 2026-11-27 の配置前提 (ユーザー指示): 高さはグリッドちょうどで余白を
/// 確保しない。最上段のポップアップはキャンバスの上端を越えて候補バー
/// 側へ被さり (ホスト座標で原点がキャンバス上端より上に出る)、最下段の
/// わ・、 は下セルを持たない。座標はホスト (候補バー＋キャンバスを跨ぐ
/// ルートビュー) 基準で扱う。
/// 代表寸法: セル 72×50、行高 50・段間 6 → グリッド高 218。
/// キャンバスはホスト内の y=64 (候補バー 34 + 予測帯 30) から始まり、
/// ホスト高さは 64 + 218 = 282。
final class FlickPopupGeometryTests: XCTestCase {
    private let cell = CGSize(width: 72, height: 50)
    private let canvasTop: CGFloat = 64
    private var host: CGSize {
        CGSize(width: 390, height: canvasTop + FlickPopupGeometry.preferredHeight(rowHeight: 50, rowGap: 6))
    }

    private func origin(keyFrame: CGRect, omitDown: Bool = false) -> CGPoint {
        FlickPopupGeometry.popupOrigin(keyFrame: keyFrame, hostSize: host, cellSize: cell, omitDown: omitDown)
    }

    // MARK: - 高さとセル集合

    func testPreferredHeightIsGridOnly() {
        // 4段 + 段間3つ。上下の余白は含まない。
        XCTAssertEqual(FlickPopupGeometry.preferredHeight(rowHeight: 50, rowGap: 6), 218, accuracy: 0.001)
    }

    func testPopupSizeFullAndOmitDown() {
        XCTAssertEqual(FlickPopupGeometry.popupSize(cellSize: cell, omitDown: false),
                       CGSize(width: 216, height: 150))
        // 下セルが無い分だけ低い (セル 2 つ分)。
        XCTAssertEqual(FlickPopupGeometry.popupSize(cellSize: cell, omitDown: true),
                       CGSize(width: 216, height: 100))
    }

    func testDisplayedDirectionsOmitDownForBottomRowKeys() {
        XCTAssertEqual(FlickPopupGeometry.displayedDirections(omitDown: false),
                       [.center, .left, .up, .right, .down])
        let bottom = FlickPopupGeometry.displayedDirections(omitDown: true)
        XCTAssertEqual(bottom, [.center, .left, .up, .right])
        XCTAssertFalse(bottom.contains(.down))
    }

    // MARK: - 原点 (ホスト座標)

    func testTopRowPopupExtendsAboveCanvasOverCandidates() {
        // 最上段キー (キャンバス内 y=0 → ホスト y=64)。原点はキャンバス
        // 上端より 1 セル分上 (候補バー側) へ出て、中心セルがキーに重なる。
        let key = CGRect(x: 90, y: canvasTop, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.y, canvasTop - 50, accuracy: 0.001)
        XCTAssertLessThan(result.y, canvasTop)
        XCTAssertEqual(result.y + 50, key.minY, accuracy: 0.001)
    }

    func testCenterKeyKeepsPopupCenteredOnKey() {
        // 3段目のキー (ホスト y = 64 + 2*(50+6) = 176) ではクランプが
        // 働かず、中心セルがキーに重なる。
        let key = CGRect(x: 159, y: 176, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.x, key.midX - 108, accuracy: 0.001)
        XCTAssertEqual(result.y, key.minY - 50, accuracy: 0.001)
    }

    func testBottomRowOmitDownPopupFitsExactlyAtHostBottom() {
        // 最下段の わ (ホスト y = 64 + 3*(50+6) = 232)、下セルなし。
        // ポップアップ下端がホスト下端 (= キャンバス下端) と一致し、
        // 中心セルがキーに重なる。
        let key = CGRect(x: 90, y: 232, width: 72, height: 50)
        let result = origin(keyFrame: key, omitDown: true)
        XCTAssertEqual(result.y, 232 - 50, accuracy: 0.001)
        XCTAssertEqual(result.y + 100, host.height, accuracy: 0.001)
        XCTAssertEqual(result.y + 50, key.minY, accuracy: 0.001)
    }

    func testBottomRowFullPopupClampsToHostBottom() {
        // 下セルを持つキーが最下段にあった場合のガード: 下端がホストを
        // 越える分だけ原点が上へ寄る。
        let key = CGRect(x: 90, y: 232, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.y, host.height - 150, accuracy: 0.001)
    }

    func testTopClampAtHostTopEdge() {
        // 候補バーより上へは出さない (ホスト上端で止まる)。
        let key = CGRect(x: 90, y: 20, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testLeftAndRightEdgeKeysClampHorizontally() {
        let leftKey = CGRect(x: 8, y: 176, width: 72, height: 50)
        XCTAssertEqual(origin(keyFrame: leftKey).x, 0, accuracy: 0.001)
        let rightKey = CGRect(x: 310, y: 176, width: 72, height: 50)
        XCTAssertEqual(origin(keyFrame: rightKey).x, 390 - 216, accuracy: 0.001)
    }

    func testPopupLargerThanHostClampsToZero() {
        // ポップアップがホストより大きい異常寸法でも負値にならない。
        let result = FlickPopupGeometry.popupOrigin(
            keyFrame: CGRect(x: 10, y: 10, width: 72, height: 50),
            hostSize: CGSize(width: 100, height: 100), cellSize: cell, omitDown: false)
        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    // MARK: - 方向判定 (ドラッグ変位 → 方向)

    func testDirectionBelowThresholdIsCenter() {
        XCTAssertEqual(FlickPopupGeometry.direction(dx: 0, dy: 0, threshold: 20), .center)
        XCTAssertEqual(FlickPopupGeometry.direction(dx: 19, dy: -19, threshold: 20), .center)
    }

    func testDirectionPicksDominantAxis() {
        XCTAssertEqual(FlickPopupGeometry.direction(dx: -30, dy: 5, threshold: 20), .left)
        XCTAssertEqual(FlickPopupGeometry.direction(dx: 30, dy: -5, threshold: 20), .right)
        XCTAssertEqual(FlickPopupGeometry.direction(dx: 5, dy: -30, threshold: 20), .up)
        XCTAssertEqual(FlickPopupGeometry.direction(dx: -5, dy: 30, threshold: 20), .down)
        // しきい値ちょうどで方向が付く。
        XCTAssertEqual(FlickPopupGeometry.direction(dx: 0, dy: 20, threshold: 20), .down)
    }

    // MARK: - わ・、 の下フリック (省略は表示だけ)

    /// FlickCanvas.rows の わ・、 と同じ割当。
    private let waRow = FlickRow(center: "わ", left: "を", up: "ん", right: "ー", down: "ゎ", omitDown: true)
    private let punctRow = FlickRow(center: "、", left: "。", up: "？", right: "！", down: "・", omitDown: true)

    func testOmitDownKeysStillResolveDownCharacter() {
        // 表示の省略 (下セルを出さない) は従来どおり。
        XCTAssertFalse(FlickPopupGeometry.displayedDirections(omitDown: waRow.omitDown).contains(.down))
        XCTAssertFalse(FlickPopupGeometry.displayedDirections(omitDown: punctRow.omitDown).contains(.down))
        // しかし方向→文字の対応は生きていて、下フリックで ゎ・ が返る。
        XCTAssertEqual(waRow.candidate(.down), "ゎ")
        XCTAssertEqual(punctRow.candidate(.down), "・")
        // ドラッグ判定から確定文字までの全経路: 下方向のドラッグは
        // omitDown でも .down に解決され、down の文字が確定する。
        let drag = FlickPopupGeometry.direction(dx: 2, dy: 40, threshold: 20)
        XCTAssertEqual(drag, .down)
        XCTAssertEqual(waRow.candidate(drag), "ゎ")
        XCTAssertEqual(punctRow.candidate(drag), "・")
        // 他方向は従来どおり。
        XCTAssertEqual(waRow.candidate(.center), "わ")
        XCTAssertEqual(waRow.candidate(.left), "を")
        XCTAssertEqual(waRow.candidate(.up), "ん")
        XCTAssertEqual(waRow.candidate(.right), "ー")
        XCTAssertEqual(punctRow.candidate(.center), "、")
        XCTAssertEqual(punctRow.candidate(.left), "。")
        XCTAssertEqual(punctRow.candidate(.up), "？")
        XCTAssertEqual(punctRow.candidate(.right), "！")
    }

    func testGuideLettersMatchRowAssignments() {
        // ガイド文字は FlickRow の割当そのもの (キー面の上下左右に表示)。
        // わ は下の ゎ を含め4方向すべてが実挙動と一致する。
        let yaRow = FlickRow(center: "や", left: "「", up: "ゆ", right: "」", down: "よ")
        for row in [waRow, punctRow, yaRow] {
            XCTAssertEqual(row.candidate(.left), row.left)
            XCTAssertEqual(row.candidate(.up), row.up)
            XCTAssertEqual(row.candidate(.right), row.right)
            XCTAssertEqual(row.candidate(.down), row.down)
        }
        XCTAssertEqual(waRow.down, "ゎ")
        XCTAssertEqual(punctRow.down, "・")
        XCTAssertEqual(yaRow.left, "「")
        XCTAssertEqual(yaRow.right, "」")
    }
}
