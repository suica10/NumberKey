import Foundation

/// フリックの十字ポップアップ (3×3 セル) の配置計算。UIKit に依存しない
/// 純粋関数として切り出し、単体テストで固定する
/// (Tests/FlickPopupGeometryTests.swift)。
enum FlickPopupGeometry {
    /// フリック面の必要高さ。グリッド (4段＋段間3つ) の上下に、ポップ
    /// アップのセル 1 つ分の余白 (ヘッドルーム) を最初から確保する
    /// (2026-11-26 ユーザー提案)。最上段・最下段のキーでも、中心セルが
    /// キーに重なったまま十字全体がキャンバス内に収まる。
    static func preferredHeight(rowHeight: CGFloat, rowGap: CGFloat) -> CGFloat {
        rowHeight * 6 + rowGap * 3
    }

    /// ポップアップのコンテナ原点を返す。基準は「十字の中心セルが
    /// 押したキーに完全に重なる」位置 (純正準拠)。上下は preferredHeight
    /// の余白で収まる設計だが、想定外の寸法でも見切れないよう、原点を
    /// キャンバス内に収まる範囲へクランプするガードを兼ねる
    /// (横方向の端は余白が無いため、こちらは常時このクランプが効く)。
    /// CGRect の midX/minY は環境により見えないため原点・サイズから計算する。
    static func popupOrigin(keyFrame: CGRect, canvasSize: CGSize, cellSize: CGSize) -> CGPoint {
        let popupSize = CGSize(width: cellSize.width * 3, height: cellSize.height * 3)
        var origin = CGPoint(x: keyFrame.origin.x + keyFrame.size.width / 2 - popupSize.width / 2,
                             y: keyFrame.origin.y - cellSize.height)
        origin.x = min(max(0, origin.x), max(0, canvasSize.width - popupSize.width))
        origin.y = min(max(0, origin.y), max(0, canvasSize.height - popupSize.height))
        return origin
    }
}
