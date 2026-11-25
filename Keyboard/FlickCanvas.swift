import UIKit

/// キーボード面の共通表面。VC は QWERTY 面 (KeyboardCanvas) とフリック面
/// (FlickCanvas) を設定で切り替えるため、VC が触る操作だけをここに揃える。
/// KeyboardCanvas は既存実装がそのまま適合する (拡張で適合を宣言)。
@MainActor
protocol KeyboardSurface: UIView {
    var onText: ((String) -> Void)? { get set }
    var onAction: ((KeyboardAction) -> Void)? { get set }
    var onDeleteHold: ((UILongPressGestureRecognizer) -> Void)? { get set }
    var configureGlobe: ((UIButton) -> Void)? { get set }
    var configureSwitchKey: ((UIButton) -> Void)? { get set }
    var configureMenu: ((UIButton) -> Void)? { get set }
    var configureSpaceMenu: ((UIButton) -> Void)? { get set }
    func configure(_ settings: LayoutSettings, shifted: Bool, symbols: Bool, japanese: Bool)
    func updateShift(_ shifted: Bool, caps: Bool)
    func setJapaneseMode(_ japanese: Bool)
    func setComposing(_ composing: Bool)
    func preferredHeight(width: CGFloat) -> CGFloat
}

extension KeyboardCanvas: KeyboardSurface {}

/// フリック1キーの候補。純正の並び: 中央=あ段、左=い段、上=う段、
/// 右=え段、下=お段。特殊行 (や・わ・記号) も同じ5枠に純正割当を入れる。
private struct FlickRow {
    var center: String
    var left: String
    var up: String
    var right: String
    var down: String
    func candidate(_ direction: FlickDirection) -> String {
        switch direction {
        case .center: return center
        case .left: return left
        case .up: return up
        case .right: return right
        case .down: return down
        }
    }
}

private enum FlickDirection { case center, left, up, right, down }

/// フリック判定を持つかなキー。タッチ開始点を記録し、移動量がしきい値を
/// 超えたら支配的な軸方向を選ぶ。離した時点で選択中の候補を必ず確定する
/// (キャンセル方向を作らない: QWERTY 面の「キーを取りこぼさない」原則)。
@MainActor
private final class FlickKey: UIView {
    var row: FlickRow
    var normalColor: UIColor = .darkGray
    var pressedColor: UIColor = .gray
    var dark = true
    var onPreview: ((FlickKey, FlickDirection) -> Void)?
    var onCommit: ((String) -> Void)?
    var onEnd: (() -> Void)?
    private let label = UILabel()
    private var startPoint: CGPoint?
    private var direction: FlickDirection = .center
    private var shadowSize: CGSize = .zero

    init(row: FlickRow, displayLabel: String? = nil) {
        self.row = row
        super.init(frame: .zero)
        label.text = displayLabel ?? row.center
        if displayLabel != nil { label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5 }
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isAccessibilityElement = true
        accessibilityLabel = row.center
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        label.font = .systemFont(ofSize: min(30, max(20, bounds.height * 0.52)))
        label.textColor = dark ? .white : .black
        backgroundColor = startPoint == nil ? normalColor : pressedColor
        if shadowSize != bounds.size {
            shadowSize = bounds.size
            layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: bounds.size), cornerRadius: 5).cgPath
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        startPoint = touch.location(in: self)
        direction = .center
        backgroundColor = pressedColor
        onPreview?(self, .center)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start = startPoint, let touch = touches.first else { return }
        let point = touch.location(in: self)
        let dx = point.x - start.x, dy = point.y - start.y
        let threshold = max(16, bounds.height * 0.38)
        var next: FlickDirection = .center
        if max(abs(dx), abs(dy)) >= threshold {
            next = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
        }
        if next != direction {
            direction = next
            onPreview?(self, next)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard startPoint != nil else { return }
        startPoint = nil
        backgroundColor = normalColor
        onCommit?(row.candidate(direction))
        onEnd?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // キャンセルでも選択中の候補を確定する (取りこぼさない)。
        touchesEnded(touches, with: event)
    }
}

/// 純正準拠のフリック面。実機の純正レイアウト (2026-11-25 ユーザー提供
/// スクリーンショット) に合わせた4段構成で、最下段バーは持たない:
/// 左レール = 絵文字 / ☆123 / ABC (縦長)、右レール = 削除 / 空白・変換 /
/// 確定 (縦長)、グリッド4段目は左から「゛゜小」「わ」「、。？！」。
/// 純正の左レール上段2キー (→ = トグル入力のクールタイム解除、
/// 曲矢印 = トグルの逆順) はトグル入力専用なので、フリックのみの本面では
/// 絵文字キーと ☆123 (記号面への直行) に置き換える。
/// 長押し割当 (2026-11-24 ユーザー口述): 確定長押し→クリップボード、
/// ABC 長押し→定型文、絵文字キーはタップで絵文字パネル。
@MainActor
final class FlickCanvas: UIView, KeyboardSurface {
    var onText: ((String) -> Void)?
    var onAction: ((KeyboardAction) -> Void)?
    var onDeleteHold: ((UILongPressGestureRecognizer) -> Void)?
    var configureGlobe: ((UIButton) -> Void)?
    var configureSwitchKey: ((UIButton) -> Void)?
    var configureMenu: ((UIButton) -> Void)?
    var configureSpaceMenu: ((UIButton) -> Void)?
    /// フリック面専用のコールバック (VC が個別に配線する)。
    var onDakuten: (() -> Void)?
    var onEmoji: (() -> Void)?
    var onLanguage: (() -> Void)?
    var onLanguageHold: (() -> Void)?
    var onSymbols: (() -> Void)?

    private var settings = LayoutSettings.defaults
    private var flickKeys: [FlickKey] = []
    private var emojiKey: KeyboardKey?
    private var symbolsKey: KeyboardKey?
    private var languageKey: KeyboardKey?
    private var deleteKey: KeyboardKey?
    private var dakutenKey: KeyboardKey?
    private var spaceKey: KeyboardKey?
    private var enterKey: KeyboardKey?
    private var switchKey: KeyboardKey?
    private var popup: UIView?
    private var popupCells: [FlickDirection: UILabel] = [:]
    private var composing = false

    private var dark: Bool { settings.theme == 2 || (settings.theme == 0 && traitCollection.userInterfaceStyle != .light) }
    private var keyColor: UIColor { dark ? UIColor(white: 0.38, alpha: 1) : .white }

    /// 純正の行割当。行ごとに [中央, 左, 上, 右, 下]。
    private static let rows: [FlickRow] = [
        FlickRow(center: "あ", left: "い", up: "う", right: "え", down: "お"),
        FlickRow(center: "か", left: "き", up: "く", right: "け", down: "こ"),
        FlickRow(center: "さ", left: "し", up: "す", right: "せ", down: "そ"),
        FlickRow(center: "た", left: "ち", up: "つ", right: "て", down: "と"),
        FlickRow(center: "な", left: "に", up: "ぬ", right: "ね", down: "の"),
        FlickRow(center: "は", left: "ひ", up: "ふ", right: "へ", down: "ほ"),
        FlickRow(center: "ま", left: "み", up: "む", right: "め", down: "も"),
        FlickRow(center: "や", left: "「", up: "ゆ", right: "」", down: "よ"),
        FlickRow(center: "ら", left: "り", up: "る", right: "れ", down: "ろ"),
        FlickRow(center: "わ", left: "を", up: "ん", right: "ー", down: "ゎ"),
        FlickRow(center: "、", left: "。", up: "？", right: "！", down: "・"),
    ]

    func configure(_ settings: LayoutSettings, shifted: Bool, symbols: Bool, japanese: Bool) {
        self.settings = settings
        subviews.forEach { $0.removeFromSuperview() }
        popup = nil; popupCells = [:]; flickKeys = []
        backgroundColor = dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1)
        for (index, row) in Self.rows.enumerated() {
            // 記号キーの表示ラベルは純正どおり「、。？！」。
            let key = FlickKey(row: row, displayLabel: index == Self.rows.count - 1 ? "、。？！" : nil)
            key.normalColor = keyColor
            key.pressedColor = dark ? UIColor(white: 0.56, alpha: 1) : UIColor(white: 0.92, alpha: 1)
            key.dark = dark
            key.onPreview = { [weak self] key, direction in self?.showPopup(for: key, direction: direction) }
            key.onCommit = { [weak self] text in self?.onText?(text) }
            key.onEnd = { [weak self] in self?.hidePopup() }
            addSubview(key)
            flickKeys.append(key)
        }
        dakutenKey = makeKey("゛゜小") { [weak self] in self?.onDakuten?() }
        dakutenKey?.accessibilityLabel = "濁点・小書き"
        emojiKey = makeKey("😊") { [weak self] in self?.onEmoji?() }
        emojiKey?.accessibilityLabel = "絵文字"
        symbolsKey = makeKey("☆123") { [weak self] in self?.onSymbols?() }
        symbolsKey?.accessibilityLabel = "数字・記号"
        languageKey = makeKey("ABC") { [weak self] in self?.onLanguage?() }
        languageKey?.accessibilityLabel = "英数入力"
        let languageHold = UILongPressGestureRecognizer(target: self, action: #selector(languageHeld(_:)))
        languageKey?.addGestureRecognizer(languageHold)
        deleteKey = makeKey("") { [weak self] in self?.onAction?(.delete) }
        deleteKey?.setImage(UIImage(systemName: "delete.left.fill"), for: .normal)
        deleteKey?.accessibilityLabel = "削除"
        deleteKey?.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(deleteHeld(_:))))
        spaceKey = makeKey(composing ? "変換" : "空白") { [weak self] in self?.onAction?(.space) }
        spaceKey?.accessibilityLabel = "空白・次候補"
        enterKey = makeKey(composing ? "確定" : "return") { [weak self] in self?.onAction?(.enter) }
        enterKey?.accessibilityLabel = composing ? "確定" : "改行"
        let enterHold = UILongPressGestureRecognizer(target: self, action: #selector(returnHeld(_:)))
        enterKey?.addGestureRecognizer(enterHold)
        // iPad ではシステムの地球キーが出ないため切替キーが要る (QWERTY 面と
        // 同じ理由・同じ配線)。置き場所は左レールの最上段にする。
        if UIDevice.current.userInterfaceIdiom == .pad {
            let key = makeKey("", action: nil)
            key.setImage(UIImage(systemName: "keyboard"), for: .normal)
            key.accessibilityLabel = "キーボード切替"
            configureSwitchKey?(key)
            switchKey = key
        }
        setNeedsLayout()
    }

    private func makeKey(_ title: String, action: (() -> Void)?) -> KeyboardKey {
        let key = KeyboardKey(type: .custom)
        key.setTitle(title, for: .normal)
        key.setTitleColor(dark ? .white : .black, for: .normal)
        key.tintColor = dark ? .white : .black
        key.normalColor = keyColor
        key.pressedColor = dark ? UIColor(white: 0.56, alpha: 1) : UIColor(white: 0.92, alpha: 1)
        key.backgroundColor = key.normalColor
        key.layer.cornerRadius = 5
        key.layer.shadowColor = UIColor.black.cgColor
        key.layer.shadowOpacity = 0.25
        key.layer.shadowRadius = 0.5
        key.layer.shadowOffset = CGSize(width: 0, height: 1)
        key.titleLabel?.adjustsFontSizeToFitWidth = true
        key.titleLabel?.minimumScaleFactor = 0.6
        key.accessibilityLabel = title
        if let action { key.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        addSubview(key)
        return key
    }

    @objc private func deleteHeld(_ g: UILongPressGestureRecognizer) { onDeleteHold?(g) }
    @objc private func languageHeld(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { onLanguageHold?() }
    }
    @objc private func returnHeld(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { onAction?(.paste) }
    }

    // MARK: - 寸法 (QWERTY 面と同じ基準幅 1206 = 402pt @3x の換算)

    private func rowHeight(width: CGFloat) -> CGFloat { min(62, max(44, width * 156 / 1206)) }
    private func rowGap(width: CGFloat) -> CGFloat { width * 18 / 1206 }

    func preferredHeight(width: CGFloat) -> CGFloat {
        rowHeight(width: width) * 4 + rowGap(width: width) * 3 + 7
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard flickKeys.count == Self.rows.count else { return }
        let width = bounds.width
        let edge = width * 9 / 1206, gap = width * 16 / 1206
        let vGap = rowGap(width: width), height = rowHeight(width: width)
        // 列: 左レール 0.84 / かな 1.0 ×3 / 右レール 1.08 (純正の比率)
        let unit = (width - 2 * edge - 4 * gap) / 4.92
        let leftRail = unit * 0.84, rightRail = unit * 1.08
        let colX: [CGFloat] = [edge + leftRail + gap,
                               edge + leftRail + unit + 2 * gap,
                               edge + leftRail + 2 * unit + 3 * gap]
        let rightX = edge + leftRail + 3 * unit + 4 * gap
        var rowYs: [CGFloat] = []
        var nextY: CGFloat = 3
        for _ in 0..<4 { rowYs.append(nextY); nextY += height + vGap }
        for (index, key) in flickKeys.enumerated() {
            if index < 9 {
                key.frame = CGRect(x: colX[index % 3], y: rowYs[index / 3], width: unit, height: height)
            } else if index == 9 {
                key.frame = CGRect(x: colX[1], y: rowYs[3], width: unit, height: height)
            } else {
                key.frame = CGRect(x: colX[2], y: rowYs[3], width: unit, height: height)
            }
            key.setNeedsLayout()
        }
        dakutenKey?.frame = CGRect(x: colX[0], y: rowYs[3], width: unit, height: height)
        let tallHeight = height * 2 + vGap
        if let switchKey {
            // iPad: 左レールは上から 切替 / 絵文字 / ☆123 / ABC (各1段)。
            switchKey.frame = CGRect(x: edge, y: rowYs[0], width: leftRail, height: height)
            emojiKey?.frame = CGRect(x: edge, y: rowYs[1], width: leftRail, height: height)
            symbolsKey?.frame = CGRect(x: edge, y: rowYs[2], width: leftRail, height: height)
            languageKey?.frame = CGRect(x: edge, y: rowYs[3], width: leftRail, height: height)
        } else {
            emojiKey?.frame = CGRect(x: edge, y: rowYs[0], width: leftRail, height: height)
            symbolsKey?.frame = CGRect(x: edge, y: rowYs[1], width: leftRail, height: height)
            languageKey?.frame = CGRect(x: edge, y: rowYs[2], width: leftRail, height: tallHeight)
        }
        deleteKey?.frame = CGRect(x: rightX, y: rowYs[0], width: rightRail, height: height)
        spaceKey?.frame = CGRect(x: rightX, y: rowYs[1], width: rightRail, height: height)
        enterKey?.frame = CGRect(x: rightX, y: rowYs[2], width: rightRail, height: tallHeight)
        for key in [emojiKey, symbolsKey, languageKey, deleteKey, dakutenKey, spaceKey, enterKey, switchKey] {
            guard let key else { continue }
            key.titleLabel?.font = .systemFont(ofSize: min(20, max(14, height * 0.36)))
            key.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: height * 0.42, weight: .semibold), forImageIn: .normal)
            fixShadow(key)
        }
        if let dakutenKey { dakutenKey.titleLabel?.font = .systemFont(ofSize: min(16, max(12, height * 0.3))) }
        if let symbolsKey { symbolsKey.titleLabel?.font = .systemFont(ofSize: min(17, max(13, height * 0.32))) }
    }

    private func fixShadow(_ key: KeyboardKey) {
        guard key.shadowSize != key.frame.size else { return }
        key.shadowSize = key.frame.size
        key.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: key.frame.size), cornerRadius: 5).cgPath
    }

    // MARK: - フリックプレビュー (十字ポップアップ)

    private func showPopup(for key: FlickKey, direction: FlickDirection) {
        if popup == nil {
            let container = UIView()
            container.isUserInteractionEnabled = false
            container.accessibilityElementsHidden = true
            for dir in [FlickDirection.center, .left, .up, .right, .down] {
                let cell = UILabel()
                cell.textAlignment = .center
                cell.layer.cornerRadius = 5
                cell.layer.masksToBounds = true
                container.addSubview(cell)
                popupCells[dir] = cell
            }
            addSubview(container)
            popup = container
        }
        guard let popup else { return }
        bringSubviewToFront(popup)
        let cell = key.bounds.size
        let size = CGSize(width: cell.width * 3, height: cell.height * 3)
        // 純正と同じく、十字の中央セルが押したキーの真上に重なる位置に出す。
        var origin = CGPoint(x: key.frame.midX - size.width / 2, y: key.frame.minY - cell.height)
        origin.x = min(max(2, origin.x), max(2, bounds.width - size.width - 2))
        popup.frame = CGRect(origin: origin, size: size)
        let positions: [FlickDirection: CGRect] = [
            .center: CGRect(x: cell.width, y: cell.height, width: cell.width, height: cell.height),
            .left: CGRect(x: 0, y: cell.height, width: cell.width, height: cell.height),
            .up: CGRect(x: cell.width, y: 0, width: cell.width, height: cell.height),
            .right: CGRect(x: cell.width * 2, y: cell.height, width: cell.width, height: cell.height),
            .down: CGRect(x: cell.width, y: cell.height * 2, width: cell.width, height: cell.height),
        ]
        for (dir, cellLabel) in popupCells {
            cellLabel.frame = positions[dir] ?? .zero
            cellLabel.text = key.row.candidate(dir)
            cellLabel.font = .systemFont(ofSize: min(30, max(20, cell.height * 0.52)))
            let selected = dir == direction
            cellLabel.backgroundColor = selected
                ? (dark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.35, alpha: 1))
                : keyColor
            cellLabel.textColor = selected ? (dark ? .black : .white) : (dark ? .white : .black)
        }
    }

    private func hidePopup() {
        popup?.removeFromSuperview()
        popup = nil
        popupCells = [:]
    }

    // MARK: - KeyboardSurface の QWERTY 固有操作 (フリック面では不要)

    func updateShift(_ shifted: Bool, caps: Bool) {}
    func setJapaneseMode(_ japanese: Bool) {}
    func setComposing(_ composing: Bool) {
        guard composing != self.composing else { return }
        self.composing = composing
        spaceKey?.setTitle(composing ? "変換" : "空白", for: .normal)
        enterKey?.setTitle(composing ? "確定" : "return", for: .normal)
        enterKey?.accessibilityLabel = composing ? "確定" : "改行"
    }
}
