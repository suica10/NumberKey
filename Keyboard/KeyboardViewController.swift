import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let settings = KeyboardSettings()
    private let service = ConversionService()
    private var composition = ComposingText()
    private var candidates: [String] = []
    private var selected: Int?
    private var shifted = false
    private var capsLocked = false
    private var symbols = false
    private var configuring = false
    private var editingSlot = 0
    private var revision = 0
    private var conversionReady = false
    private var waitingSpaceCount = 0
    private var conversionTask: Task<Void, Never>?
    private var deleteTimer: Timer?
    private var heightConstraint: NSLayoutConstraint?
    private var documentID: UUID?
    private let content = UIStackView()
    private let compositionLabel = UILabel()
    private let candidateStack = UIStackView()
    private let rowStack = UIStackView()
    private let statusLabel = UILabel()
    private weak var enterButton: UIButton?
    private let alternatives: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        ".": "…", ",": "、", "-": "ー", "?": "？", "!": "！",
        "(": "「", ")": "」", "\"": "『", "'": "』", "/": "・"
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        documentID = textDocumentProxy.documentIdentifier
        content.axis = .vertical
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 350)
        height.priority = .init(999)
        height.isActive = true
        heightConstraint = height
        buildKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        documentID = textDocumentProxy.documentIdentifier
        buildKeyboard()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDelete()
        clearComposition()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if documentID != textDocumentProxy.documentIdentifier {
            documentID = textDocumentProxy.documentIdentifier
            clearComposition()
        }
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        // Composition is private to this keyboard until explicit confirmation.
        // Do not carry it into an externally edited or newly selected text field.
        if !composition.isEmpty { clearComposition() }
    }

    private var isJapanese: Bool { settings.japanese }

    private func clear(_ stack: UIStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func applyTheme() {
        overrideUserInterfaceStyle = settings.theme == 1 ? .light : settings.theme == 2 ? .dark : .unspecified
        view.backgroundColor = .secondarySystemBackground
    }

    private func buildKeyboard() {
        applyTheme()
        clear(content)
        clear(rowStack)
        if configuring { buildSettings(); return }
        let toolbar = UIStackView()
        toolbar.spacing = 5
        compositionLabel.font = .systemFont(ofSize: 17)
        compositionLabel.textColor = .label
        compositionLabel.lineBreakMode = .byTruncatingHead
        compositionLabel.accessibilityLabel = "未確定文字"
        toolbar.addArrangedSubview(compositionLabel)
        let cancel = button("取消", special: true) { [weak self] in self?.clearComposition() }
        cancel.widthAnchor.constraint(equalToConstant: 45).isActive = true
        toolbar.addArrangedSubview(cancel)
        let gear = button("⚙", special: true) { [weak self] in
            guard let self else { return }
            self.commitRaw()
            self.configuring = true
            self.buildKeyboard()
        }
        gear.accessibilityLabel = "キーボード設定"
        gear.widthAnchor.constraint(equalToConstant: 38).isActive = true
        toolbar.addArrangedSubview(gear)
        toolbar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        content.addArrangedSubview(toolbar)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.heightAnchor.constraint(equalToConstant: 37).isActive = true
        candidateStack.axis = .horizontal
        candidateStack.spacing = 5
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(candidateStack)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        content.addArrangedSubview(scroll)

        rowStack.axis = .vertical
        rowStack.spacing = 5
        content.addArrangedSubview(rowStack)
        addRow(settings.topKeys)
        if symbols {
            addRow(Array("!@#$%^&*()").map(String.init))
            addRow(Array("[]{}<>+=/").map(String.init))
            addRow(Array("_\\|~`：；").map(String.init), sideKeys: true)
        } else {
            addRow(Array("qwertyuiop").map(String.init))
            addRow(Array("asdfghjkl").map(String.init), inset: 14)
            addRow(Array("zxcvbnm").map(String.init), sideKeys: true)
        }
        addBottomRow()
        heightConstraint?.constant = 28 + 37 + settings.keyHeight * 5 + 5 * 4 + 4 * 4 + 8
        refreshComposition()
    }

    private func button(_ title: String, special: Bool = false, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .label
        config.baseBackgroundColor = special ? .tertiarySystemFill : .systemBackground
        config.cornerStyle = .fixed
        config.background.cornerRadius = 6
        config.contentInsets = .init(top: 2, leading: 2, bottom: 2, trailing: 2)
        b.configuration = config
        b.titleLabel?.font = .systemFont(ofSize: title.count > 2 ? 13 : 20)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.accessibilityLabel = title
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func key(_ text: String) -> UIButton {
        let display = shifted && !symbols ? text.uppercased() : text
        let b = button(display) { [weak self] in self?.insert(text) }
        b.accessibilityHint = alternatives[text].map { "長押しで\($0)" }
        b.accessibilityIdentifier = text
        if alternatives[text] != nil {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPressAlternative(_:)))
            gesture.minimumPressDuration = 0.4
            b.addGestureRecognizer(gesture)
        }
        return b
    }

    private func makeRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.heightAnchor.constraint(equalToConstant: settings.keyHeight).isActive = true
        rowStack.addArrangedSubview(row)
        return row
    }

    private func addRow(_ keys: [String], inset: CGFloat = 0, sideKeys: Bool = false) {
        let row = makeRow()
        if sideKeys {
            let shift = button(symbols ? "ABC" : (capsLocked ? "⇪" : shifted ? "⬆" : "⇧"), special: true) { [weak self] in
                guard let self else { return }
                if self.symbols { self.symbols = false }
                else { self.shifted.toggle(); self.capsLocked = false }
                self.buildKeyboard()
            }
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(lockCaps(_:)))
            doubleTap.numberOfTapsRequired = 2
            shift.addGestureRecognizer(doubleTap)
            shift.widthAnchor.constraint(equalToConstant: 37).isActive = true
            row.addArrangedSubview(shift)
        }
        if inset > 0 {
            let spacer = UIView()
            spacer.widthAnchor.constraint(equalToConstant: inset).isActive = true
            row.addArrangedSubview(spacer)
        }
        var previous: UIButton?
        for text in keys {
            let b = key(text)
            row.addArrangedSubview(b)
            if let previous { b.widthAnchor.constraint(equalTo: previous.widthAnchor).isActive = true }
            previous = b
        }
        if inset > 0 {
            let spacer = UIView()
            spacer.widthAnchor.constraint(equalToConstant: inset).isActive = true
            row.addArrangedSubview(spacer)
        }
        if sideKeys {
            let delete = button("⌫", special: true) { [weak self] in self?.backspace() }
            delete.accessibilityLabel = "削除"
            delete.widthAnchor.constraint(equalToConstant: 37).isActive = true
            delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:))))
            row.addArrangedSubview(delete)
        }
    }

    private func addBottomRow() {
        let row = makeRow()
        let globe = button("🌐", special: true) {}
        globe.accessibilityLabel = "次のキーボード"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.widthAnchor.constraint(equalToConstant: 32).isActive = true
        row.addArrangedSubview(globe)
        let mode = button(isJapanese ? "日本語" : "ABC", special: true) { [weak self] in
            guard let self else { return }
            self.commitRaw()
            self.settings.japanese = !self.isJapanese
            self.shifted = false
            self.capsLocked = false
            self.buildKeyboard()
        }
        mode.widthAnchor.constraint(equalToConstant: 46).isActive = true
        row.addArrangedSubview(mode)
        let sym = button(symbols ? "ABC" : "#+=", special: true) { [weak self] in
            guard let self else { return }
            self.symbols.toggle(); self.buildKeyboard()
        }
        sym.widthAnchor.constraint(equalToConstant: 36).isActive = true
        row.addArrangedSubview(sym)
        for text in [isJapanese ? "、" : ",", isJapanese ? "。" : "."] {
            let b = key(text)
            b.widthAnchor.constraint(equalToConstant: 25).isActive = true
            row.addArrangedSubview(b)
        }
        let space = button(isJapanese ? "変換 / 空白" : "space") { [weak self] in self?.space() }
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        row.addArrangedSubview(space)
        for (label, offset) in [("←", -1), ("→", 1)] {
            let b = button(label, special: true) { [weak self] in self?.moveCursor(offset) }
            b.widthAnchor.constraint(equalToConstant: 25).isActive = true
            row.addArrangedSubview(b)
        }
        let enter = button(composition.isEmpty ? "↵" : "確定", special: true) { [weak self] in self?.enter() }
        enter.accessibilityLabel = composition.isEmpty ? "改行" : "確定"
        enter.widthAnchor.constraint(equalToConstant: 38).isActive = true
        enterButton = enter
        row.addArrangedSubview(enter)
    }

    private func insert(_ text: String) {
        let roman = text.count == 1 && text.range(of: "^[a-z'-]$", options: .regularExpression) != nil
        if isJapanese && roman && !symbols {
            // Keep requests bounded for the extension's memory and latency limits.
            if composition.input.count >= 96 { commitRaw() }
            composition.insertAtCursorPosition(text.lowercased(), inputStyle: .roman2kana)
            selected = nil
            scheduleConversion()
        } else {
            commitCurrent()
            textDocumentProxy.insertText(shifted && !isJapanese ? text.uppercased() : text)
        }
        if shifted && !capsLocked { shifted = false; buildKeyboard() }
        else { refreshComposition() }
    }

    private func scheduleConversion() {
        revision += 1
        let requestRevision = revision
        let snapshot = composition
        conversionReady = false
        waitingSpaceCount = 0
        candidates = baseCandidates()
        conversionTask?.cancel()
        refreshComposition()
        guard !snapshot.isEmpty else { return }
        let service = service
        conversionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 55_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            let converted = await service.candidates(for: snapshot)
            guard !Task.isCancelled, let self, self.revision == requestRevision else { return }
            var seen = Set<String>()
            self.candidates = (converted + self.baseCandidates()).filter { seen.insert($0).inserted }
            self.conversionReady = true
            self.selected = self.waitingSpaceCount > 0 && !self.candidates.isEmpty
                ? (self.waitingSpaceCount - 1) % self.candidates.count : nil
            self.waitingSpaceCount = 0
            self.refreshComposition()
        }
    }

    private func baseCandidates() -> [String] {
        guard !composition.isEmpty else { return [] }
        let kana = composition.convertTarget
        let katakana = kana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? kana
        return kana == katakana ? [kana] : [kana, katakana]
    }

    private func refreshComposition() {
        enterButton?.configuration?.title = composition.isEmpty ? "↵" : "確定"
        enterButton?.accessibilityLabel = composition.isEmpty ? "改行" : "確定"
        let display = selected.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil }
            ?? composition.convertTarget
        let p = composition.convertTargetCursorPosition
        if selected == nil && !composition.isEmpty {
            compositionLabel.text = String(display.prefix(p)) + "│" + String(display.dropFirst(p))
        } else {
            compositionLabel.text = display.isEmpty ? (isJapanese ? "日本語 · ローマ字入力" : "English · QWERTY") : display
        }
        clear(candidateStack)
        for (index, value) in candidates.enumerated() {
            let b = button(value, special: selected == index) { [weak self] in self?.commit(value) }
            b.configuration?.contentInsets = .init(top: 2, leading: 12, bottom: 2, trailing: 12)
            candidateStack.addArrangedSubview(b)
        }
        if candidates.isEmpty {
            let hint = UILabel()
            hint.text = isJapanese ? "スペースで変換 ・ 候補をタップして確定" : "数字は最上段 ・ 長押しで記号"
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabel
            candidateStack.addArrangedSubview(hint)
        }
    }

    private func space() {
        guard !composition.isEmpty else { textDocumentProxy.insertText(" "); return }
        if !conversionReady {
            waitingSpaceCount += 1
            compositionLabel.text = composition.convertTarget + "  変換中…"
            return
        }
        if candidates.isEmpty { candidates = baseCandidates() }
        guard !candidates.isEmpty else { return }
        selected = selected.map { ($0 + 1) % candidates.count } ?? 0
        // Freeze the displayed list so a late request cannot change a chosen candidate.
        revision += 1
        conversionTask?.cancel()
        refreshComposition()
    }

    private func enter() {
        if composition.isEmpty { textDocumentProxy.insertText("\n") }
        else { commitCurrent() }
    }

    private func commitCurrent() {
        if let selected, candidates.indices.contains(selected) { commit(candidates[selected]) }
        else { commitRaw() }
    }

    private func commitRaw() {
        guard !composition.isEmpty else { return }
        var text = composition.convertTarget
        if text.hasSuffix("n") { text.removeLast(); text += "ん" }
        commit(text)
    }

    private func commit(_ text: String) {
        clearComposition()
        textDocumentProxy.insertText(text)
    }

    private func clearComposition() {
        revision += 1
        conversionTask?.cancel()
        composition = ComposingText()
        selected = nil
        candidates = []
        waitingSpaceCount = 0
        conversionReady = false
        if isViewLoaded && !configuring { refreshComposition() }
    }

    private func backspace() {
        if composition.isEmpty { textDocumentProxy.deleteBackward() }
        else {
            if selected != nil { selected = nil; refreshComposition(); return }
            composition.deleteBackwardFromCursorPosition(count: 1)
            scheduleConversion()
        }
    }

    private func moveCursor(_ offset: Int) {
        if composition.isEmpty { textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
        else {
            selected = nil
            _ = composition.moveCursorFromCursorPosition(count: offset)
            scheduleConversion()
        }
    }

    @objc private func longPressAlternative(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let id = gesture.view?.accessibilityIdentifier,
              let alternative = alternatives[id] else { return }
        commitCurrent()
        textDocumentProxy.insertText(alternative)
    }

    @objc private func lockCaps(_ gesture: UITapGestureRecognizer) {
        guard !symbols else { return }
        shifted = true; capsLocked = true; buildKeyboard()
    }

    @objc private func repeatDelete(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopDelete()
            backspace()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.backspace() }
            }
        case .ended, .cancelled, .failed: stopDelete()
        default: break
        }
    }

    private func stopDelete() { deleteTimer?.invalidate(); deleteTimer = nil }

    private func buildSettings() {
        let title = UILabel()
        title.text = "キーボード設定"
        title.font = .boldSystemFont(ofSize: 18)
        content.addArrangedSubview(title)
        let theme = UISegmentedControl(items: ["自動", "ライト", "ダーク"])
        theme.selectedSegmentIndex = settings.theme
        theme.addAction(UIAction { [weak self, weak theme] _ in
            guard let self, let theme else { return }
            self.settings.theme = theme.selectedSegmentIndex
            self.applyTheme()
        }, for: .valueChanged)
        content.addArrangedSubview(theme)
        statusLabel.text = "キーの高さ：\(Int(settings.keyHeight))"
        content.addArrangedSubview(statusLabel)
        let slider = UISlider()
        slider.minimumValue = 32; slider.maximumValue = 56; slider.value = Float(settings.keyHeight)
        slider.accessibilityLabel = "キーの高さ"
        slider.addAction(UIAction { [weak self, weak slider] _ in
            guard let self, let slider else { return }
            self.settings.keyHeight = CGFloat(slider.value.rounded())
            self.statusLabel.text = "キーの高さ：\(Int(self.settings.keyHeight))"
        }, for: .valueChanged)
        content.addArrangedSubview(slider)
        let hint = UILabel()
        hint.text = "最上段の位置を選び、下の文字を割り当て"
        hint.font = .systemFont(ofSize: 13)
        content.addArrangedSubview(hint)
        let slots = UIStackView()
        slots.distribution = .fillEqually; slots.spacing = 3
        for (i, key) in settings.topKeys.enumerated() {
            slots.addArrangedSubview(button(key, special: i == editingSlot) { [weak self] in
                guard let self else { return }
                self.editingSlot = i; self.buildKeyboard()
            })
        }
        content.addArrangedSubview(slots)
        for chars in ["1234567890", "!@#$%&*()-", "[]{}<>/+=_", "「」、。・？！〜："] {
            let palette = UIStackView()
            palette.spacing = 3; palette.distribution = .fillEqually
            for c in chars {
                let value = String(c)
                palette.addArrangedSubview(button(value) { [weak self] in
                    guard let self else { return }
                    var keys = self.settings.topKeys; keys[self.editingSlot] = value
                    self.settings.topKeys = keys; self.buildKeyboard()
                })
            }
            palette.heightAnchor.constraint(equalToConstant: 28).isActive = true
            content.addArrangedSubview(palette)
        }
        let actions = UIStackView()
        actions.spacing = 5; actions.distribution = .fillEqually
        actions.addArrangedSubview(button("数字列に戻す", special: true) { [weak self] in
            guard let self else { return }
            self.settings.topKeys = Array("1234567890").map(String.init); self.buildKeyboard()
        })
        actions.addArrangedSubview(button("完了", special: true) { [weak self] in
            guard let self else { return }
            self.configuring = false; self.buildKeyboard()
        })
        content.addArrangedSubview(actions)
        heightConstraint?.constant = 375
    }
}
