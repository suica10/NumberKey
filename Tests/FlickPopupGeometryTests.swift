import XCTest
@testable import PhraseStore

/// フリック十字ポップアップの配置計算 (2026-11-26 実機フィードバック:
/// ビルド83で最上段は上セル、最下段は下セルが見切れた) の単体テスト。
/// 本筋はグリッド上下の余白確保 (preferredHeight) で、原点クランプは
/// 横方向と異常寸法へのガード。前半の寸法は余白なし時代の代表値:
/// キャンバス 390×226、セル 72×50 (ポップアップは 216×150)。
final class FlickPopupGeometryTests: XCTestCase {
    private let canvas = CGSize(width: 390, height: 226)
    private let cell = CGSize(width: 72, height: 50)

    private func origin(keyFrame: CGRect) -> CGPoint {
        FlickPopupGeometry.popupOrigin(keyFrame: keyFrame, canvasSize: canvas, cellSize: cell)
    }

    func testCenterKeyKeepsPopupCenteredOnKey() {
        // 中央付近のキーではクランプが働かず、中心セルがキーに重なる。
        let key = CGRect(x: 159, y: 110, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.x, key.midX - 108, accuracy: 0.001)
        XCTAssertEqual(result.y, key.minY - 50, accuracy: 0.001)
    }

    func testTopRowKeyClampsToTopEdge() {
        // 最上段 (y=3): 基準位置は y=-47 にはみ出すため 0 にクランプされ、
        // 上セルまで全て見える。
        let key = CGRect(x: 90, y: 3, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testBottomRowKeyClampsToBottomEdge() {
        // 最下段 (y=173): 基準位置は y=123 で下端 (226) を 47 はみ出すため、
        // 226-150=76 にクランプされ、下セルまで全て見える。
        let key = CGRect(x: 90, y: 173, width: 72, height: 50)
        let result = origin(keyFrame: key)
        XCTAssertEqual(result.y, 226 - 150, accuracy: 0.001)
    }

    func testLeftAndRightEdgeKeysClampHorizontally() {
        let leftKey = CGRect(x: 8, y: 110, width: 72, height: 50)
        XCTAssertEqual(origin(keyFrame: leftKey).x, 0, accuracy: 0.001)
        let rightKey = CGRect(x: 310, y: 110, width: 72, height: 50)
        XCTAssertEqual(origin(keyFrame: rightKey).x, 390 - 216, accuracy: 0.001)
    }

    func testPopupLargerThanCanvasClampsToZero() {
        // ポップアップがキャンバスより大きい異常寸法でも負値にならない。
        let result = FlickPopupGeometry.popupOrigin(
            keyFrame: CGRect(x: 10, y: 10, width: 72, height: 50),
            canvasSize: CGSize(width: 100, height: 100), cellSize: cell)
        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    // MARK: - 余白確保 (2026-11-26 ユーザー提案の本筋)

    /// 余白つきの実寸: 行高 50・段間 6 → 高さ 6*50+3*6 = 318、
    /// グリッドは上から 50 (セル1つ分) 下げて始まる。
    private var headroomCanvas: CGSize {
        CGSize(width: 390, height: FlickPopupGeometry.preferredHeight(rowHeight: 50, rowGap: 6))
    }

    func testPreferredHeightReservesOneCellTopAndBottom() {
        XCTAssertEqual(FlickPopupGeometry.preferredHeight(rowHeight: 50, rowGap: 6), 318, accuracy: 0.001)
    }

    func testTopRowPopupFitsWithoutClampingWhenHeadroomReserved() {
        // 最上段キー (グリッド開始 y=50): 中心セル＝キーの基準位置
        // (y=0) のままクランプなしで収まる。
        let key = CGRect(x: 90, y: 50, width: 72, height: 50)
        let result = FlickPopupGeometry.popupOrigin(keyFrame: key, canvasSize: headroomCanvas, cellSize: cell)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testBottomRowPopupFitsWithoutClampingWhenHeadroomReserved() {
        // 最下段キー (y = 50 + 3*(50+6) = 218): 基準位置 (y=168) のまま
        // 収まり、ポップアップ下端がキャンバス高さ 318 と一致する。
        let key = CGRect(x: 90, y: 218, width: 72, height: 50)
        let result = FlickPopupGeometry.popupOrigin(keyFrame: key, canvasSize: headroomCanvas, cellSize: cell)
        XCTAssertEqual(result.y, 168, accuracy: 0.001)
        XCTAssertEqual(result.y + 150, headroomCanvas.height, accuracy: 0.001)
    }
}
