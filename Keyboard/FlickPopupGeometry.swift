import Foundation

/// フリック方向。ポップアップのセル配置と候補の対応を決める
/// (FlickCanvas のキー判定と、ここの配置計算で共有する)。
enum FlickDirection { case center, left, up, right, down }

/// フリックの十字ポップアップの配置計算。UIKit に依存しない純粋関数
/// として切り出し、単体テストで固定する
/// (Tests/FlickPopupGeometryTests.swift)。
///
/// 配置の前提 (2026-11-27 ユーザー指示): キャンバスに上下の余白は確保
/// しない。高さはグリッド (4段＋段間3つ) ちょうどで、最上段キーの
/// ポップアップはキャンバスの上端を越えて候補バー側へ被さる。そのため
/// ポップアップはキャンバスではなく候補バー＋キャンバスを跨ぐホスト
/// (VC のルートビュー) に載せ、座標はすべてホスト基準で扱う。
/// 最下段の わ・、 は下セル自体を持たない (下フリックは中央で確定する)
/// ため、下側の余白も要らない。
enum FlickPopupGeometry {
    /// フリック面の必要高さ = グリッドそのもの (4段＋段間3つ)。
    /// ポップアップ表示で高さは変わらない。
    static func preferredHeight(rowHeight: CGFloat, rowGap: CGFloat) -> CGFloat {
        rowHeight * 4 + rowGap * 3
    }

    /// ポップアップの占有サイズ。omitDown のキー (最下段の わ・、) は
    /// 下セルが無いため、高さがセル 2 つ分になる。
    static func popupSize(cellSize: CGSize, omitDown: Bool) -> CGSize {
        CGSize(width: cellSize.width * 3, height: cellSize.height * (omitDown ? 2 : 3))
    }

    /// ポップアップに表示するセルの集合。omitDown では下セルを出さない。
    static func displayedDirections(omitDown: Bool) -> [FlickDirection] {
        omitDown ? [.center, .left, .up, .right] : [.center, .left, .up, .right, .down]
    }

    /// ポップアップの原点を返す (ホスト座標、keyFrame もホスト座標)。
    /// 基準は「十字の中心セルが押したキーに完全に重なる」位置 (純正準拠)。
    /// 最上段では原点がキャンバスより上 (候補バー側) へ出るのが正しい
    /// 挙動で、クランプはホストの端に対してだけ掛ける (候補バーの
    /// さらに上や、ホストの下端の外へは出さないためのガード)。
    /// CGRect の midX/minY は環境により見えないため原点・サイズから計算する。
    static func popupOrigin(keyFrame: CGRect, hostSize: CGSize, cellSize: CGSize, omitDown: Bool) -> CGPoint {
        let size = popupSize(cellSize: cellSize, omitDown: omitDown)
        var origin = CGPoint(x: keyFrame.origin.x + keyFrame.size.width / 2 - size.width / 2,
                             y: keyFrame.origin.y - cellSize.height)
        origin.x = min(max(0, origin.x), max(0, hostSize.width - size.width))
        origin.y = min(max(0, origin.y), max(0, hostSize.height - size.height))
        return origin
    }
}
