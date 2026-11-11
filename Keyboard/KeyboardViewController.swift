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
        rebuildCanvas()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDelete()
        syncHostChange(); commitCurrent()
        editor.finish()
        resetComposition()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        let candidateHeight: CGFloat = isJapanese && !composition.isEmpty ? 34 : 0
        candidateScroll.isHidden = candidateHeight == 0
        candidateScroll.frame = CGRect(x: 0, y: 0, width: width, height: candidateHeight)
        let keysHeight = canvas.preferredHeight(width: width)
        canvas.frame = CGRect(x: 0, y: candidateHeight, width: width, height: keysHeight)
        let height = candidateHeight + keysHeight + view.safeAreaInsets.bottom
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
        let japanese = UIAction(title: "日本語入力", state: isJapanese ? .on : .off) { [weak self] _ in self?.setLanguage(true) }
        let english = UIAction(title: "English", state: isJapanese ? .off : .on) { [weak self] _ in self?.setLanguage(false) }
        let presetActions = settings.snapshot.phrases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { phrase in
            UIAction(title: phrase) { [weak self] _ in self?.insertPhrase(phrase) }
        }
        let phrases = presetActions.isEmpty
            ? [UIAction(title: "アプリで定型文を登録", attributes: .disabled) { _ in }]
            : presetActions
        button.menu = UIMenu(children: [
            UIMenu(options: .displayInline, children: [japanese, english]),
            UIMenu(options: .displayInline, children: phrases)
        ])
        button.showsMenuAsPrimaryAction = false
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
        case .space: space()
        case .enter:
            if composition.isEmpty { editor.insert("\n") }
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
        if isJapanese && roman && !symbols {
            if composition.input.count >= 96 { commitRaw() }
            composition.insertAtCursorPosition(text.lowercased(), inputStyle: .roman2kana)
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
