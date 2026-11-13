import UIKit

enum KeyboardAction { case shift, delete, symbols, symbolPage, space, enter, paste }

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
    var configureSpaceMenu: ((UIButton) -> Void)?
    private var settings = LayoutSettings.defaults
    private var characterRows: [[KeyboardKey]] = []
    private var values: [[String]] = []
    private var shiftButton: KeyboardKey?
    private var deleteButton: KeyboardKey?
    private var spaceButton: KeyboardKey?
    private var bottom: [KeyboardKey] = []
    private var popup: UILabel?
    private var shifted = false
    private var symbols = false
    private var symbolPage = 0
    private var dark: Bool { settings.theme == 2 || (settings.theme == 0 && traitCollection.userInterfaceStyle != .light) }
    private var keyColor: UIColor { dark ? UIColor(white: 0.38, alpha: 1) : .white }

    func configure(_ settings: LayoutSettings, shifted: Bool, symbols: Bool, symbolPage: Int, japanese: Bool) {
        self.settings = settings; self.shifted = shifted
        self.symbols = symbols; self.symbolPage = symbolPage
        subviews.forEach { $0.removeFromSuperview() }
        popup = nil; characterRows = []; bottom = []
        lastLayoutFont = -1  // キーを作り直したのでフォントを当て直させる
        backgroundColor = dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.82, alpha: 1)
        if symbols {
            let mainSymbols = ["-", "/", ":", ";", "(", ")", "$", "&", "@", String(UnicodeScalar(34)!)]
            let extendedSymbols = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
            let punctuation = [".", ",", "?", "!", "'"]
            let backslash = String(UnicodeScalar(92)!)
            let extraSymbols = ["_", backslash, "|", "~", "<", ">", "€", "£", "¥", "•"]
            let digitRow = japanese ? settings.rows[0].map(japaneseFullWidth) : settings.rows[0]
            let symbolRow = symbolPage == 0 ? mainSymbols : extendedSymbols
            let punctuationRow = symbolPage == 0 ? punctuation : extraSymbols
            values = [digitRow,
                      japanese ? symbolRow.map(japaneseFullWidth) : symbolRow,
                      japanese ? punctuationRow.map(japaneseFullWidth) : punctuationRow]
        } else {
            values = settings.rows
        }
        let alternates = ["1":"!", "2":"@", "3":"#", "4":"$", "5":"%", "6":"^", "7":"&", "8":"*", "9":"(", "0":")",
                          "１":"！", "２":"＠", "３":"＃", "４":"＄", "５":"％", "６":"＾", "７":"＆", "８":"＊", "９":"（", "０":"）"]
        for row in values {
            characterRows.append(row.map { text in
                // 文字キーは touchDown で確定する: touchUpInside だと、離す前に
                // 指が少しでもキー外へ流れると入力が落ちる (ユーザーの
                // 「文字が抜ける」の主因)。長押しメニュー付きの数字キーだけは
                // メニュー選択と二重入力にならないよう従来のまま。
                let button = makeKey(text, commitOnDown: alternates[text] == nil) { [weak self] in self?.onText?(text) }
                button.accessibilityIdentifier = text
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
        shiftButton = makeKey(symbols ? (symbolPage == 0 ? "#+=" : "123") : "") { [weak self] in
            self?.onAction?(symbols ? .symbolPage : .shift)
        }
        shiftButton?.accessibilityLabel = symbols ? (symbolPage == 0 ? "その他の記号" : "数字記号") : "シフト"
        if !symbols {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleShift(_:)))
            doubleTap.numberOfTapsRequired = 2
            shiftButton?.addGestureRecognizer(doubleTap)
        }
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
        let space = makeKey(japanese ? "日本語" : "space") { [weak self] in self?.onAction?(.space) }
        configureSpaceMenu?(space)
        let comma = makeKey(japanese ? "、" : ",", commitOnDown: true) { [weak self] in self?.onText?(japanese ? "、" : ",") }
        comma.accessibilityLabel = japanese ? "読点" : "comma"
        let period = makeKey(japanese ? "。" : ".", commitOnDown: true) { [weak self] in self?.onText?(japanese ? "。" : ".") }
        period.accessibilityLabel = japanese ? "句点" : "period"
        let enter = makeKey("return") { [weak self] in self?.onAction?(.enter) }
        enter.accessibilityLabel = "改行"
        let pasteHold = UILongPressGestureRecognizer(target: self, action: #selector(returnHold(_:)))
        enter.addGestureRecognizer(pasteHold)
        spaceButton = space
        bottom = [symbolsKey, globe, comma, space, period, enter]
        // 再構築前の確定/改行の表示状態を引き継ぐ。
        let composing = lastComposing ?? false
        lastComposing = nil
        setComposing(composing)
        setJapaneseMode(japanese)
        updateShift(shifted, caps: false)
        setNeedsLayout()
    }

    private func makeKey(_ title: String, commitOnDown: Bool = false, action: (() -> Void)?) -> KeyboardKey {
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
        if let action { key.addAction(UIAction { _ in action() }, for: commitOnDown ? .touchDown : .touchUpInside) }
        addSubview(key)
        return key
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let height = settings.keyHeight == 0 ? min(49, max(32, width * 114 / 1206)) : CGFloat(settings.keyHeight)
        let rowCount: CGFloat = symbols ? 4 : 5
        return height * rowCount + width * 26 / 1206 * (rowCount - 1) + 7
    }

    private var lastLayoutFont: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        guard characterRows.count == (symbols ? 3 : 4), bottom.count == 6 else { return }
        let width = bounds.width, edge = width * 9 / 1206, gap = width * 20 / 1206
        let verticalGap = width * 26 / 1206
        let keyWidth = (width - 2 * edge - 9 * gap) / 10
        let keyHeight = settings.keyHeight == 0 ? min(49, max(32, width * 114 / 1206)) : CGFloat(settings.keyHeight)
        let font = min(26, max(18, width * 66 / 1206))
        // フォントとシンボル設定は幅が変わったときだけ当て直す（レイアウトの
        // たびに全キーへ設定し直すと、それだけで再描画が走って重くなる）。
        let fontsChanged = font != lastLayoutFont
        let sideWidth = keyWidth * 1.34
        for (rowIndex, row) in characterRows.enumerated() {
            let count = row.count
            let rowWidth: CGFloat
            if symbols && rowIndex == 2 {
                let available = width - 2 * edge - 2 * sideWidth - 2 * gap
                rowWidth = min(keyWidth, (available - CGFloat(count - 1) * gap) / CGFloat(count))
            } else {
                rowWidth = keyWidth
            }
            let span = CGFloat(count) * rowWidth + CGFloat(count - 1) * gap
            let start = rowIndex < 2 ? edge : (width - span) / 2
            let y = 3 + CGFloat(rowIndex) * (keyHeight + verticalGap)
            for (column, key) in row.enumerated() {
                key.frame = CGRect(x: start + CGFloat(column) * (rowWidth + gap), y: y, width: rowWidth, height: keyHeight)
                if fontsChanged { key.titleLabel?.font = .systemFont(ofSize: font) }
            }
        }
        let actionRow = symbols ? 2 : 3
        let actionY = 3 + CGFloat(actionRow) * (keyHeight + verticalGap)
        shiftButton?.frame = CGRect(x: edge, y: actionY, width: sideWidth, height: keyHeight)
        deleteButton?.frame = CGRect(x: width - edge - sideWidth, y: actionY, width: sideWidth, height: keyHeight)
        if fontsChanged {
            let icon = UIImage.SymbolConfiguration(pointSize: font + 2, weight: .semibold)
            if symbols {
                shiftButton?.titleLabel?.font = .systemFont(ofSize: 16)
            } else {
                shiftButton?.setPreferredSymbolConfiguration(icon, forImageIn: .normal)
            }
            deleteButton?.setPreferredSymbolConfiguration(icon, forImageIn: .normal)
        }
        let weights: [CGFloat] = [120, 110, 100, 460, 100, 242]
        let available = width - 2 * edge - CGFloat(bottom.count - 1) * gap
        var x = edge
        let bottomY = 3 + CGFloat(symbols ? 3 : 4) * (keyHeight + verticalGap)
        for i in bottom.indices {
            let key = bottom[i], w = available * weights[i] / weights.reduce(0, +)
            key.frame = CGRect(x: x, y: bottomY, width: w, height: keyHeight)
            if fontsChanged {
                key.titleLabel?.font = .systemFont(ofSize: min(20, max(15, font * 0.82)))
                key.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: font + 3, weight: .regular), forImageIn: .normal)
            }
            x += w + gap
        }
        if fontsChanged { lastLayoutFont = font }
    }

    func updateShift(_ shifted: Bool, caps: Bool) {
        self.shifted = shifted
        for (rowIndex, row) in characterRows.enumerated() {
            for (column, button) in row.enumerated() {
                let value = values[rowIndex][column]
                button.setTitle(shifted && !symbols ? value.uppercased() : value, for: .normal)
            }
        }
        if symbols {
            shiftButton?.setImage(nil, for: .normal)
            shiftButton?.setTitle(symbolPage == 0 ? "#+=" : "123", for: .normal)
        } else {
            shiftButton?.setTitle("", for: .normal)
            shiftButton?.setImage(UIImage(systemName: caps ? "capslock.fill" : shifted ? "shift.fill" : "shift"), for: .normal)
        }
    }
    func setJapaneseMode(_ japanese: Bool) {
        spaceButton?.setTitle(japanese ? "日本語" : "space", for: .normal)
        spaceButton?.accessibilityLabel = japanese ? "日本語入力" : "スペース"
    }
    private var lastComposing: Bool?
    func setComposing(_ composing: Bool) {
        guard composing != lastComposing else { return }
        lastComposing = composing
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
    @objc private func returnHold(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { onAction?(.paste) }
    }
}
