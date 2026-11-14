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
    // build 48: candidateStack コンテナは廃止。候補キーは candidateScroll の
    // 直下に直接置く (詳細は renderState の配置ブロックのコメント参照)。
    // Layout snapshots are deduplicated; build 47's paired render samples are not.
    private var lastBarGeometrySignature: String?
    // Build 47: non-interactive overlays; never change the candidate layout.
    // Build 48: マーカー C は candidateStack 内にあったためコンテナ廃止に伴い削除。
    private let barMarkerRoot = KeyboardViewController.makeBarMarker("A")
    private let barMarkerScroll = KeyboardViewController.makeBarMarker("B")
    private var barDiagnosticSample = 0
    private var candidateKeys: [CandidateKey] = []
    /// 開発段階の計測オーバーレイ（PerfProbe の集計を候補欄の上に重ねて表示）。
    private let perfLabel = UILabel()
    private var candidateStyleIsLight: Bool?
    // 定型文はキーボード拡張自身の保存領域で完結させる（PhraseStore 参照）。
    private lazy var phraseStore = PhraseStore(legacyPhrases: { KeyboardViewController.legacySharedPhrases() })
    private let clipboardStore = ClipboardHistoryStore()
    private var englishLexicon: EnglishLexicon?
    private var englishSuggestions: [String] = []
    private var englishExtraValues: Set<String> = []
    private let dictionaryStore = DictionaryPackStore()
    private let dictionaryLibrary = DictionaryPackLibrary()
    private var packExtraValues: Set<String> = []
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
    // 販売ビルド: 体験期間が終了したときだけ、キーの代わりに出す案内ビュー。
    private let expiredView = UIView()
    private let expiredLabel = UILabel()
    private let expiredOpenButton = UIButton(type: .system)
    private var purchaseExpired = false
    private let clipboardStack = UIStackView()
    private let clipboardClearButton = UIButton(type: .system)
    private var isClipboardPicking = false
    private weak var openClipboardRow: PhraseRowView?
    private var isJapanese: Bool { settings.japanese }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 変換時間の計測は PerfProbe に集約する (ConversionService 側のコメント参照)。
        ConversionService.perfSink = { name, ms in PerfProbe.shared.recordElapsed(name, ms: ms) }
        // 実機診断: ライブ変換パスのトレースを DiagTrace に集約する。
        ConversionService.traceSink = { event, detail in DiagTrace.shared.record(event: event, detail: detail) }
        KeyboardSettings.migrateLegacyExtensionPreferences()
        // 英単語リスト（約1MB）の読み込みは起動処理を止めないよう非同期で行う。
        // 起動が重いとアップデート直後の初回表示で iOS に見限られ、代わりに
        // システムキーボードが出てしまうことがある。
        Task.detached(priority: .utility) { [weak self] in
            let loaded = EnglishLexicon.loadBundled()
            await MainActor.run { self?.englishLexicon = loaded }
        }
        if PerfProbe.enabled {
            // 開発用と一目で分かる高コントラスト表示にする。候補欄に重ねず、
            // レイアウト側で専用の帯を確保する (viewDidLayoutSubviews 参照)。
            perfLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            perfLabel.textColor = .black
            perfLabel.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.92)
            perfLabel.adjustsFontSizeToFitWidth = true
            perfLabel.minimumScaleFactor = 0.7
            perfLabel.text = "PerfProbe 起動中"
            view.addSubview(perfLabel)
        }
        view.addSubview(candidateScroll)
        candidateScroll.showsHorizontalScrollIndicator = false
        // build 48: build 47 の実機診断で、scroll 直下のマーカー B とルート直下の
        // マーカー A は表示されるのに、コンテナ candidateStack の子 (マーカー C と
        // 候補キー) だけが一切合成されないことが確定した。CSV 上は stack の
        // frame/win/hidden/alpha も key0 の model/presentation も全て正常。
        // build 46 で UIStackView → 素の UIView + 手動フレームに替えても中身が
        // 出なかったため、コンテナそのものを廃止し、候補キーは renderState で
        // candidateScroll の直下に直接配置する。
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
        DiagProbe.runOnce(service: service)
        let height = view.heightAnchor.constraint(equalToConstant: 270)
        height.priority = .init(999); height.isActive = true; heightConstraint = height
        // 期限切れ案内ビュー（通常は隠れている）。文言だけが頼りの導線なので、
        // アプリを開くボタンは試みとして置き、効かなくても文言で案内できる形にする。
        expiredView.isHidden = true
        expiredLabel.text = "体験期間（1週間）が終了しました。One Keyboard アプリを開いて購入すると、引き続き使えます。"
        expiredLabel.numberOfLines = 0
        expiredLabel.textAlignment = .center
        expiredLabel.font = .systemFont(ofSize: 16)
        expiredView.addSubview(expiredLabel)
        expiredOpenButton.setTitle("One Keyboard アプリを開く", for: .normal)
        expiredOpenButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        expiredOpenButton.addAction(UIAction { [weak self] _ in
            guard let url = URL(string: "onekeyboard://") else { return }
            self?.extensionContext?.open(url, completionHandler: nil)
        }, for: .touchUpInside)
        expiredView.addSubview(expiredOpenButton)
        view.addSubview(expiredView)
        view.addSubview(barMarkerRoot)
        candidateScroll.addSubview(barMarkerScroll)
        layoutBarMarkers()
        refreshPurchaseState()
        rebuildCanvas()
        // 初期高さも実レイアウトと同じ計算式から決める (270 の決め打ちは廃止)。
        // 以降は viewDidLayoutSubviews が候補バーの有無込みで更新し続ける。
        let initialWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        heightConstraint?.constant = canvas.preferredHeight(width: initialWidth) + (showsCandidateStrip ? 34 : 0)
    }

    /// 購入/トライアル状態を判定し直す。期限切れのときだけ案内ビューを出す。
    /// 読み取りに失敗した場合は PurchaseGate 側のフェイルオープンで trial 扱いに
    /// なるため、ここでロックされることはない。
    private func refreshPurchaseState() {
        purchaseExpired = PurchaseGate.evaluateForDisplay() == .expired
    }

    private var panelsBuilt = false
    /// パネル群（定型文・クリップボード・絵文字・登録）は初回表示まで作らない。
    /// 起動時に全部組み立てると表示が重くなり、iOS に見限られる一因になる。
    private func buildPanelsIfNeeded() {
        guard !panelsBuilt else { return }
        panelsBuilt = true
        // 定型文の登録は、枠（パネル）の中で完結させる。タイトル・入力テキスト・
        // 保存/取消ボタンを1つの枠に入れ、「ここに入力する」ことが見て分かるようにする。
        capturePanel.isHidden = true
        capturePanel.layer.cornerRadius = 10
        capturePanel.layer.borderWidth = 1
        view.insertSubview(capturePanel, belowSubview: canvas)
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
        view.insertSubview(phrasePanel, belowSubview: canvas)
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
        view.insertSubview(clipboardPanel, belowSubview: canvas)
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
        view.insertSubview(emojiPanel, belowSubview: canvas)
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
    }
    private var lastAppearanceSnapshot: LayoutSettings?
    private var lastAppearanceJapanese: Bool?
    private var lastAppearanceStyle: UIUserInterfaceStyle = .unspecified

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // キーボードを開くたびに判定し直す（アプリ側で購入された場合に追随する）。
        refreshPurchaseState()
        if PerfProbe.enabled { PerfProbe.shared.reset(); perfLabel.text = nil }
        settings = KeyboardSettings()
        // 設定が変わったときだけキャンバスを組み直す。毎回組み直すと、キーボードを
        // 開くたびに全キーを再生成することになり表示が重くなる。旧設定の移行は
        // viewDidLoad で1回だけ行う（ここで毎回やる必要はない）。
        let snapshot = settings.snapshot
        let style = traitCollection.userInterfaceStyle
        if snapshot != lastAppearanceSnapshot || settings.japanese != lastAppearanceJapanese || style != lastAppearanceStyle {
            lastAppearanceSnapshot = snapshot
            lastAppearanceJapanese = settings.japanese
            lastAppearanceStyle = style
            rebuildCanvas()
        }
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
        // PerfProbe の帯は候補欄の上に専用スペースを確保する。重ね表示だと
        // 候補のボタンやホスト側の角丸に隠れて見えないことがあったため。
        // パネル表示中は帯ごと隠す。
        let perfHeight: CGFloat = (PerfProbe.enabled && topHeight == 0) ? 16 : 0
        if PerfProbe.enabled {
            perfLabel.isHidden = perfHeight == 0
            if perfHeight > 0 { perfLabel.frame = CGRect(x: 0, y: topHeight, width: width, height: perfHeight) }
            view.bringSubviewToFront(perfLabel)
            updatePerfOverlay()
        }
        candidateScroll.isHidden = candidateHeight == 0
        candidateScroll.frame = CGRect(x: 0, y: topHeight + perfHeight, width: width, height: candidateHeight)
        layoutBarMarkers()
        canvas.frame = CGRect(x: 0, y: topHeight + perfHeight + candidateHeight, width: width, height: keysHeight)
        // 期限切れのときは案内ビューがキーボード全体を覆う（キーは触れない）。
        expiredView.isHidden = !purchaseExpired
        if purchaseExpired {
            expiredView.frame = view.bounds
            expiredView.backgroundColor = view.backgroundColor
            expiredLabel.textColor = traitCollection.userInterfaceStyle == .light ? UIColor.black : UIColor.white
            let midY = view.bounds.height / 2
            expiredLabel.frame = CGRect(x: 24, y: midY - 78, width: max(0, width - 48), height: 92)
            expiredOpenButton.frame = CGRect(x: 24, y: midY + 22, width: max(0, width - 48), height: 44)
            view.bringSubviewToFront(expiredView)
        }
        let height = topHeight + perfHeight + candidateHeight + keysHeight + view.safeAreaInsets.bottom
        if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
        traceBarGeometry(source: "layout")
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
        // キャンバス再構築のたびに認識器が積み重ならないよう1つだけにする。
        if button.gestureRecognizers?.contains(where: { $0.name == "phrasePicker" }) != true {
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(spaceLongPressed(_:)))
            hold.minimumPressDuration = 0.35
            hold.name = "phrasePicker"
            button.addGestureRecognizer(hold)
        }
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
        buildPanelsIfNeeded()
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
        buildPanelsIfNeeded()
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
        buildPanelsIfNeeded()
        hidePhrasePicker()
        hideClipboardPanel()
        if emojiCategories.isEmpty {
            emojiCategories = EmojiCatalog.loadBundled()
            recentEmojiStore.retainOnly(valid: Set(emojiCategories.flatMap { $0.emojis }))
        }
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
        // 絵文字は連続して入れることが多いので、挿入してもパネルは閉じない
        // （閉じるのは × ボタンだけ）。「最近」タブでは打った絵文字が
        // 先頭に来るようグリッドをその場で更新する。
        syncHostChange()
        commitCurrent()
        editor.insert(emoji)
        recentEmojiStore.record(emoji)
        pendingAutocorrectUndo = nil
        if emojiCategoryIndex == 0 { rebuildEmojiGrid() }
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
            noteRow("フルアクセスが必要です。設定 → 一般 → キーボード → One Keyboardで「フルアクセスを許可」をオンにしてください。")
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
        buildPanelsIfNeeded()
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
                                          message: "クリップボードの読み取りにはフルアクセスが必要です。設定でOne Keyboardのフルアクセスを許可してください。",
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
                                      message: "One Keyboardアプリで配置をコピーしてから、もう一度読み込んでください。",
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
        let roman = text.count == 1 && text.first.map { $0.isASCII && ($0.isLetter || $0 == "'") } == true
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
        let inputStamp = PerfProbe.stamp()
        revision += 1
        let requestRevision = revision, snapshot = composition
        DiagTrace.shared.record(event: "vc.schedule", detail: "rev=\(requestRevision) input=\(snapshot.convertTarget) empty=\(snapshot.isEmpty)")
        conversionReady = false; waitingSpaceCount = 0; selected = nil
        // 候補を毎打鍵でリセットすると候補欄が点滅して遅く見える。前回の候補を
        // 残したまま新しい変換結果を待つ。
        // 空のときの「基本候補で先埋め」もしない: 単語の打ち始めに [かな, カナ]
        // が一瞬出てから本候補に総入れ替えされる二度表示が、ちらつきの主因。
        // 変換は約5msで返るので、先埋めなしでも空白は知覚できない。
        if snapshot.isEmpty { candidates = []; englishExtraValues = []; packExtraValues = [] }
        conversionTask?.cancel()
        renderState()
        PerfProbe.shared.record("input", since: inputStamp)
        guard !snapshot.isEmpty else { return }
        let service = service
        conversionTask = Task { [weak self] in
            // 打鍵の束をまとめるための短い待ち。長くするとその分だけ候補の
            // 出現が遅れるので最小限にし、古い変換の実行自体はサービス側の
            // 世代ゲートで省く。
            do { try await Task.sleep(nanoseconds: 4_000_000) } catch {
                DiagTrace.shared.record(event: "vc.sleepcancel", detail: "rev=\(requestRevision)")
                return
            }
            guard !Task.isCancelled else {
                DiagTrace.shared.record(event: "vc.cancelled", detail: "rev=\(requestRevision)")
                return
            }
            // 世代遅れでスキップされたら nil。状態は新しいタスクが持つので触らない。
            let awaitStamp = PerfProbe.stamp()
            let serviceResult = await service.candidates(for: snapshot, generation: requestRevision)
            guard let result = serviceResult else {
                DiagTrace.shared.record(event: "vc.stale", detail: "rev=\(requestRevision) input=\(snapshot.convertTarget)")
                return
            }
            PerfProbe.shared.record("await", since: awaitStamp)
            guard !Task.isCancelled, let self else {
                DiagTrace.shared.record(event: "vc.dropped", detail: "rev=\(requestRevision) reason=cancelled-or-gone")
                return
            }
            guard self.revision == requestRevision else {
                DiagTrace.shared.record(event: "vc.dropped", detail: "rev=\(requestRevision) nowRev=\(self.revision) reason=revision-mismatch")
                return
            }
            // ここで syncHostChange() はしない。変換中にホスト側で編集があれば
            // textDidChange / selectionDidChange 側のチェックで composition が
            // リセットされ、revision ガードでこの結果は捨てられる。毎回の
            // documentContext 読み直し（ホスト往復）を候補表示の経路から外す。
            var seen = Set<String>()
            let merged = Array((result + self.baseCandidates()).filter { seen.insert($0).inserted })
            let withEnglish = self.insertEnglishExtras(merged, raw: self.rawRomaji(of: snapshot))
            let newCandidates = Array(self.insertPackExtras(withEnglish, kana: snapshot.convertTarget).prefix(30))
            let candidatesChanged = newCandidates != self.candidates
            if candidatesChanged { self.candidates = newCandidates }
            self.conversionReady = true
            self.selected = self.waitingSpaceCount > 0 && !self.candidates.isEmpty ? (self.waitingSpaceCount - 1) % self.candidates.count : nil
            let hadWaitingSpace = self.waitingSpaceCount > 0
            self.waitingSpaceCount = 0
            DiagTrace.shared.record(event: "vc.applied", detail: "rev=\(requestRevision) svcCount=\(result.count) finalCount=\(newCandidates.count) first=\(newCandidates.first ?? "") changed=\(candidatesChanged) render=\(candidatesChanged || hadWaitingSpace)")
            // 候補が前回と同一なら候補欄の再描画は不要（体感の遅さ対策）。
            if candidatesChanged || hadWaitingSpace { self.renderState() }
            self.updatePerfOverlay()
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
    /// 辞書パックの候補を候補列に差し込む。SNS は候補列の先頭に固定し
    /// (変換・リランク・タイポ補正の後段なので並び替えでは動かない)、
    /// それ以外のパックは末尾に足す (通常辞書より低優先)。読みがかな文字列と
    /// 完全一致した表記だけを出す (部分一致は誤爆する)。
    /// パック候補は英字そのまま候補と同様、日本語変換の学習対象にしない。
    private func insertPackExtras(_ list: [String], kana: String) -> [String] {
        guard isJapanese else { packExtraValues = []; return list }
        let pinned = dictionaryLibrary.pinnedSurfaces(forKana: kana, store: dictionaryStore)
        let appended = dictionaryLibrary.appendedSurfaces(forKana: kana, store: dictionaryStore)
        packExtraValues = Set(pinned + appended)
        return DictionaryPackLibrary.mergingPacks(into: list, pinned: pinned, appended: appended)
    }
    /// 変換学習に回してよい候補か。英字そのまま候補と辞書パック候補は回さない。
    private func shouldLearn(_ value: String) -> Bool {
        !englishExtraValues.contains(value) && !packExtraValues.contains(value)
    }
    private func baseCandidates() -> [String] {
        guard !composition.isEmpty else { return [] }
        let kana = composition.convertTarget
        let katakana = kana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? kana
        return kana == katakana ? [kana] : [kana, katakana]
    }
    /// build 45: 候補キーの未選択ピル背景と選択時背景。.custom ボタンでは
    /// システム側の見た目が付かないため、スタイルに合わせて自前で塗る。
    private func candidatePillColor(isLight: Bool) -> UIColor {
        isLight ? UIColor(white: 1.0, alpha: 0.65) : UIColor(white: 0.32, alpha: 0.55)
    }
    private var selectedCandidateColor: UIColor { UIColor(white: 0.45, alpha: 0.95) }
    private func renderState(updateMarked: Bool = true) {
        if !isJapanese { refreshEnglishSuggestions() }
        if updateMarked {
            let display = selected.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil } ?? composition.convertTarget
            let caret = selected == nil ? String(display.prefix(composition.convertTargetCursorPosition)).utf16.count : display.utf16.count
            PerfProbe.shared.measure("show") { editor.show(display, caret: caret) }
        }
        canvas.setComposing(!composition.isEmpty)
        let shouldHideCandidates = !showsCandidateStrip
        if candidateScroll.isHidden != shouldHideCandidates { view.setNeedsLayout() }
        let stripStamp = PerfProbe.stamp()
        let stripCount = isJapanese ? candidates.count : englishSuggestions.count
        while candidateKeys.count > stripCount {
            let key = candidateKeys.removeLast()
            key.removeFromSuperview()
        }
        while candidateKeys.count < stripCount {
            // build 45: .system ボタンは iOS 27 SDK でホスト側リモートビューに
            // ラベル/マテリアルが合成されず候補欄が空白になる疑いがあるため
            // .custom に変更し、背景色も自前で塗る。
            let key = CandidateKey(type: .custom)
            key.titleLabel?.font = .systemFont(ofSize: 17)
            key.setTitleColor(traitCollection.userInterfaceStyle == .light ? .black : .white, for: .normal)
            key.backgroundColor = candidatePillColor(isLight: traitCollection.userInterfaceStyle == .light)
            key.contentEdgeInsets = .init(top: 0, left: 10, bottom: 0, right: 10)
            key.layer.cornerRadius = 4
            key.addTarget(key, action: #selector(CandidateKey.activate), for: .touchUpInside)
            candidateKeys.append(key)
            // build 48: コンテナ (旧 candidateStack) を介さず scroll 直下へ直接置く。
            candidateScroll.addSubview(key)
        }
        let isLight = traitCollection.userInterfaceStyle == .light
        if candidateStyleIsLight != isLight {
            candidateKeys.forEach { key in
                key.setTitleColor(isLight ? .black : .white, for: .normal)
                if key.isSelectedCandidate != true {
                    key.backgroundColor = candidatePillColor(isLight: isLight)
                }
            }
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
                    key.backgroundColor = candidatePillColor(isLight: isLight)
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
                key.backgroundColor = isSelected ? selectedCandidateColor : candidatePillColor(isLight: isLight)
                key.isSelectedCandidate = isSelected
            }
            if key.actionRevision != displayedRevision || valueChanged {
                key.onSelect = { [weak self] in
                    guard let self else { return }
                    // 変換待ちの間に残っている前回候補は、確定に使わない。
                    guard self.conversionReady else { return }
                    self.syncHostChange()
                    guard self.revision == displayedRevision else { return }
                    self.commit(value, learn: self.shouldLearn(value))
                }
                key.actionRevision = displayedRevision
            }
        }
        // build 48: 手動フレーム配置。キーは candidateScroll の直下の子で、
        // frame は scroll のコンテンツ座標そのもの。左端 6pt から 8pt 間隔で
        // 並べ、contentSize を内容幅に合わせる (右端にも 6pt の余白を残す)。
        // 配置計算自体は build 46 (コンテナ内配置) から無変更。
        do {
            var x: CGFloat = 6
            let stripHeight: CGFloat = 34
            for key in candidateKeys {
                var w = key.intrinsicContentSize.width
                if w <= 0 {
                    w = key.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: stripHeight)).width
                }
                key.frame = CGRect(x: x, y: 0, width: w, height: stripHeight)
                x += w + 8
            }
            let contentWidth = candidateKeys.isEmpty ? 0 : x - 8 + 6
            candidateScroll.contentSize = CGSize(width: contentWidth, height: stripHeight)
        }
        PerfProbe.shared.record("strip", since: stripStamp)
        // 候補リストが変わったら候補欄を左端に戻し、必ず左から見せる。
        // （選択ハイライトだけの変化では戻さない。）
        let stripValues = isJapanese ? candidates : englishSuggestions
        if stripValues != lastStripValues {
            lastStripValues = stripValues
            if candidateScroll.contentOffset.x != 0 {
                candidateScroll.setContentOffset(.zero, animated: false)
            }
        }
        DiagTrace.shared.record(event: "bar.render", detail: "items=\(candidateKeys.count) stripCount=\(stripCount) showsStrip=\(showsCandidateStrip) composing=\(!composition.isEmpty) ja=\(isJapanese) rev=\(revision)")
        // Only order our diagnostic overlays above content; do not reorder product views.
        candidateScroll.bringSubviewToFront(barMarkerScroll)
        barDiagnosticSample += 1
        let sample = barDiagnosticSample
        let requestedRevision = revision
        let sampledAt = ProcessInfo.processInfo.systemUptime
        traceBarGeometry(source: "render sample=\(sample) requestRev=\(requestedRevision)", force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - sampledAt
            self.traceBarGeometry(source: "render.delayed sample=\(sample) requestRev=\(requestedRevision) elapsed=\(elapsed)", force: true)
        }
    }

    private static func makeBarMarker(_ title: String) -> UILabel {
        let marker = UILabel()
        marker.text = title
        marker.font = .boldSystemFont(ofSize: 14)
        marker.textAlignment = .center
        marker.textColor = .white
        marker.backgroundColor = .red
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = false
        return marker
    }

    private func layoutBarMarkers() {
        // Separate x positions allow both markers to be distinguished in one screenshot.
        // B is a direct scroll child and scrolls in UIScrollView's content
        // coordinates. No inset/offset compensation is applied.
        barMarkerRoot.frame = CGRect(x: 70, y: candidateScroll.frame.minY + 5, width: 24, height: 24)
        barMarkerScroll.frame = CGRect(x: 38, y: 5, width: 24, height: 24)
    }

    /// 実機診断 (build 44〜47): 候補欄のピクセル側の状態を取るトレース。
    /// build 48: ユーザー指示により固定長でコンパクト化した。build 44〜47 の
    /// 形式は祖先チェーン全ダンプ (transform 行列等) で1イベントが1万字を
    /// 超えていたため廃止し、判定に必要な最小フィールドだけを残す
    /// (1イベント数百文字以内)。build 47 で model/presentation・inset・
    /// offset は全て正常と確定済みなので、それらの採取もやめた。
    /// Layout は差分のみ、render と約0.5秒後のペアは同値でも両方残す。
    private func traceBarGeometry(source: String, force: Bool = false) {
        func rect(_ r: CGRect) -> String {
            String(format: "%.0f,%.0f,%.0f,%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height)
        }
        func winRect(of v: UIView) -> String {
            v.window.map { rect(v.convert(v.bounds, to: $0)) } ?? "nil"
        }
        var parts: [String] = []
        parts.append("rev=\(revision)")
        parts.append("heightC=\(heightConstraint.map { String(format: "%.0f", $0.constant) } ?? "nil")")
        parts.append("scroll.frame=\(rect(candidateScroll.frame))")
        parts.append("scroll.hidden=\(candidateScroll.isHidden)")
        parts.append("scroll.size=\(String(format: "%.0f,%.0f", candidateScroll.contentSize.width, candidateScroll.contentSize.height))")
        parts.append("keys=\(candidateKeys.count)")
        if let key = candidateKeys.first {
            parts.append("key0.frame=\(rect(key.frame))")
            parts.append("key0.win=\(winRect(of: key))")
            parts.append("key0.title=\(key.currentTitle ?? "nil")")
        } else {
            parts.append("key0=none")
        }
        parts.append("mA.win=\(winRect(of: barMarkerRoot))")
        parts.append("mB.win=\(winRect(of: barMarkerScroll))")
        let signature = parts.joined(separator: " ")
        guard force || signature != lastBarGeometrySignature else { return }
        lastBarGeometrySignature = signature
        DiagTrace.shared.record(event: "bar.geometry", detail: "src=\(source) " + signature)
    }
    /// 計測オーバーレイの表示を最新の集計に更新する（開発段階のみ）。
    private func updatePerfOverlay() {
        guard PerfProbe.enabled else { return }
        let summary = PerfProbe.shared.summary()
        // 集計が空でも帯が見えること自体が診断情報になるため、空文字にはしない。
        perfLabel.text = summary.isEmpty ? "PerfProbe: 計測待ち" : summary
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
        var merged = lexicon.suggestions(for: typed.lowercased())
        // 辞書パックの英数字パターン (そのまま型) も補完の末尾に足す。
        for extra in dictionaryLibrary.patternCompletions(forTyped: typed, store: dictionaryStore) where !merged.contains(extra) {
            merged.append(extra)
        }
        englishSuggestions = Array(merged.prefix(10))
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
        if let selected, candidates.indices.contains(selected) { commit(candidates[selected], learn: shouldLearn(candidates[selected])) }
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
