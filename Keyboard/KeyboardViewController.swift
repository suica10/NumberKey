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
    private let clipboardStore = ClipboardHistoryStore()
    private var englishLexicon: EnglishLexicon?
    private var englishSuggestions: [String] = []
    private var englishExtraValues: Set<String> = []
    private var pendingAutocorrectUndo: (original: String, corrected: String, delimiter: String)?
    private var activeDocument: KeyboardDocument { documentOverride ?? ProxyDocument(textDocumentProxy) }
    private var showsCandidateStrip: Bool {
        isJapanese ? !composition.isEmpty : (!symbols && !englishSuggestions.isEmpty)
    }
    private var captureDocument: BufferDocument?
    private var isCapturing: Bool { captureDocument != nil }
    private let capturePanel = UIView()
    private let captureTitle = UILabel()
    private let captureDisplay = UILabel()
    private let captureButtonRow = UIStackView()
    private let phrasePanel = UIView()
    private let phraseTitle = UILabel()
    private let phraseCloseButton = UIButton(type: .system)
    private let phraseScroll = UIScrollView()
    private let phraseStack = UIStackView()
    private let phraseAddButton = UIButton(type: .system)
    private let phraseReorderToggle = UIButton(type: .system)
    private var isPicking = false
    private var pickerReorderMode = false
    private weak var openPhraseRow: PhraseRowView?
    private var pickerOpenedAt: Date?
    private let clipboardPanel = UIView()
    private let clipboardTitle = UILabel()
    private let clipboardCloseButton = UIButton(type: .system)
    private let clipboardScroll = UIScrollView()
    private let emojiPanel = UIView()
    private let emojiTitle = UILabel()
    private let emojiCloseButton = UIButton(type: .system)
    private let emojiCategoryScroll = UIScrollView()
    private let emojiCategoryStack = UIStackView()
    private let emojiScroll = UIScrollView()
    private let emojiStack = UIStackView()
    private var isEmojiPicking = false
    private var emojiCategories: [EmojiCatalog.Category] = []
    private var emojiCategoryIndex = 0
    private var emojiCategoryButtons: [UIButton] = []
    private let recentEmojiStore = RecentEmojiStore()
    private var emojiPanelOpenedAt: Date?
    private var lastStripValues: [String] = []
    private let clipboardStack = UIStackView()
    private let clipboardClearButton = UIButton(type: .system)
    private var isClipboardPicking = false
    private weak var openClipboardRow: PhraseRowView?
    private var isJapanese: Bool { settings.japanese }

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardSettings.migrateLegacyExtensionPreferences()
        // 英単語リスト（約1MB）の読み込みは起動処理を止めないよう非同期で行う。
        // 起動が重いとアップデート直後の初回表示で iOS に見限られ、代わりに
        // システムキーボードが出てしまうことがある。
        Task.detached(priority: .utility) { [weak self] in
            let loaded = EnglishLexicon.loadBundled()
            await MainActor.run { self?.englishLexicon = loaded }
        }
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
        let pasteButton = UIButton(type: .system)
        pasteButton.setTitle("貼り付け", for: .normal)
        pasteButton.titleLabel?.font = .systemFont(ofSize: 17)
        pasteButton.addAction(UIAction { [weak self] _ in self?.pasteIntoCapture() }, for: .touchUpInside)
        captureButtonRow.addArrangedSubview(pasteButton)
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
        phraseReorderToggle.setTitle("並び替え", for: .normal)
        phraseReorderToggle.titleLabel?.font = .systemFont(ofSize: 16)
        phraseReorderToggle.contentHorizontalAlignment = .right
        phraseReorderToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pickerReorderMode.toggle()
            self.rebuildPhraseRows()
        }, for: .touchUpInside)
        phrasePanel.addSubview(phraseReorderToggle)
        // クリップボード履歴パネル（リターン長押し）。定型文パネルと同じ作り。
        clipboardPanel.isHidden = true
        clipboardPanel.layer.cornerRadius = 10
        clipboardPanel.layer.borderWidth = 1
        view.addSubview(clipboardPanel)
        clipboardTitle.text = "クリップボード"
        clipboardTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        clipboardPanel.addSubview(clipboardTitle)
        clipboardCloseButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clipboardCloseButton.addAction(UIAction { [weak self] _ in self?.hideClipboardPanel() }, for: .touchUpInside)
        clipboardPanel.addSubview(clipboardCloseButton)
        clipboardStack.axis = .vertical
        clipboardStack.spacing = 6
        clipboardStack.translatesAutoresizingMaskIntoConstraints = false
        clipboardScroll.addSubview(clipboardStack)
        NSLayoutConstraint.activate([
            clipboardStack.leadingAnchor.constraint(equalTo: clipboardScroll.contentLayoutGuide.leadingAnchor),
            clipboardStack.trailingAnchor.constraint(equalTo: clipboardScroll.contentLayoutGuide.trailingAnchor),
            clipboardStack.topAnchor.constraint(equalTo: clipboardScroll.contentLayoutGuide.topAnchor),
            clipboardStack.bottomAnchor.constraint(equalTo: clipboardScroll.contentLayoutGuide.bottomAnchor),
            clipboardStack.widthAnchor.constraint(equalTo: clipboardScroll.frameLayoutGuide.widthAnchor)
        ])
        clipboardPanel.addSubview(clipboardScroll)
        clipboardClearButton.setTitle("全削除", for: .normal)
        clipboardClearButton.titleLabel?.font = .systemFont(ofSize: 16)
        clipboardClearButton.setTitleColor(.systemRed, for: .normal)
        clipboardClearButton.contentHorizontalAlignment = .right
        clipboardClearButton.addAction(UIAction { [weak self] _ in
            self?.clipboardStore.clear()
            self?.rebuildClipboardRows()
        }, for: .touchUpInside)
        clipboardPanel.addSubview(clipboardClearButton)
        // 絵文字パネル（地球儀キーの長押しメニュー）。他のパネルと同じ作り。
        emojiPanel.isHidden = true
        emojiPanel.layer.cornerRadius = 10
        emojiPanel.layer.borderWidth = 1
        view.addSubview(emojiPanel)
        emojiTitle.text = "絵文字"
        emojiTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emojiPanel.addSubview(emojiTitle)
        emojiCloseButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        emojiCloseButton.addAction(UIAction { [weak self] _ in self?.hideEmojiPanel() }, for: .touchUpInside)
        emojiPanel.addSubview(emojiCloseButton)
        emojiCategoryStack.axis = .horizontal
        emojiCategoryStack.spacing = 4
        emojiCategoryStack.translatesAutoresizingMaskIntoConstraints = false
        emojiCategoryScroll.addSubview(emojiCategoryStack)
        NSLayoutConstraint.activate([
            emojiCategoryStack.leadingAnchor.constraint(equalTo: emojiCategoryScroll.contentLayoutGuide.leadingAnchor),
            emojiCategoryStack.trailingAnchor.constraint(equalTo: emojiCategoryScroll.contentLayoutGuide.trailingAnchor),
            emojiCategoryStack.topAnchor.constraint(equalTo: emojiCategoryScroll.contentLayoutGuide.topAnchor),
            emojiCategoryStack.bottomAnchor.constraint(equalTo: emojiCategoryScroll.contentLayoutGuide.bottomAnchor),
            emojiCategoryStack.heightAnchor.constraint(equalTo: emojiCategoryScroll.frameLayoutGuide.heightAnchor)
        ])
        emojiPanel.addSubview(emojiCategoryScroll)
        emojiStack.axis = .vertical
        emojiStack.spacing = 2
        emojiStack.translatesAutoresizingMaskIntoConstraints = false
        emojiScroll.addSubview(emojiStack)
        NSLayoutConstraint.activate([
            emojiStack.leadingAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.leadingAnchor),
            emojiStack.trailingAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.trailingAnchor),
            emojiStack.topAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.topAnchor),
            emojiStack.bottomAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.bottomAnchor),
            emojiStack.widthAnchor.constraint(equalTo: emojiScroll.frameLayoutGuide.widthAnchor)
        ])
        emojiPanel.addSubview(emojiScroll)
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
                // 長押しで絵文字パネルが開いた直後のタップは言語切替にしない。
                if let openedAt = self.emojiPanelOpenedAt, Date().timeIntervalSince(openedAt) < 0.6 { return }
                self.setLanguage(!self.isJapanese)
            }, for: .touchUpInside)
            // 地球儀の長押しはメニュー経由でなく直接絵文字パネルを開く。
            // 「次のキーボード」は One Keyboard のコンセプトとして持たない。
            if button.gestureRecognizers?.contains(where: { $0.name == "emojiPanel" }) != true {
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(globeLongPressed(_:)))
                hold.minimumPressDuration = 0.35
                hold.name = "emojiPanel"
                button.addGestureRecognizer(hold)
            }
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
        let candidateHeight: CGFloat = showsCandidateStrip ? 34 : 0
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
            phraseTitle.frame = CGRect(x: 12, y: 10, width: 200, height: 28)
            phraseCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            phraseScroll.frame = CGRect(x: 8, y: 48, width: max(0, panelWidth - 16), height: max(0, panelHeight - 48 - 50))
            phraseAddButton.frame = CGRect(x: 12, y: max(0, panelHeight - 46), width: 160, height: 38)
            phraseReorderToggle.frame = CGRect(x: max(0, panelWidth - 142), y: max(0, panelHeight - 46), width: 130, height: 38)
        }
        var clipboardPanelHeight: CGFloat = 0
        if isClipboardPicking && !isCapturing && !isPicking {
            let budget = UIScreen.main.bounds.height * 0.62
            clipboardPanelHeight = max(200, budget - candidateHeight - keysHeight - view.safeAreaInsets.bottom)
        }
        clipboardPanel.isHidden = !isClipboardPicking
        if isClipboardPicking && !isCapturing && !isPicking {
            let isLight = traitCollection.userInterfaceStyle == .light
            clipboardPanel.backgroundColor = isLight ? UIColor(white: 0.97, alpha: 1) : UIColor(white: 0.24, alpha: 1)
            clipboardPanel.layer.borderColor = (isLight ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.42, alpha: 1)).cgColor
            clipboardPanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, clipboardPanelHeight - 12))
            let panelWidth = clipboardPanel.bounds.width
            let panelHeight = clipboardPanel.bounds.height
            clipboardTitle.frame = CGRect(x: 12, y: 10, width: 200, height: 28)
            clipboardCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            clipboardScroll.frame = CGRect(x: 8, y: 48, width: max(0, panelWidth - 16), height: max(0, panelHeight - 48 - 50))
            clipboardClearButton.frame = CGRect(x: max(0, panelWidth - 112), y: max(0, panelHeight - 46), width: 100, height: 38)
        }
        var emojiPanelHeight: CGFloat = 0
        if isEmojiPicking && !isCapturing && !isPicking && !isClipboardPicking {
            let budget = UIScreen.main.bounds.height * 0.62
            emojiPanelHeight = max(200, budget - candidateHeight - keysHeight - view.safeAreaInsets.bottom)
        }
        emojiPanel.isHidden = !isEmojiPicking
        if isEmojiPicking && !isCapturing && !isPicking && !isClipboardPicking {
            let isLight = traitCollection.userInterfaceStyle == .light
            emojiPanel.backgroundColor = isLight ? UIColor(white: 0.97, alpha: 1) : UIColor(white: 0.24, alpha: 1)
            emojiPanel.layer.borderColor = (isLight ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.42, alpha: 1)).cgColor
            emojiPanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, emojiPanelHeight - 12))
            let panelWidth = emojiPanel.bounds.width
            let panelHeight = emojiPanel.bounds.height
            emojiTitle.frame = CGRect(x: 12, y: 10, width: 200, height: 28)
            emojiCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            emojiCategoryScroll.frame = CGRect(x: 8, y: 44, width: max(0, panelWidth - 16), height: 36)
            emojiScroll.frame = CGRect(x: 8, y: 86, width: max(0, panelWidth - 16), height: max(0, panelHeight - 86 - 8))
        }
        let topHeight = capturePanelHeight + phrasePanelHeight + clipboardPanelHeight + emojiPanelHeight
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
    @objc private func globeLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !isCapturing else { return }
        emojiPanelOpenedAt = Date()
        showEmojiPanel()
    }
    private func showPhrasePicker() {
        hideClipboardPanel()
        phraseStore.reload()
        pickerReorderMode = false
        isPicking = true
        rebuildPhraseRows()
        view.setNeedsLayout()
    }
    private func hidePhrasePicker() {
        guard isPicking else { return }
        isPicking = false
        view.setNeedsLayout()
    }
    private static let clipboardChangeCountKey = "clipboard.lastChangeCount"
    /// クリップボードに新しい文字列があれば履歴の先頭に取り込む。
    /// changeCount が変わったときだけ中身を読む（無駄な読み取りをしない）。
    private func captureClipboard() {
        guard hasFullAccess else { return }
        let pasteboard = UIPasteboard.general
        let last = UserDefaults.standard.integer(forKey: Self.clipboardChangeCountKey)
        guard pasteboard.changeCount != last else { return }
        UserDefaults.standard.set(pasteboard.changeCount, forKey: Self.clipboardChangeCountKey)
        if let text = pasteboard.string { clipboardStore.record(text) }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureClipboard()
    }
    private func showClipboardPanel() {
        captureClipboard()
        hidePhrasePicker()
        isClipboardPicking = true
        rebuildClipboardRows()
        view.setNeedsLayout()
    }
    private func hideClipboardPanel() {
        guard isClipboardPicking else { return }
        isClipboardPicking = false
        view.setNeedsLayout()
    }
    private func showEmojiPanel() {
        guard !isCapturing else { return }
        hidePhrasePicker()
        hideClipboardPanel()
        if emojiCategories.isEmpty { emojiCategories = EmojiCatalog.loadBundled() }
        if recentEmojiStore.items.isEmpty { emojiCategoryIndex = 1 }
        isEmojiPicking = true
        rebuildEmojiCategories()
        rebuildEmojiGrid()
        view.setNeedsLayout()
    }
    private func hideEmojiPanel() {
        guard isEmojiPicking else { return }
        isEmojiPicking = false
        view.setNeedsLayout()
    }
    private func rebuildEmojiCategories() {
        emojiCategoryButtons.forEach { $0.removeFromSuperview() }
        emojiCategoryButtons = []
        for (index, name) in (["最近"] + emojiCategories.map { $0.name }).enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(name, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: index == emojiCategoryIndex ? .bold : .regular)
            button.contentEdgeInsets = .init(top: 4, left: 10, bottom: 4, right: 10)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.emojiCategoryIndex = index
                self.rebuildEmojiCategories()
                self.rebuildEmojiGrid()
            }, for: .touchUpInside)
            emojiCategoryStack.addArrangedSubview(button)
            emojiCategoryButtons.append(button)
        }
    }
    private func rebuildEmojiGrid() {
        emojiStack.arrangedSubviews.forEach { emojiStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let emojis = emojiCategoryIndex == 0 ? recentEmojiStore.items
            : (emojiCategories.indices.contains(emojiCategoryIndex - 1) ? emojiCategories[emojiCategoryIndex - 1].emojis : [])
        if emojis.isEmpty {
            let label = UILabel()
            label.text = emojiCategoryIndex == 0 ? "まだ絵文字を使っていません" : "絵文字がありません"
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabel
            emojiStack.addArrangedSubview(label)
            return
        }
        let columns = 8
        for start in stride(from: 0, to: emojis.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 2
            let slice = emojis[start..<min(start + columns, emojis.count)]
            for emoji in slice {
                let button = UIButton(type: .system)
                button.setTitle(emoji, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 30)
                button.heightAnchor.constraint(equalToConstant: 46).isActive = true
                button.addAction(UIAction { [weak self] _ in self?.insertEmoji(emoji) }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            for _ in slice.count..<columns { row.addArrangedSubview(UIView()) }
            emojiStack.addArrangedSubview(row)
        }
        emojiScroll.setContentOffset(.zero, animated: false)
    }
    private func insertEmoji(_ emoji: String) {
        syncHostChange()
        commitCurrent()
        editor.insert(emoji)
        recentEmojiStore.record(emoji)
        pendingAutocorrectUndo = nil
    }
    private func rebuildClipboardRows() {
        for arranged in clipboardStack.arrangedSubviews {
            clipboardStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        openClipboardRow = nil
        let isLight = traitCollection.userInterfaceStyle == .light
        func noteRow(_ text: String) {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 15)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            clipboardStack.addArrangedSubview(label)
        }
        guard hasFullAccess else {
            noteRow("フルアクセスが必要です。設定 → 一般 → キーボード → NumberKeyで「フルアクセスを許可」をオンにしてください。")
            return
        }
        clipboardStore.reload()
        let items = clipboardStore.items
        if items.isEmpty { noteRow("履歴はまだありません") }
        for (index, item) in items.enumerated() {
            let row = PhraseRowView(phrase: item, isLight: isLight, reorderMode: false, isFirst: false, isLast: false)
            row.onTap = { [weak self] in
                guard let self else { return }
                self.hideClipboardPanel()
                self.syncHostChange()
                self.commitCurrent()
                self.editor.insert(item)
            }
            row.onDelete = { [weak self] in
                self?.clipboardStore.remove(at: index)
                self?.rebuildClipboardRows()
            }
            row.onSwipeStart = { [weak self, weak row] in
                guard let self, let row else { return }
                if self.openClipboardRow !== row {
                    self.openClipboardRow?.setOpen(false, animated: true)
                }
                self.openClipboardRow = row
            }
            clipboardScroll.panGestureRecognizer.require(toFail: row.panRecognizer)
            clipboardStack.addArrangedSubview(row)
        }
    }
    private func rebuildPhraseRows() {
        for arranged in phraseStack.arrangedSubviews {
            phraseStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        openPhraseRow = nil
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
            let row = PhraseRowView(phrase: phrase, isLight: isLight, reorderMode: pickerReorderMode,
                                    isFirst: index == 0, isLast: index == phrases.count - 1)
            row.onTap = { [weak self] in
                guard let self, !self.pickerReorderMode else { return }
                self.hidePhrasePicker()
                self.insertPhrase(phrase)
            }
            row.onDelete = { [weak self] in
                self?.phraseStore.remove(at: index)
                self?.rebuildPhraseRows()
            }
            row.onMoveUp = { [weak self] in
                self?.phraseStore.move(from: index, to: index - 1)
                self?.rebuildPhraseRows()
            }
            row.onMoveDown = { [weak self] in
                self?.phraseStore.move(from: index, to: index + 1)
                self?.rebuildPhraseRows()
            }
            row.onSwipeStart = { [weak self, weak row] in
                guard let self, let row else { return }
                if self.openPhraseRow !== row {
                    self.openPhraseRow?.setOpen(false, animated: true)
                }
                self.openPhraseRow = row
            }
            if !pickerReorderMode {
                phraseScroll.panGestureRecognizer.require(toFail: row.panRecognizer)
            }
            phraseStack.addArrangedSubview(row)
        }
        phraseReorderToggle.setTitle(pickerReorderMode ? "並び替え中" : "並び替え", for: .normal)
        phraseReorderToggle.setTitleColor(pickerReorderMode ? .systemBlue : nil, for: .normal)
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
        hideClipboardPanel()
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
    /// 登録パネルはラベル表示でシステムのカーソル/ペーストが付かないため、
    /// 専用ボタンでクリップボードの文字列をバッファへ直接入れる。
    private func pasteIntoCapture() {
        guard isCapturing else { return }
        guard hasFullAccess else {
            let alert = UIAlertController(title: "貼り付けできません",
                                          message: "クリップボードの読み取りにはフルアクセスが必要です。設定でNumberKeyのフルアクセスを許可してください。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        var sanitized = ""
        for scalar in pasted.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { sanitized.append(" ") }
            else if !CharacterSet.controlCharacters.contains(scalar) { sanitized.unicodeScalars.append(scalar) }
        }
        guard !sanitized.isEmpty else { return }
        commitCurrent()
        editor.insert(sanitized)
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
        if action != .delete { pendingAutocorrectUndo = nil }
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
        case .paste: showClipboardPanel()
        }
    }
    private func insert(_ text: String) {
        syncHostChange()
        if !isJapanese, !symbols, composition.isEmpty, text.count == 1, ".?!,".contains(text) {
            autocorrectEnglishWord(delimiter: text)
        }
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
        if !isJapanese, composition.isEmpty { renderState() }
    }
    private func scheduleConversion() {
        revision += 1
        let requestRevision = revision, snapshot = composition
        conversionReady = false; waitingSpaceCount = 0; selected = nil
        // 候補を毎打鍵でリセットすると候補欄が点滅して遅く見える。前回の候補を
        // 残したまま新しい変換結果を待つ（空のときだけ基本候補で埋める）。
        if snapshot.isEmpty { candidates = []; englishExtraValues = [] }
        else if candidates.isEmpty { candidates = insertEnglishExtras(baseCandidates(), raw: rawRomaji(of: snapshot)) }
        conversionTask?.cancel()
        renderState()
        guard !snapshot.isEmpty else { return }
        let service = service
        conversionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await service.candidates(for: snapshot)
            guard !Task.isCancelled, let self, self.revision == requestRevision else { return }
            self.syncHostChange()
            guard self.revision == requestRevision else { return }
            var seen = Set<String>()
            let merged = Array((result + self.baseCandidates()).filter { seen.insert($0).inserted })
            let newCandidates = Array(self.insertEnglishExtras(merged, raw: self.rawRomaji(of: snapshot)).prefix(30))
            let candidatesChanged = newCandidates != self.candidates
            if candidatesChanged { self.candidates = newCandidates }
            self.conversionReady = true
            self.selected = self.waitingSpaceCount > 0 && !self.candidates.isEmpty ? (self.waitingSpaceCount - 1) % self.candidates.count : nil
            let hadWaitingSpace = self.waitingSpaceCount > 0
            self.waitingSpaceCount = 0
            // 候補が前回と同一なら候補欄の再描画は不要（体感の遅さ対策）。
            if candidatesChanged || hadWaitingSpace { self.renderState() }
        }
    }
    /// composition の生のローマ字入力を復元する（英字候補の判定用）。
    private func rawRomaji(of composition: ComposingText) -> String {
        var result = ""
        for element in composition.input {
            switch element.piece {
            case .character(let character): result.append(character)
            case .key(_, let input, _): result.append(input)
            case .compositionSeparator: break
            }
        }
        return result
    }
    /// 日本語の候補列に英字そのまま候補を差し込む。英単語として成立すれば
    /// 上位（2番手）、そうでなければ3番手。英字候補は日本語変換の学習対象にしない。
    private func insertEnglishExtras(_ list: [String], raw: String) -> [String] {
        guard isJapanese, let lexicon = englishLexicon else { englishExtraValues = []; return list }
        let extras = lexicon.englishCandidates(forRomaji: raw).filter { !list.contains($0) }
        englishExtraValues = Set(extras)
        guard !extras.isEmpty else { return list }
        var merged = list
        let position = min(lexicon.contains(raw) && raw.count >= 3 ? 1 : 2, merged.count)
        merged.insert(contentsOf: extras, at: position)
        return merged
    }
    private func baseCandidates() -> [String] {
        guard !composition.isEmpty else { return [] }
        let kana = composition.convertTarget
        let katakana = kana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? kana
        return kana == katakana ? [kana] : [kana, katakana]
    }
    private func renderState(updateMarked: Bool = true) {
        if !isJapanese { refreshEnglishSuggestions() }
        if updateMarked {
            let display = selected.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil } ?? composition.convertTarget
            let caret = selected == nil ? String(display.prefix(composition.convertTargetCursorPosition)).utf16.count : display.utf16.count
            editor.show(display, caret: caret)
        }
        canvas.setComposing(!composition.isEmpty)
        let shouldHideCandidates = !showsCandidateStrip
        if candidateScroll.isHidden != shouldHideCandidates { view.setNeedsLayout() }
        let stripCount = isJapanese ? candidates.count : englishSuggestions.count
        while candidateKeys.count > stripCount {
            let key = candidateKeys.removeLast()
            candidateStack.removeArrangedSubview(key)
            key.removeFromSuperview()
        }
        while candidateKeys.count < stripCount {
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
            guard isJapanese else {
                let value = englishSuggestions[index]
                let title = applyingCase(of: currentEnglishWord(), to: value)
                if key.renderedValue != value || key.title(for: .normal) != title {
                    key.setTitle(title, for: .normal)
                    key.accessibilityIdentifier = "candidate." + value
                    key.renderedValue = value
                }
                if key.isSelectedCandidate == true {
                    key.backgroundColor = .clear
                    key.isSelectedCandidate = false
                }
                key.onSelect = { [weak self] in self?.acceptEnglishSuggestion(value) }
                key.actionRevision = displayedRevision
                continue
            }
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
                    // 変換待ちの間に残っている前回候補は、確定に使わない。
                    guard self.conversionReady else { return }
                    self.syncHostChange()
                    guard self.revision == displayedRevision else { return }
                    self.commit(value, learn: !self.englishExtraValues.contains(value))
                }
                key.actionRevision = displayedRevision
            }
        }
        // 候補リストが変わったら候補欄を左端に戻し、必ず左から見せる。
        // （選択ハイライトだけの変化では戻さない。）
        let stripValues = isJapanese ? candidates : englishSuggestions
        if stripValues != lastStripValues {
            lastStripValues = stripValues
            if candidateScroll.contentOffset.x != 0 {
                candidateScroll.setContentOffset(.zero, animated: false)
            }
        }
    }
    // MARK: - 英語の補完・自動修正

    /// カーソル直前の英単語（英字と内部アポストロフィの連続）。
    private func currentEnglishWord() -> String {
        guard let before = activeDocument.before else { return "" }
        var word = ""
        for character in before.reversed() {
            if character.isLetter || character == "'" { word.append(character) } else { break }
        }
        return String(word.reversed())
    }
    private func refreshEnglishSuggestions() {
        guard !isJapanese, !symbols, composition.isEmpty, !isCapturing else { englishSuggestions = []; return }
        let typed = currentEnglishWord()
        guard typed.count >= 2, typed.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }),
              let lexicon = englishLexicon else { englishSuggestions = []; return }
        englishSuggestions = lexicon.suggestions(for: typed.lowercased())
    }
    private func applyingCase(of typed: String, to suggestion: String) -> String {
        if typed.count > 1, typed == typed.uppercased(), typed != typed.lowercased() {
            return suggestion.uppercased()
        }
        if let first = typed.first, first.isUppercase {
            return suggestion.prefix(1).uppercased() + String(suggestion.dropFirst())
        }
        return suggestion
    }
    private func acceptEnglishSuggestion(_ value: String) {
        let typed = currentEnglishWord()
        guard !typed.isEmpty else { return }
        syncHostChange()
        for _ in 0..<typed.count { editor.deleteBackward() }
        editor.insert(applyingCase(of: typed, to: value) + " ")
        pendingAutocorrectUndo = nil
        renderState()
    }
    /// 確信できる場合だけ入力中単語を修正する。delimiter は確定に使った区切り文字（取り消し判定用）。
    @discardableResult
    private func autocorrectEnglishWord(delimiter: String) -> Bool {
        guard !symbols, let lexicon = englishLexicon else { return false }
        let typed = currentEnglishWord()
        guard typed.count >= 3, typed.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }),
              let correction = lexicon.autocorrect(for: typed.lowercased()) else { return false }
        for _ in 0..<typed.count { editor.deleteBackward() }
        let fixed = applyingCase(of: typed, to: correction)
        editor.insert(fixed)
        pendingAutocorrectUndo = (original: typed, corrected: fixed, delimiter: delimiter)
        return true
    }
    private func englishSpace() {
        pendingAutocorrectUndo = nil
        autocorrectEnglishWord(delimiter: " ")
        editor.insert(" ")
        renderState()
    }
    /// 自動修正直後のバックスペースは、修正前の単語に戻す（iOS 純正と同じ作法）。
    private func undoEnglishAutocorrectIfApplicable() -> Bool {
        guard let undo = pendingAutocorrectUndo else { return false }
        pendingAutocorrectUndo = nil
        let suffix = undo.corrected + undo.delimiter
        guard let before = activeDocument.before, before.hasSuffix(suffix) else { return false }
        for _ in 0..<suffix.count { editor.deleteBackward() }
        editor.insert(undo.original)
        return true
    }
    private func space() {
        guard !composition.isEmpty else {
            if isJapanese || symbols { editor.insert(" ") } else { englishSpace() }
            return
        }
        guard conversionReady else { waitingSpaceCount += 1; return }
        guard !candidates.isEmpty else { return }
        selected = selected.map { ($0 + 1) % candidates.count } ?? 0
        revision += 1; conversionTask?.cancel()
        renderState()
    }
    private func commitCurrent() {
        guard !composition.isEmpty else { return }
        if let selected, candidates.indices.contains(selected) { commit(candidates[selected], learn: !englishExtraValues.contains(candidates[selected])) }
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
        if composition.isEmpty {
            if undoEnglishAutocorrectIfApplicable() { renderState(); return }
            editor.deleteBackward()
            if !isJapanese { renderState() }
        }
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

/// 定型文パネルの1行。カードを左へスワイプすると右端に「削除」が出る
/// （iOS標準のスワイプ削除と同じ作法）。並び替えモードではスワイプを止め、
/// 右端に ↑ ↓ ボタンを出す。
private final class PhraseRowView: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onSwipeStart: (() -> Void)?

    let panRecognizer = UIPanGestureRecognizer()
    private let card = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var panBase: CGFloat = 0
    private(set) var isOpen = false
    private static let deleteWidth: CGFloat = 76

    init(phrase: String, isLight: Bool, reorderMode: Bool, isFirst: Bool, isLast: Bool) {
        super.init(frame: .zero)
        deleteButton.setTitle("削除", for: .normal)
        deleteButton.setTitleColor(.white, for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        deleteButton.backgroundColor = .systemRed
        deleteButton.layer.cornerRadius = 8
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        addSubview(deleteButton)

        card.contentHorizontalAlignment = .left
        card.titleLabel?.numberOfLines = 3
        card.titleLabel?.font = .systemFont(ofSize: 18)
        card.titleLabel?.lineBreakMode = .byTruncatingTail
        card.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: reorderMode ? 56 : 12)
        card.layer.cornerRadius = 8
        card.backgroundColor = isLight ? .white : UIColor(white: 0.32, alpha: 1)
        card.setTitle(phrase, for: .normal)
        card.setTitleColor(isLight ? .black : .white, for: .normal)
        card.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.isOpen { self.setOpen(false, animated: true) } else { self.onTap?() }
        }, for: .touchUpInside)
        addSubview(card)

        if reorderMode {
            let up = UIButton(type: .system)
            up.setTitle("↑", for: .normal)
            up.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
            up.isEnabled = !isFirst
            up.alpha = isFirst ? 0.25 : 1
            up.addAction(UIAction { [weak self] _ in self?.onMoveUp?() }, for: .touchUpInside)
            let down = UIButton(type: .system)
            down.setTitle("↓", for: .normal)
            down.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
            down.isEnabled = !isLast
            down.alpha = isLast ? 0.25 : 1
            down.addAction(UIAction { [weak self] _ in self?.onMoveDown?() }, for: .touchUpInside)
            addSubview(up)
            addSubview(down)
            up.translatesAutoresizingMaskIntoConstraints = false
            down.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                up.trailingAnchor.constraint(equalTo: trailingAnchor),
                up.topAnchor.constraint(equalTo: topAnchor),
                up.widthAnchor.constraint(equalToConstant: 48),
                up.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5),
                down.trailingAnchor.constraint(equalTo: trailingAnchor),
                down.bottomAnchor.constraint(equalTo: bottomAnchor),
                down.widthAnchor.constraint(equalToConstant: 48),
                down.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5)
            ])
        }

        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        panRecognizer.delegate = self
        panRecognizer.isEnabled = !reorderMode
        card.addGestureRecognizer(panRecognizer)

        card.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.topAnchor.constraint(equalTo: topAnchor),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: Self.deleteWidth)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setOpen(_ open: Bool, animated: Bool) {
        isOpen = open
        let target = CGAffineTransform(translationX: open ? -Self.deleteWidth : 0, y: 0)
        if animated {
            UIView.animate(withDuration: 0.2) { self.card.transform = target }
        } else {
            card.transform = target
        }
    }

    // UIView 自身が持つ同名メソッドの override（extension には置けない）。
    // 横方向のパンだけをスワイプとして開始し、縦はパネルのスクロールに譲る。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            panBase = card.transform.tx
            onSwipeStart?()
        case .changed:
            let x = min(0, max(-Self.deleteWidth, panBase + gesture.translation(in: self).x))
            card.transform = CGAffineTransform(translationX: x, y: 0)
        case .ended, .cancelled:
            let shouldOpen = card.transform.tx < -Self.deleteWidth / 2 || gesture.velocity(in: self).x < -300
            setOpen(shouldOpen, animated: true)
        default:
            break
        }
    }
}
