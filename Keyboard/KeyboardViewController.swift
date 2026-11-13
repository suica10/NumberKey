import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

private final class CandidateKey: UIButton {
    var onSelect: (() -> Void)?
    var renderedValue: String?
    var isSelectedCandidate: Bool?
    var actionRevision = -1

    @objc func activate() { onSelect?() }
}

@MainActor
final class KeyboardViewController: UIInputViewController {
    var settings = KeyboardSettings()
    var documentOverride: KeyboardDocument?
    private lazy var editor = MarkedTextSession { [unowned self] in
        self.documentOverride ?? ProxyDocument(self.textDocumentProxy)
    }
    private let service = ConversionService()
    private var composition = ComposingText()
    private var candidates: [String] = []
    private var selected: Int?
    private var shifted = false
    private var capsLocked = false
    private var symbols = false
    private var symbolPage = 0
    private var revision = 0
    private var conversionReady = false
    private var waitingSpaceCount = 0
    private var conversionTask: Task<Void, Never>?
    private var deleteTimer: Timer?
    private var heightConstraint: NSLayoutConstraint?
    private let canvas = KeyboardCanvas()
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private var candidateKeys: [CandidateKey] = []
    private var candidateStyleIsLight: Bool?
    // 定型文はキーボード拡張自身の保存領域で完結させる（PhraseStore 参照）。
    private lazy var phraseStore = PhraseStore(legacyPhrases: { KeyboardViewController.legacySharedPhrases() })
    private var captureDocument: BufferDocument?
    private var isCapturing: Bool { captureDocument != nil }
    private let capturePanel = UIView()
    private let captureTitle = UILabel()
    private let captureDisplay = UILabel()
    private let captureButtonRow = UIStackView()
    private let phrasePanel = UIView()
    private let phraseTitle = UILabel()
    private let phraseLanguageControl = UISegmentedControl(items: ["日本語", "English"])
    private let phraseCloseButton = UIButton(type: .system)
    private let phraseScroll = UIScrollView()
    private let phraseStack = UIStackView()
    private let phraseAddButton = UIButton(type: .system)
    private let phraseDeleteToggle = UIButton(type: .system)
    private var isPicking = false
    private var pickerDeleteMode = false
    private var pickerOpenedAt: Date?
    private var isJapanese: Bool { settings.japanese }

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardSettings.migrateLegacyExtensionPreferences()
        view.addSubview(candidateScroll)
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateStack.axis = .horizontal
        candidateStack.spacing = 8
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateStack)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor, constant: 6),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor, constant: -6),
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor)
        ])
        // 定型文の登録は、枠（パネル）の中で完結させる。タイトル・入力テキスト・
        // 保存/取消ボタンを1つの枠に入れ、「ここに入力する」ことが見て分かるようにする。
        capturePanel.isHidden = true
        capturePanel.layer.cornerRadius = 10
        capturePanel.layer.borderWidth = 1
        view.addSubview(capturePanel)
        captureTitle.text = "定型文を登録"
        captureTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        captureTitle.textColor = .secondaryLabel
        capturePanel.addSubview(captureTitle)
        captureDisplay.font = .systemFont(ofSize: 20)
        captureDisplay.numberOfLines = 0
        captureDisplay.lineBreakMode = .byWordWrapping
        capturePanel.addSubview(captureDisplay)
        captureButtonRow.axis = .horizontal
        captureButtonRow.spacing = 8
        captureButtonRow.alignment = .center
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.addAction(UIAction { [weak self] _ in self?.endCapture(save: false) }, for: .touchUpInside)
        let saveButton = UIButton(type: .system)
        saveButton.setTitle("保存", for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.addAction(UIAction { [weak self] _ in self?.endCapture(save: true) }, for: .touchUpInside)
        captureButtonRow.addArrangedSubview(spacer)
        captureButtonRow.addArrangedSubview(cancelButton)
        captureButtonRow.addArrangedSubview(saveButton)
        capturePanel.addSubview(captureButtonRow)
        // 定型文パネル（スペース長押し）。言語切替・定型文リスト・追加/削除を
        // 大きな枠の中に収める。システムメニューの小ささへの対策。
        phrasePanel.isHidden = true
        phrasePanel.layer.cornerRadius = 10
        phrasePanel.layer.borderWidth = 1
        view.addSubview(phrasePanel)
        phraseTitle.text = "定型文"
        phraseTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        phrasePanel.addSubview(phraseTitle)
        phraseLanguageControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setLanguage(self.phraseLanguageControl.selectedSegmentIndex == 0)
            self.hidePhrasePicker()
        }, for: .valueChanged)
        phrasePanel.addSubview(phraseLanguageControl)
        phraseCloseButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        phraseCloseButton.addAction(UIAction { [weak self] _ in self?.hidePhrasePicker() }, for: .touchUpInside)
        phrasePanel.addSubview(phraseCloseButton)
        phraseStack.axis = .vertical
        phraseStack.spacing = 6
        phraseStack.translatesAutoresizingMaskIntoConstraints = false
        phraseScroll.addSubview(phraseStack)
        NSLayoutConstraint.activate([
            phraseStack.leadingAnchor.constraint(equalTo: phraseScroll.contentLayoutGuide.leadingAnchor),
            phraseStack.trailingAnchor.constraint(equalTo: phraseScroll.contentLayoutGuide.trailingAnchor),
            phraseStack.topAnchor.constraint(equalTo: phraseScroll.contentLayoutGuide.topAnchor),
            phraseStack.bottomAnchor.constraint(equalTo: phraseScroll.contentLayoutGuide.bottomAnchor),
            phraseStack.widthAnchor.constraint(equalTo: phraseScroll.frameLayoutGuide.widthAnchor)
        ])
        phrasePanel.addSubview(phraseScroll)
        phraseAddButton.setTitle("＋ 定型文を追加", for: .normal)
        phraseAddButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        phraseAddButton.contentHorizontalAlignment = .left
        phraseAddButton.addAction(UIAction { [weak self] _ in self?.beginCapture() }, for: .touchUpInside)
        phrasePanel.addSubview(phraseAddButton)
        phraseDeleteToggle.setTitle("削除モード", for: .normal)
        phraseDeleteToggle.titleLabel?.font = .systemFont(ofSize: 16)
        phraseDeleteToggle.contentHorizontalAlignment = .right
        phraseDeleteToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pickerDeleteMode.toggle()
            self.rebuildPhraseRows()
        }, for: .touchUpInside)
        phrasePanel.addSubview(phraseDeleteToggle)
        view.addSubview(canvas)
        canvas.onText = { [weak self] in self?.insert($0) }
        canvas.onAction = { [weak self] in self?.handle($0) }
        canvas.onCaps = { [weak self] in
            guard let self else { return }
            self.shifted = true; self.capsLocked = true
            self.canvas.updateShift(true, caps: true)
        }
        canvas.onDeleteHold = { [weak self] in self?.repeatDelete($0) }
        canvas.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.setLanguage(!self.isJapanese)
            }, for: .touchUpInside)
            button.menu = UIMenu(children: [
                UIAction(title: "次のキーボードへ", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                    self?.advanceToNextInputMode()
                }
            ])
            button.showsMenuAsPrimaryAction = false
        }
        canvas.configureMenu = { [weak self] button in self?.configureMenu(button) }
        canvas.configureSpaceMenu = { [weak self] button in self?.configureSpaceMenu(button) }
        Task { await service.warmUp() }
        let height = view.heightAnchor.constraint(equalToConstant: 270)
        height.priority = .init(999); height.isActive = true; heightConstraint = height
        rebuildCanvas()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardSettings.migrateLegacyExtensionPreferences()
        settings = KeyboardSettings()
        rebuildCanvas()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isCapturing { endCapture(save: false) }
        stopDelete()
        syncHostChange(); commitCurrent()
        editor.finish()
        resetComposition()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        let keysHeight = canvas.preferredHeight(width: width)
        let candidateHeight: CGFloat = isJapanese && !composition.isEmpty ? 34 : 0
        // 登録中はキーボード全体を画面の約6割まで広げ、その大半を定型文の枠に充てる。
        // 完全な全画面は拡張の仕様上できないため、これが上限の目安。
        var capturePanelHeight: CGFloat = 0
        if isCapturing {
            let budget = UIScreen.main.bounds.height * 0.62
            capturePanelHeight = max(150, budget - candidateHeight - keysHeight - view.safeAreaInsets.bottom)
        }
        capturePanel.isHidden = !isCapturing
        if isCapturing {
            let isLight = traitCollection.userInterfaceStyle == .light
            capturePanel.backgroundColor = isLight ? UIColor(white: 0.97, alpha: 1) : UIColor(white: 0.24, alpha: 1)
            capturePanel.layer.borderColor = (isLight ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.42, alpha: 1)).cgColor
            capturePanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, capturePanelHeight - 12))
            let panelWidth = capturePanel.bounds.width
            let panelHeight = capturePanel.bounds.height
            captureTitle.frame = CGRect(x: 12, y: 8, width: max(0, panelWidth - 24), height: 18)
            captureButtonRow.frame = CGRect(x: 12, y: max(30, panelHeight - 50), width: max(0, panelWidth - 24), height: 42)
            captureDisplay.frame = CGRect(x: 12, y: 30, width: max(0, panelWidth - 24), height: max(0, panelHeight - 30 - 56))
        }
        var phrasePanelHeight: CGFloat = 0
        if isPicking && !isCapturing {
            let budget = UIScreen.main.bounds.height * 0.62
            phrasePanelHeight = max(200, budget - candidateHeight - keysHeight - view.safeAreaInsets.bottom)
        }
        phrasePanel.isHidden = !isPicking
        if isPicking && !isCapturing {
            let isLight = traitCollection.userInterfaceStyle == .light
            phrasePanel.backgroundColor = isLight ? UIColor(white: 0.97, alpha: 1) : UIColor(white: 0.24, alpha: 1)
            phrasePanel.layer.borderColor = (isLight ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.42, alpha: 1)).cgColor
            phrasePanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, phrasePanelHeight - 12))
            let panelWidth = phrasePanel.bounds.width
            let panelHeight = phrasePanel.bounds.height
            phraseTitle.frame = CGRect(x: 12, y: 10, width: 70, height: 28)
            phraseLanguageControl.frame = CGRect(x: 88, y: 8, width: 170, height: 32)
            phraseCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            phraseScroll.frame = CGRect(x: 8, y: 48, width: max(0, panelWidth - 16), height: max(0, panelHeight - 48 - 50))
            phraseAddButton.frame = CGRect(x: 12, y: max(0, panelHeight - 46), width: 160, height: 38)
            phraseDeleteToggle.frame = CGRect(x: max(0, panelWidth - 172), y: max(0, panelHeight - 46), width: 160, height: 38)
        }
        let topHeight = capturePanelHeight + phrasePanelHeight
        candidateScroll.isHidden = candidateHeight == 0
        candidateScroll.frame = CGRect(x: 0, y: topHeight, width: width, height: candidateHeight)
        canvas.frame = CGRect(x: 0, y: topHeight + candidateHeight, width: width, height: keysHeight)
        let height = topHeight + candidateHeight + keysHeight + view.safeAreaInsets.bottom
        if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncHostChange()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        syncHostChange()
    }
    private func syncHostChange() {
        if editor.hostDidChange() { resetComposition() }
    }
    private func rebuildCanvas() {
        let snapshot = settings.snapshot
        overrideUserInterfaceStyle = snapshot.theme == 1 ? .light : snapshot.theme == 2 ? .dark : .unspecified
        view.backgroundColor = traitCollection.userInterfaceStyle == .light ? UIColor(white: 0.82, alpha: 1) : UIColor(white: 0.17, alpha: 1)
        canvas.configure(snapshot, shifted: shifted, symbols: symbols, symbolPage: symbolPage, japanese: isJapanese)
        canvas.setJapaneseMode(isJapanese)
        canvas.updateShift(shifted, caps: capsLocked)
        renderState(updateMarked: false)
        view.setNeedsLayout()
    }
    private func configureMenu(_ button: UIButton) {
        let left = UIAction(title: "カーソルを左へ", image: UIImage(systemName: "arrow.left")) { [weak self] _ in self?.moveCursor(-1) }
        let right = UIAction(title: "カーソルを右へ", image: UIImage(systemName: "arrow.right")) { [weak self] _ in self?.moveCursor(1) }
        button.menu = UIMenu(children: [UIMenu(options: .displayInline, children: [left, right])])
    }
    private func configureSpaceMenu(_ button: UIButton) {
        // システムのUIMenuは小さくて長い定型文が読めないため、長押しでは
        // 自前の大きな定型文パネルを開く（旧updateSpaceMenuは置き換え）。
        button.menu = nil
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(spaceLongPressed(_:)))
        hold.minimumPressDuration = 0.35
        button.addGestureRecognizer(hold)
    }
    @objc private func spaceLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !isCapturing else { return }
        pickerOpenedAt = Date()
        showPhrasePicker()
    }
    private func showPhrasePicker() {
        phraseStore.reload()
        pickerDeleteMode = false
        isPicking = true
        phraseLanguageControl.selectedSegmentIndex = isJapanese ? 0 : 1
        rebuildPhraseRows()
        view.setNeedsLayout()
    }
    private func hidePhrasePicker() {
        guard isPicking else { return }
        isPicking = false
        view.setNeedsLayout()
    }
    private func rebuildPhraseRows() {
        for arranged in phraseStack.arrangedSubviews {
            phraseStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        let isLight = traitCollection.userInterfaceStyle == .light
        let phrases = phraseStore.phrases
        if phrases.isEmpty {
            let label = UILabel()
            label.text = "定型文はまだありません"
            label.font = .systemFont(ofSize: 15)
            label.textColor = .secondaryLabel
            phraseStack.addArrangedSubview(label)
        }
        for (index, phrase) in phrases.enumerated() {
            let row = UIButton(type: .system)
            row.contentHorizontalAlignment = .left
            row.titleLabel?.numberOfLines = 3
            row.titleLabel?.font = .systemFont(ofSize: 18)
            row.titleLabel?.lineBreakMode = .byTruncatingTail
            row.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            row.layer.cornerRadius = 8
            row.backgroundColor = isLight ? .white : UIColor(white: 0.32, alpha: 1)
            row.setTitle(pickerDeleteMode ? "✕ " + phrase : phrase, for: .normal)
            row.setTitleColor(pickerDeleteMode ? .systemRed : (isLight ? .black : .white), for: .normal)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            row.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if self.pickerDeleteMode {
                    self.phraseStore.remove(at: index)
                    self.rebuildPhraseRows()
                } else {
                    self.hidePhrasePicker()
                    self.insertPhrase(phrase)
                }
            }, for: .touchUpInside)
            phraseStack.addArrangedSubview(row)
        }
        phraseDeleteToggle.setTitle(pickerDeleteMode ? "削除モード中" : "削除モード", for: .normal)
        phraseDeleteToggle.setTitleColor(pickerDeleteMode ? .systemRed : nil, for: .normal)
    }
    /// 旧実装（共有 LayoutSettings）から定型文を一度だけ引き継ぐための読み出し。
    private static func legacySharedPhrases() -> [String]? {
        struct LegacyLayout: Decodable { var phrases: [String]? }
        var sources: [UserDefaults] = []
        if let suite = UserDefaults(suiteName: KeyboardSettings.appGroupIdentifier) { sources.append(suite) }
        sources.append(.standard)
        for source in sources {
            if let data = source.data(forKey: "layout.v1"),
               let legacy = try? JSONDecoder().decode(LegacyLayout.self, from: data),
               let phrases = legacy.phrases { return phrases }
        }
        return nil
    }
    private func beginCapture() {
        guard !isCapturing else { return }
        hidePhrasePicker()
        syncHostChange(); commitCurrent()
        let document = BufferDocument()
        document.onChange = { [weak self] text in
            guard let self else { return }
            self.captureDisplay.text = text.isEmpty ? "ここに定型文を入力" : text
            self.captureDisplay.textColor = text.isEmpty ? .placeholderText
                : (self.traitCollection.userInterfaceStyle == .light ? .black : .white)
        }
        captureDocument = document
        documentOverride = document
        captureDisplay.text = "ここに定型文を入力"
        captureDisplay.textColor = .placeholderText
        updateCaptureStrip()
        view.setNeedsLayout()
    }
    private func endCapture(save: Bool) {
        guard let document = captureDocument else { return }
        if save {
            commitCurrent()
            let text = document.text
            if !phraseStore.add(text) {
                let truncated = String(text.prefix(PhraseBook.maxLength))
                if truncated != text, phraseStore.add(truncated) {
                    let alert = UIAlertController(title: "定型文を保存しました",
                                                  message: "100文字を超えたため、先頭100文字で保存しました。",
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    present(alert, animated: true)
                }
            }
        } else {
            resetComposition()
        }
        captureDocument = nil
        documentOverride = nil
        updateCaptureStrip()
        view.setNeedsLayout()
    }
    private func updateCaptureStrip() {
        capturePanel.isHidden = !isCapturing
    }
    @discardableResult
    func applyLayoutString(_ text: String) -> Bool {
        guard let snapshot = LayoutSettings.decode(text) else { return false }
        syncHostChange(); commitCurrent()
        settings.apply(snapshot)
        shifted = false; capsLocked = false; symbols = false; symbolPage = 0
        if isViewLoaded { rebuildCanvas() }
        return true
    }
    private func showImportError() {
        let alert = UIAlertController(title: "配置を読み込めませんでした",
                                      message: "NumberKeyアプリで配置をコピーしてから、もう一度読み込んでください。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    private func insertPhrase(_ phrase: String) {
        syncHostChange(); commitCurrent()
        editor.insert(phrase)
    }

    private func setLanguage(_ japanese: Bool) {
        guard settings.japanese != japanese else { return }
        syncHostChange(); commitCurrent()
        settings.japanese = japanese
        shifted = false; capsLocked = false; symbols = false; symbolPage = 0
        rebuildCanvas()
    }
    private func handle(_ action: KeyboardAction) {
        syncHostChange()
        switch action {
        case .shift:
            if symbols { symbols = false; rebuildCanvas() }
            else { shifted.toggle(); capsLocked = false; canvas.updateShift(shifted, caps: false) }
        case .delete: backspace()
        case .symbols:
            symbols.toggle(); symbolPage = 0; rebuildCanvas()
        case .symbolPage:
            guard symbols else { return }
            symbolPage = symbolPage == 0 ? 1 : 0
            rebuildCanvas()
        case .space:
            // 長押しで定型文パネルを開いた直後の離しタップは、スペースとして扱わない。
            if isPicking { hidePhrasePicker() }
            else if let opened = pickerOpenedAt, Date().timeIntervalSince(opened) < 0.6 { }
            else { space() }
        case .enter:
            if isCapturing && composition.isEmpty { endCapture(save: true) }
            else if composition.isEmpty { editor.insert("\n") }
            else { commitCurrent() }
        case .paste: pasteFromClipboard()
        }
    }
    private func pasteFromClipboard() {
        syncHostChange()
        guard hasFullAccess else {
            let alert = UIAlertController(
                title: "ペーストにはフルアクセスが必要です",
                message: "設定 → 一般 → キーボード → NumberKeyで「フルアクセスを許可」をオンにしてください。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        commitCurrent()
        editor.insert(text)
    }
    private func insert(_ text: String) {
        syncHostChange()
        let roman = text.count == 1 && text.range(of: "^[a-zA-Z']$", options: .regularExpression) != nil
        let isRomanInput = roman && !symbols
        if isJapanese && (isRomanInput || !composition.isEmpty) {
            if composition.input.count >= 96 { commitRaw() }
            let inputText = isRomanInput ? text.lowercased() : japaneseFullWidth(text)
            composition.insertAtCursorPosition(inputText, inputStyle: isRomanInput ? .roman2kana : .direct)
            selected = nil
            scheduleConversion()
        } else {
            commitCurrent()
            let committedText = isJapanese && symbols ? japaneseFullWidth(text) : text
            editor.insert(shifted && !isJapanese ? text.uppercased() : committedText)
        }
        if shifted && !capsLocked { shifted = false; canvas.updateShift(false, caps: false) }
    }
    private func scheduleConversion() {
        revision += 1
        let requestRevision = revision, snapshot = composition
        conversionReady = false; waitingSpaceCount = 0; selected = nil
        candidates = baseCandidates()
        conversionTask?.cancel()
        renderState()
        guard !snapshot.isEmpty else { return }
        let service = service
        conversionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await service.candidates(for: snapshot)
            guard !Task.isCancelled, let self, self.revision == requestRevision else { return }
            self.syncHostChange()
            guard self.revision == requestRevision else { return }
            var seen = Set<String>()
            self.candidates = (result + self.baseCandidates()).filter { seen.insert($0).inserted }
            self.conversionReady = true
            self.selected = self.waitingSpaceCount > 0 && !self.candidates.isEmpty ? (self.waitingSpaceCount - 1) % self.candidates.count : nil
            self.waitingSpaceCount = 0
            self.renderState()
        }
    }
    private func baseCandidates() -> [String] {
        guard !composition.isEmpty else { return [] }
        let kana = composition.convertTarget
        let katakana = kana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? kana
        return kana == katakana ? [kana] : [kana, katakana]
    }
    private func renderState(updateMarked: Bool = true) {
        if updateMarked {
            let display = selected.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil } ?? composition.convertTarget
            let caret = selected == nil ? String(display.prefix(composition.convertTargetCursorPosition)).utf16.count : display.utf16.count
            editor.show(display, caret: caret)
        }
        canvas.setComposing(!composition.isEmpty)
        let shouldHideCandidates = !isJapanese || composition.isEmpty
        if candidateScroll.isHidden != shouldHideCandidates { view.setNeedsLayout() }
        while candidateKeys.count > candidates.count {
            let key = candidateKeys.removeLast()
            candidateStack.removeArrangedSubview(key)
            key.removeFromSuperview()
        }
        while candidateKeys.count < candidates.count {
            let key = CandidateKey(type: .system)
            key.titleLabel?.font = .systemFont(ofSize: 17)
            key.setTitleColor(traitCollection.userInterfaceStyle == .light ? .black : .white, for: .normal)
            key.contentEdgeInsets = .init(top: 0, left: 10, bottom: 0, right: 10)
            key.layer.cornerRadius = 4
            key.addTarget(key, action: #selector(CandidateKey.activate), for: .touchUpInside)
            candidateKeys.append(key)
            candidateStack.addArrangedSubview(key)
        }
        let isLight = traitCollection.userInterfaceStyle == .light
        if candidateStyleIsLight != isLight {
            candidateKeys.forEach { $0.setTitleColor(isLight ? .black : .white, for: .normal) }
            candidateStyleIsLight = isLight
        }
        let displayedRevision = revision
        for (index, key) in candidateKeys.enumerated() {
            let value = candidates[index]
            let valueChanged = key.renderedValue != value
            if valueChanged {
                key.setTitle(value, for: .normal)
                key.accessibilityIdentifier = "candidate." + value
                key.renderedValue = value
            }
            let isSelected = selected == index
            if key.isSelectedCandidate != isSelected {
                key.backgroundColor = isSelected ? UIColor(white: 0.45, alpha: 0.6) : .clear
                key.isSelectedCandidate = isSelected
            }
            if key.actionRevision != displayedRevision || valueChanged {
                key.onSelect = { [weak self] in
                    guard let self else { return }
                    self.syncHostChange()
                    guard self.revision == displayedRevision else { return }
                    self.commit(value, learn: true)
                }
                key.actionRevision = displayedRevision
            }
        }
    }
    private func space() {
        guard !composition.isEmpty else { editor.insert(" "); return }
        guard conversionReady else { waitingSpaceCount += 1; return }
        guard !candidates.isEmpty else { return }
        selected = selected.map { ($0 + 1) % candidates.count } ?? 0
        revision += 1; conversionTask?.cancel()
        renderState()
    }
    private func commitCurrent() {
        guard !composition.isEmpty else { return }
        if let selected, candidates.indices.contains(selected) { commit(candidates[selected], learn: true) }
        else { commitRaw() }
    }
    private func commitRaw() {
        guard !composition.isEmpty else { return }
        var text = composition.convertTarget
        if text.hasSuffix("n") { text.removeLast(); text += "ん" }
        commit(text)
    }
    private func commit(_ text: String, learn: Bool = false) {
        if learn { Task { await service.learn(text) } }
        editor.commit(text)
        resetComposition()
    }
    private func resetComposition() {
        revision += 1; conversionTask?.cancel()
        composition = ComposingText(); candidates = []; selected = nil
        conversionReady = false; waitingSpaceCount = 0
        if isViewLoaded { renderState(updateMarked: false) }
    }
    private func backspace() {
        if composition.isEmpty { editor.deleteBackward() }
        else if selected != nil { selected = nil; renderState() }
        else { composition.deleteBackwardFromCursorPosition(count: 1); scheduleConversion() }
    }
    private func moveCursor(_ offset: Int) {
        syncHostChange()
        if composition.isEmpty { editor.move(offset) }
        else { selected = nil; _ = composition.moveCursorFromCursorPosition(count: offset); scheduleConversion() }
    }
    private func repeatDelete(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopDelete(); backspace()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncHostChange(); self?.backspace() }
            }
        case .ended, .cancelled, .failed: stopDelete()
        default: break
        }
    }
    private func stopDelete() { deleteTimer?.invalidate(); deleteTimer = nil }
}
