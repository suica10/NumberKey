import UIKit

enum KeyboardAction { case shift, delete, symbols, space, enter }

final class KeyboardKey: UIButton {
    var normalColor: UIColor = .darkGray
    var pressedColor: UIColor = .gray
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? pressedColor : normalColor }
    }
}

@MainActor
final class KeyboardCanvas: UIView {
    var onText: ((String) -> Void)?
    var onAction: ((KeyboardAction) -> Void)?
    var onDeleteHold: ((UILongPressGestureRecognizer) -> Void)?
    var onCaps: (() -> Void)?
    var configureGlobe: ((UIButton) -> Void)?
    var configureMenu: ((UIButton) -> Void)?
    private var settings = LayoutSettings.defaults
    private var characterRows: [[KeyboardKey]] = []
    private var values: [[String]] = []
    private var shiftButton: KeyboardKey?
    private var deleteButton: KeyboardKey?
    private var bottom: [KeyboardKey] = []
    private var popup: UILabel?
    private var shifted = false
    private var dark: Bool { traitCollection.userInterfaceStyle != .light }
    private var keyColor: UIColor { dark ? UIColor(white: 0.38, alpha: 1) : .white }

    func configure(_ settings: LayoutSettings, shifted: Bool, symbols: Bool) {
        self.settings = settings; self.shifted = shifted
        subviews.forEach { $0.removeFromSuperview() }
        popup = nil; characterRows = []; bottom = []
        backgroundColor = dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1)
        values = settings.rows
        if symbols {
            let symbolRows: [String] = ["!@#$%^&*()", "[]{}<>+=/", "_\\|~\u{0060}：；"]
            values = [settings.rows[0]] + symbolRows.map { line in line.map { String($0) } }
        }
        for row in values {
            characterRows.append(row.map { text in
                let button = makeKey(text) { [weak self] in self?.onText?(text) }
                button.accessibilityIdentifier = text
                let alternates = ["1":"!", "2":"@", "3":"#", "4":"$", "5":"%", "6":"^", "7":"&", "8":"*", "9":"(", "0":")"]
                if let alternate = alternates[text] {
                    button.menu = UIMenu(children: [UIAction(title: alternate) { [weak self] _ in self?.onText?(alternate) }])
                }
                button.addAction(UIAction { [weak self, weak button] _ in
                    if let button { self?.showPopup(button) }
                }, for: [.touchDown, .touchDragEnter])
                button.addAction(UIAction { [weak self] _ in self?.hidePopup() },
                                 for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
                return button
            })
        }
        shiftButton = makeKey("") { [weak self] in self?.onAction?(.shift) }
        shiftButton?.accessibilityLabel = "シフト"
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleShift(_:)))
        doubleTap.numberOfTapsRequired = 2
        shiftButton?.addGestureRecognizer(doubleTap)
        deleteButton = makeKey("") { [weak self] in self?.onAction?(.delete) }
        deleteButton?.setImage(UIImage(systemName: "delete.left.fill"), for: .normal)
        deleteButton?.accessibilityLabel = "削除"
        deleteButton?.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(deleteHold(_:))))
        let symbolsKey = makeKey(symbols ? "ABC" : "123") { [weak self] in self?.onAction?(.symbols) }
        symbolsKey.accessibilityLabel = symbols ? "英字配列" : "数字と記号"
        configureMenu?(symbolsKey)
        let globe = makeKey("", action: nil)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.accessibilityLabel = "次のキーボード"
        configureGlobe?(globe)
        let space = makeKey("space") { [weak self] in self?.onAction?(.space) }
        space.accessibilityLabel = "スペース"
        let enter = makeKey("return") { [weak self] in self?.onAction?(.enter) }
        enter.accessibilityLabel = "改行"
        bottom = [symbolsKey, globe, space, enter]
        updateShift(shifted, caps: false)
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
        key.titleLabel?.minimumScaleFactor = 0.65
        key.accessibilityLabel = title
        if let action { key.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        addSubview(key)
        return key
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let height = settings.keyHeight == 0 ? min(49, max(32, width * 114 / 1206)) : CGFloat(settings.keyHeight)
        return height * 5 + width * 26 / 1206 * 4 + 7
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard characterRows.count == 4, bottom.count == 4 else { return }
        let width = bounds.width, edge = width * 9 / 1206, gap = width * 20 / 1206
        let verticalGap = width * 26 / 1206
        let keyWidth = (width - 2 * edge - 9 * gap) / 10
        let keyHeight = settings.keyHeight == 0 ? min(49, max(32, width * 114 / 1206)) : CGFloat(settings.keyHeight)
        let font = min(26, max(18, width * 66 / 1206))
        for r in 0..<4 {
            let count = characterRows[r].count
            let span = CGFloat(count) * keyWidth + CGFloat(count - 1) * gap
            let start = r < 2 ? edge : (width - span) / 2
            for (c, key) in characterRows[r].enumerated() {
                key.frame = CGRect(x: start + CGFloat(c) * (keyWidth + gap), y: 3 + CGFloat(r) * (keyHeight + verticalGap), width: keyWidth, height: keyHeight)
                key.titleLabel?.font = .systemFont(ofSize: font)
            }
        }
        let sideWidth = keyWidth * 1.34
        shiftButton?.frame = CGRect(x: edge, y: 3 + 3 * (keyHeight + verticalGap), width: sideWidth, height: keyHeight)
        deleteButton?.frame = CGRect(x: width - edge - sideWidth, y: 3 + 3 * (keyHeight + verticalGap), width: sideWidth, height: keyHeight)
        let icon = UIImage.SymbolConfiguration(pointSize: font + 2, weight: .semibold)
        shiftButton?.setPreferredSymbolConfiguration(icon, forImageIn: .normal)
        deleteButton?.setPreferredSymbolConfiguration(icon, forImageIn: .normal)
        let weights: [CGFloat] = [132, 130, 588, 282]
        let available = width - 2 * edge - 3 * gap
        var x = edge
        for i in 0..<4 {
            let key = bottom[i], w = available * weights[i] / weights.reduce(0, +)
            key.frame = CGRect(x: x, y: 3 + 4 * (keyHeight + verticalGap), width: w, height: keyHeight)
            key.titleLabel?.font = .systemFont(ofSize: min(20, max(15, font * 0.82)))
            key.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: font + 3, weight: .regular), forImageIn: .normal)
            x += w + gap
        }
    }

    func updateShift(_ shifted: Bool, caps: Bool) {
        self.shifted = shifted
        for (r, row) in characterRows.enumerated() {
            for (c, button) in row.enumerated() {
                let value = values[r][c]
                button.setTitle(shifted ? value.uppercased() : value, for: .normal)
            }
        }
        shiftButton?.setImage(UIImage(systemName: caps ? "capslock.fill" : shifted ? "shift.fill" : "shift"), for: .normal)
    }
    func setComposing(_ composing: Bool) {
        bottom.last?.setTitle(composing ? "確定" : "return", for: .normal)
        bottom.last?.accessibilityLabel = composing ? "確定" : "改行"
    }
    private func showPopup(_ key: UIButton) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        hidePopup()
        let label = UILabel()
        label.text = key.title(for: .normal)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 32)
        label.textColor = dark ? .white : .black
        label.backgroundColor = keyColor
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.frame = CGRect(x: key.frame.midX - (key.bounds.width + 18) / 2,
                             y: max(0, key.frame.minY - 43), width: key.bounds.width + 18, height: 48)
        label.isUserInteractionEnabled = false
        label.accessibilityElementsHidden = true
        addSubview(label); popup = label
    }
    private func hidePopup() { popup?.removeFromSuperview(); popup = nil }
    @objc private func doubleShift(_ g: UITapGestureRecognizer) { onCaps?() }
    @objc private func deleteHold(_ g: UILongPressGestureRecognizer) { onDeleteHold?(g) }
}
