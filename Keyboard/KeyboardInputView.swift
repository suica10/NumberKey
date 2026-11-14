import UIKit

/// キーボードのルートビュー（build 52）。
///
/// 高さの交渉をこのクラスに一本化する。経緯：
/// - ビルド51まで：ルートビュー（システム既定の UIInputView）に
///   heightAnchor 制約（優先度999）を付け、定数を 261↔295 に切り替えて
///   いたが、実機では view.bounds.height がホストアプリごとの既定高さ
///   （226 / 216）に固定され、制約が一度も勝たなかった
///   （diag-probe-5.csv で確定）。ビルド44当時は制約が効いていた。
/// - allowsSelfSizing = true 単独でも無効だった。allowsSelfSizing は
///   「入力ビューのフィッティング結果を使う」という宣言にすぎず、
///   ルートビューが systemLayoutSizeFitting / intrinsicContentSize で
///   希望高さを報告していない（中身は手動フレームで Auto Layout の
///   測定に乗らない）と、システムは既定高さに落ちる。
///
/// そこでこのサブクラスが requestedHeight を保持し、フィッティング
/// 系の API すべてで一貫してその高さを報告する。要求高さの計算と
/// 更新は KeyboardViewController.updateRequestedHeight() が唯一の
/// 入口（layoutMetrics の totalHeight を使う）。
final class KeyboardInputView: UIInputView {
    /// システムへ報告する希望高さ。変わったら intrinsic サイズを
    /// 無効化し、次のレイアウトで再測定させる。
    var requestedHeight: CGFloat = 270 {
        didSet {
            if abs(oldValue - requestedHeight) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowsSelfSizing = true
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: requestedHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        fittingSize(for: targetSize)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                          withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {
        fittingSize(for: targetSize)
    }

    private func fittingSize(for targetSize: CGSize) -> CGSize {
        let width = targetSize.width > 0 ? targetSize.width
            : (bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width)
        return CGSize(width: width, height: requestedHeight)
    }
}
