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
final class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate {
    var settings = KeyboardSettings()
    var documentOverride: KeyboardDocument?
    private lazy var editor = MarkedTextSession { [unowned self] in
        self.documentOverride ?? ProxyDocument(self.textDocumentProxy)
    }
    private let service = ConversionService()
    private var composition = ComposingText()
    /// LM v3 の文脈条件付け用に、このキーボード自身が確定したテキストを
    /// 追跡する (ホストの documentContext を打鍵ごとに読み直す往復を避ける
    /// ため)。変換確定のたびに伸び、外部編集・カーソル移動でリセットする。
    private var committedContext = ""
    private var candidates: [String] = []
    private var selected: Int?
    private var shifted = false
    private var capsLocked = false
    private var symbols = false
    /// B案: 日本語モードで Shift を押して大文字から打ち始めた単語の入力中。
    /// この間、英字はかな変換を通さず .direct で組成に入り、候補は入力
    /// そのままだけになる。確定・削除し切り・外部リセットで解除される。
    /// 状態遷移そのものは EnglishWordMode (テスト可能部品) が持つ。
    private var englishWordTracker = EnglishWordMode()
    private var englishWordMode: Bool {
        get { englishWordTracker.isActive }
        set { if !newValue { englishWordTracker.reset() } }
    }
    /// 記号画面で括弧キーを押した直後に帯へ出す括弧の変換候補。
    /// 選ぶと、挿入済みの括弧がその種類へ置き換わる。
    private var bracketCandidates: [String] = []
    private var revision = 0
    private var conversionReady = false
    private var waitingSpaceCount = 0
    private var conversionTask: Task<Void, Never>?
    private var deleteTimer: Timer?
    /// ルート高さ制約（優先度999）。定数は updateRequestedHeight() が
    /// 更新する（単一の公開地点）。ビルド54で高さ方式をビルド45の構成に
    /// 戻した：プレーンなルートビュー + この制約のみで交渉する
    /// （詳細は updateRequestedHeight のコメント参照）。
    private var heightConstraint: NSLayoutConstraint?
    private let canvas = KeyboardCanvas()
    private let flickCanvas = FlickCanvas()
    /// フリック面が有効な状態か (設定 ON かつ日本語モード)。英数と記号面
    /// ではフリック設定でも QWERTY 面を使う (フリックは日本語専用)。
    private var flickActive: Bool { settings.snapshot.flickMode && isJapanese && !symbols }
    private var activeSurface: KeyboardSurface { flickActive ? flickCanvas : canvas }
    /// 候補帯のコンテナ（build 58: UIScrollView を廃止）。
    /// build 56 まで帯は UIScrollView で、中身を手動フレーム＋手動
    /// contentSize にしても「帯に触れると候補の表示だけが消える
    /// （ヒットテストと確定は生きている）」「横スクロールできない」
    /// 症状が残った。スクロールビュー内部のレイヤ構造がこのホスト
    /// （iOS 27 のリモート描画）と相性が悪いと判断し、帯はプレーンな
    /// UIView（他パネルと同じ素性）に変え、横スクロールは
    /// UIPanGestureRecognizer で候補キーのフレームを手動でずらす
    /// 自前実装にした。帯の中に Auto Layout は持ち込まない。
    private let candidateStrip = UIView()
    /// 候補帯の横スクロール用パン認識器（build 58）。
    private let candidatePan = UIPanGestureRecognizer()
    /// 候補帯のスクロールオフセット（pt、0 = 左端）。
    private var stripContentOffsetX: CGFloat = 0
    /// 候補コンテンツの総幅（renderState の配置で更新）。
    private var stripContentWidth: CGFloat = 0
    /// パン開始時点のオフセット（ドラッグ量の基準）。
    private var stripPanBase: CGFloat = 0
    /// 候補帯スクロールの慣性減速（build 59）。パン終了時点のオフセット
    /// 方向速度（pt/s、正 = コンテンツが左へ進む方向）。0 なら減速なし。
    private var stripDecelVelocity: CGFloat = 0
    /// 慣性減速を駆動する DisplayLink（減速中のみ有効）。
    private var stripDisplayLink: CADisplayLink?
    /// 減速の前フレーム時刻（dt 算出用）。
    private var stripLastFrameTime: CFTimeInterval = 0
    /// 下段の予測専用帯 (build 88 の二段構成)。候補バー (上段) の直下に
    /// 置き、辞書パックの前方一致予測だけを表示する。構造は上段と同じ
    /// プレーンな UIView + 手動フレーム + パン自前実装で、帯の中に
    /// Auto Layout は持ち込まない (上段と同じ理由)。
    private let predictionStrip = UIView()
    /// 予測帯の横スクロール用パン認識器。
    private let predictionPan = UIPanGestureRecognizer()
    /// 予測帯のスクロールオフセット（pt、0 = 左端）。
    private var predictionContentOffsetX: CGFloat = 0
    /// 予測コンテンツの総幅（renderPredictionStrip の配置で更新）。
    private var predictionContentWidth: CGFloat = 0
    /// パン開始時点のオフセット（ドラッグ量の基準）。
    private var predictionPanBase: CGFloat = 0
    /// 予測帯スクロールの慣性減速（上段と同じ指数減衰方式）。
    private var predictionDecelVelocity: CGFloat = 0
    private var predictionDisplayLink: CADisplayLink?
    private var predictionLastFrameTime: CFTimeInterval = 0
    /// 予測帯のキー（上段の candidateKeys と対）。
    private var predictionKeys: [CandidateKey] = []
    /// 予測キーへ最後に適用したパレット。
    private var predictionPaletteApplied: KeyboardPalette?
    /// 前回描画した予測の値（変わったときだけオフセットを左端に戻す）。
    private var lastPredictionValues: [String] = []
    /// 下段に出す前方一致予測 (insertPackExtras が変換完了のたびに更新)。
    /// 上段の候補列には混ぜない。空なら帯は空欄になるだけで枠は残る。
    private var predictedCandidates: [String] = []
    /// 高さ交渉のための Auto Layout 足場（不可視の sizer view）。
    /// build 53 で候補帯内に置いたが、ビルド56でルート直下へ移した。
    /// 足場は帯の外でルート階層の Auto Layout 参加だけを担い、帯の
    /// 高さには candidateStrip の height と等しくして連動させる。
    private let candidateSizer = UIView()
    /// 候補バーの高さ（表示時）。帯の高さはこの定数を唯一の情報源とし、
    /// 要求高さ・帯のフレーム・キャンバスの原点はすべて layoutMetrics の
    /// 同じ計算結果から決める（build 50: 帯の表示/非表示で全体が帯の分だけ
    /// 下にずれて最下段が切れる不具合の修正）。
    private let candidateStripHeight: CGFloat = 34
    /// 下段の予測帯の高さ (build 88)。上段と同じクラスに収める。
    private let predictionStripHeight: CGFloat = 30
    /// 帯が占める高さ。2026-11-26 のユーザー決定で、候補バーは候補の
    /// 有無によらず両面とも常時表示とし、高さを固定する（入力中に
    /// レイアウトが変動しないようにする）。候補が無いとき帯は空欄に
    /// なるだけで、枠そのものは出し続ける。2026-11-27 以降はフリック
    /// 面のポップアップがこの帯の領域へ被さって出る (高さは不変)。
    /// build 88 で下段の予測帯が加わり、日本語モードでは上段+下段の
    /// 合計を常時予約する (予測の有無で高さが跳ねないようにするため)。
    /// 英語モードに予測帯は無いので、その分の高さは言語切替のときに
    /// だけ変わる (入力の途中では変わらない)。
    private var currentCandidateHeight: CGFloat {
        candidateStripHeight + (isJapanese ? predictionStripHeight : 0)
    }
    // build 48: candidateStack コンテナは廃止。候補キーは候補帯コンテナ
    // （build 58 で candidateStrip）の直下に直接置く
    // (詳細は renderState の配置ブロックのコメント参照)。
    private var candidateKeys: [CandidateKey] = []
    /// 開発段階の計測オーバーレイ（PerfProbe の集計を候補欄の上に重ねて表示）。
    private let perfLabel = UILabel()
    /// 候補キーへ最後に適用したパレット。変わったときだけ全キーの色を
    /// 付け直す（renderState は打鍵のたびに走るため、毎回は付け直さない）。
    private var candidatePaletteApplied: KeyboardPalette?
    /// アイドル時に候補帯の右端へ出すペーストボタン（build 95、96で
    /// アイコンのみに簡素化）。候補が無く組成も無いときだけ現れる。
    /// 帯は常時表示・高さ固定なので、出し入れで全体のレイアウトは
    /// 動かない。実体は候補帯の子として置き、配置は layoutPasteButton
    /// が右端に寄せる。中身の有無は見ず、空ならタップしても何も起きない。
    private let pasteButton = UIButton(type: .custom)
    /// ボタンへ最後に適用したパレット（候補キーと同じ作法）。
    private var pastePaletteApplied: KeyboardPalette?
    /// 着せ替えの実効パレット（rebuildCanvas のたびに設定から解決する）。
    /// OFF では現行色と一致する standard になる。
    private var currentPalette = KeyboardPalette.standard(dark: true)
    /// 背景画像（着せ替え）の表示先。ルート直下に敷き、その上に重ね
    /// ビュー（背景色のスクリム）を置いてキー文字の読みやすさを調整する。
    /// キャンバス側は画像使用時に透明になり、この画像が全面に見える。
    /// 画像は拡大・位置調整ではみ出すため、クリップ用のコンテナに入れる。
    private let backgroundClipView = UIView()
    private let backgroundImageView = UIImageView()
    private let backgroundScrimView = UIView()
    /// 読み込み済みの背景画像のファイル名（同じ画像を再読込しないため）。
    private var loadedBackgroundImageName: String?
    /// 表示中の背景画像に適用する見た目設定（拡大率・位置を含む）。
    /// レイアウト時に CustomAppearance.backgroundImageRect へ渡す。
    private var backgroundAppearance: CustomAppearance?
    // 定型文はキーボード拡張自身の保存領域で完結させる（PhraseStore 参照）。
    private lazy var phraseStore = PhraseStore(legacyPhrases: { KeyboardViewController.legacySharedPhrases() })
    private let clipboardStore = ClipboardHistoryStore()
    private var englishLexicon: EnglishLexicon?
    private var englishSuggestions: [String] = []
    private var englishExtraValues: Set<String> = []
    private let dictionaryStore = DictionaryPackStore()
    private let dictionaryLibrary = DictionaryPackLibrary()
    private let selectionHistory = SelectionHistoryStore()
    private var packExtraValues: Set<String> = []
    private var pendingAutocorrectUndo: (original: String, corrected: String, delimiter: String)?
    private var activeDocument: KeyboardDocument { documentOverride ?? ProxyDocument(textDocumentProxy) }
    private var captureDocument: BufferDocument?
    private var isCapturing: Bool { captureDocument != nil }
    /// 編集中の定型文の位置（新規登録なら nil）。
    private var captureEditingIndex: Int?
    private var captureText = ""
    private var captureCursorOffset = 0
    private var captureCursorVisible = true
    private var captureBlinkTimer: Timer?
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
    // 販売ビルド: 有料機能（定型文・クリップボード履歴・辞書パック）が
    // 使えるか。体験期間終了後は false になり、各機能の入口でのみ案内を
    // 出す（2026-11-26 仕様変更: 全面ロックアウト廃止）。基本入力はこの
    // フラグに一切影響されない。既定は true（判定前・判定失敗時は
    // PurchaseGate のフェイルオープンと合わせて機能を止めない）。
    private var premiumFeaturesEnabled = true
    private let clipboardStack = UIStackView()
    private let clipboardClearButton = UIButton(type: .system)
    private var isClipboardPicking = false
    private weak var openClipboardRow: PhraseRowView?
    private var isJapanese: Bool { settings.japanese }

    // build 54: loadView は上書きしない。ルートビューは
    // UIInputViewController 既定のプレーンなビューのままにし、高さは
    // viewDidLoad で付ける優先度999の制約だけで交渉する（ビルド45の
    // 構成）。ビルド52/53の KeyboardInputView（UIInputView サブクラス +
    // systemLayoutSizeFitting / intrinsicContentSize 上書き）は、実機で
    // 「セッション中の高さ増加（261→295）が反映されない」症状が出た
    // ため廃止した（ビルド53のCSV: 帯なし c=261→b=261 は一致するが、
    // 帯あり c=295 でも b=261 のまま）。Auto Layout 足場（candidateSizer）
    // はビルド56で帯の中からルート直下へ移設した（理由は candidateSizer
    // のコメント参照）。
    override func viewDidLoad() {
        super.viewDidLoad()
        // 着せ替えの背景画像は一番下に敷く。以後に追加される帯・パネル・
        // キャンバスはすべてこの上に載る。画像とスクリムは操作を受けない。
        // 画像のフレームは拡大率・位置で決まるため contentMode は使わず、
        // はみ出しはクリップ用コンテナで切る。
        backgroundClipView.clipsToBounds = true
        backgroundClipView.isUserInteractionEnabled = false
        backgroundClipView.isHidden = true
        view.addSubview(backgroundClipView)
        backgroundImageView.contentMode = .scaleToFill
        backgroundImageView.isUserInteractionEnabled = false
        backgroundClipView.addSubview(backgroundImageView)
        backgroundScrimView.isUserInteractionEnabled = false
        backgroundScrimView.isHidden = true
        view.addSubview(backgroundScrimView)
        // 変換時間の計測は PerfProbe に集約する (ConversionService 側のコメント参照)。
        ConversionService.perfSink = { name, ms in PerfProbe.shared.recordElapsed(name, ms: ms) }
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
        // build 58: 候補帯はプレーンな UIView。はみ出した候補は
        // clipsToBounds で切り、横スクロールはパン認識器でキー
        // フレームをずらして実現する（candidateStrip のコメント参照）。
        // ドラッグが始まったら候補ボタンのタッチはキャンセルされ、
        // 候補選択は従来どおり離したタップ（touchUpInside）でのみ発火
        // する（cancelsTouchesInView = true）。縦ドラッグは開始しない
        // （gestureRecognizerShouldBegin で横方向だけに絞る。旧
        // UIScrollView の directional lock 相当）。
        view.addSubview(candidateStrip)
        candidateStrip.clipsToBounds = true
        candidatePan.addTarget(self, action: #selector(handleCandidatePan(_:)))
        candidatePan.cancelsTouchesInView = true
        candidatePan.delegate = self
        candidateStrip.addGestureRecognizer(candidatePan)
        // 下段の予測帯も上段と同じ素性 (プレーンな UIView + パン自前
        // 実装)。キーは renderPredictionStrip で帯の直下に直接置く。
        view.addSubview(predictionStrip)
        predictionStrip.clipsToBounds = true
        predictionPan.addTarget(self, action: #selector(handlePredictionPan(_:)))
        predictionPan.cancelsTouchesInView = true
        predictionPan.delegate = self
        predictionStrip.addGestureRecognizer(predictionPan)
        // ペーストボタン（build 95、96でアイコンのみに簡素化）。候補キー
        // と同じ .custom で作り、色は候補文字色に追随させる。初期状態は
        // 非表示で、表示の判断は updatePasteButton が担う。
        pasteButton.isHidden = true
        pasteButton.tintColor = currentPalette.candidateText.uiColor
        pasteButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        pasteButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 15), forImageIn: .normal)
        pasteButton.accessibilityIdentifier = "pasteButton"
        pasteButton.accessibilityLabel = "ペースト"
        pasteButton.addTarget(self, action: #selector(pasteButtonTapped), for: .touchUpInside)
        candidateStrip.addSubview(pasteButton)
        // build 56/58: 高さ交渉用の Auto Layout 足場（不可視の sizer）は
        // 候補帯の中ではなくルート直下に置く（candidateSizer のコメント
        // 参照）。帯の高さに連動させるため height は candidateStrip の
        // height と等しくする。sizer は操作を受けず、背景も透明で、
        // レイアウトには一切影響しない（幅0・左上固定）。
        candidateSizer.backgroundColor = .clear
        candidateSizer.isUserInteractionEnabled = false
        candidateSizer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(candidateSizer)
        NSLayoutConstraint.activate([
            candidateSizer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            candidateSizer.topAnchor.constraint(equalTo: view.topAnchor),
            candidateSizer.widthAnchor.constraint(equalToConstant: 0),
            candidateSizer.heightAnchor.constraint(equalTo: candidateStrip.heightAnchor),
        ])
        // build 48: build 47 の実機診断で、scroll 直下のマーカー B とルート直下の
        // マーカー A は表示されるのに、コンテナ candidateStack の子 (マーカー C と
        // 候補キー) だけが一切合成されないことが確定した。CSV 上は stack の
        // frame/win/hidden/alpha も key0 の model/presentation も全て正常。
        // build 46 で UIStackView → 素の UIView + 手動フレームに替えても中身が
        // 出なかったため、コンテナそのものを廃止し、候補キーは renderState で
        // 候補帯の直下に直接配置する（build 58 で帯は candidateStrip）。
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
        canvas.configureSwitchKey = { [weak self] button in
            guard let self else { return }
            // システム標準の入力モード切替にそのまま配線する: タップで次の
            // キーボード、長押しでキーボード一覧 (iPad 専用キー)。
            button.addTarget(self, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        canvas.configureMenu = { [weak self] button in self?.configureMenu(button) }
        canvas.configureSpaceMenu = { [weak self] button in self?.configureSpaceMenu(button) }
        view.addSubview(flickCanvas)
        // フリックのポップアップは候補バー側へ被さるため、ルートビューを
        // 載せ先にする (キャンバス内に閉じ込めない)。
        flickCanvas.popupHost = view
        flickCanvas.isHidden = true
        flickCanvas.onText = { [weak self] in self?.insertFlick($0) }
        flickCanvas.onAction = { [weak self] in self?.handle($0) }
        flickCanvas.onDeleteHold = { [weak self] in self?.repeatDelete($0) }
        flickCanvas.onDakuten = { [weak self] in self?.applyDakuten() }
        flickCanvas.onEmoji = { [weak self] in self?.showEmojiPanel() }
        flickCanvas.onLanguage = { [weak self] in
            guard let self else { return }
            // 長押しで定型文パネルを開いた直後の離しタップは切替にしない
            // (スペースキーの既存ガードと同じ作法)。
            if let opened = self.pickerOpenedAt, Date().timeIntervalSince(opened) < 0.6 { return }
            self.setLanguage(false)
        }
        flickCanvas.onLanguageHold = { [weak self] in
            guard let self, !self.isCapturing else { return }
            self.pickerOpenedAt = Date()
            self.showPhrasePicker()
        }
        flickCanvas.onSymbols = { [weak self] in
            // ☆123: QWERTY の記号面へ直行する (純正フリックのみモードの
            // タブと同じ役目)。戻りは記号面の「ABC」キーと言語切替。
            guard let self, !self.symbols else { return }
            self.symbols = true
            self.rebuildCanvas()
        }
        flickCanvas.configureSwitchKey = { [weak self] button in
            guard self != nil else { return }
            button.addTarget(self, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        Task { await service.warmUp() }
        refreshPurchaseState()
        rebuildCanvas()
        // ルート高さ制約（優先度999、ビルド45と同じ付け方）。初期値は
        // 仮置きで、直後の updateRequestedHeight() が layoutMetrics の
        // 実計算値に更新する。以降も状態が変わるたびに同じ入口が
        // 候補バーの有無込みで公開し続ける。
        let height = view.heightAnchor.constraint(equalToConstant: 270)
        height.priority = .init(999); height.isActive = true; heightConstraint = height
        updateRequestedHeight()
    }

    /// 購入/トライアル状態を判定し直し、有料機能の可否だけを更新する。
    /// 基本入力には一切触れない。読み取りに失敗した場合は PurchaseGate 側の
    /// フェイルオープンで trial 扱いになるため、機能が誤って止まることはない。
    private func refreshPurchaseState() {
        premiumFeaturesEnabled = PurchaseGate.evaluateForDisplay().premiumFeaturesEnabled
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
        phraseReorderToggle.setTitle("編集・並び替え", for: .normal)
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
        // 組み立て直後は現在の着せ替え設定でタイトル色を合わせておく
        // (rebuildCanvas 経由の refreshAppearance はパネル未構築だと素通りする)。
        applyPanelTextColors()
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
        // 設定（キー高さ・記号モード等）で合計高さが変わりうるので、表示前に
        // 現在の状態の要求高さを公開しておく（build 50）。出現時は値が
        // 同じでも定数をセットし直して、ホスト側に再測定させる。
        updateRequestedHeight(force: true)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isCapturing { endCapture(save: false) }
        stopDelete()
        syncHostChange(); commitCurrent()
        editor.finish()
        resetComposition()
    }
    /// レイアウト寸法の一括計算結果。要求高さ・候補バーのフレーム・
    /// キャンバスの原点はすべてこの1回の計算から決める。
    private struct LayoutMetrics {
        var capturePanelHeight: CGFloat
        var phrasePanelHeight: CGFloat
        var clipboardPanelHeight: CGFloat
        var emojiPanelHeight: CGFloat
        var topHeight: CGFloat
        var perfHeight: CGFloat
        var candidateHeight: CGFloat
        var keysHeight: CGFloat
        var totalHeight: CGFloat
    }

    /// 現在の状態に対するレイアウト寸法を計算する（build 50）。
    /// 合計高さは「実際に配置するフレームの合計」そのものとし、状態の
    /// 純粋な関数にする。以前は合計に view.safeAreaInsets.bottom を加えて
    /// いたが、初期高さ（viewDidLoad）の式には含まれておらず、提示の
    /// タイミングで変わりうる値を要求高さに混ぜると、配置済みフレームの
    /// 合計と要求高さが食い違って実フレーム高さと要求高さが乖離する一因になる。
    /// パネル高さの予算計算からも同様に外した（帯・キー列との合算で
    /// 画面の約6割に収まる性質は変わらない）。
    private func layoutMetrics(width: CGFloat) -> LayoutMetrics {
        let keysHeight = activeSurface.preferredHeight(width: width)
        let candidateHeight = currentCandidateHeight
        var capturePanelHeight: CGFloat = 0
        if isCapturing {
            let budget = UIScreen.main.bounds.height * 0.62
            capturePanelHeight = max(150, budget - candidateHeight - keysHeight)
        }
        var phrasePanelHeight: CGFloat = 0
        if isPicking && !isCapturing {
            let budget = UIScreen.main.bounds.height * 0.62
            phrasePanelHeight = max(200, budget - candidateHeight - keysHeight)
        }
        var clipboardPanelHeight: CGFloat = 0
        if isClipboardPicking && !isCapturing && !isPicking {
            let budget = UIScreen.main.bounds.height * 0.62
            clipboardPanelHeight = max(200, budget - candidateHeight - keysHeight)
        }
        var emojiPanelHeight: CGFloat = 0
        if isEmojiPicking && !isCapturing && !isPicking && !isClipboardPicking {
            let budget = UIScreen.main.bounds.height * 0.62
            emojiPanelHeight = max(200, budget - candidateHeight - keysHeight)
        }
        let topHeight = capturePanelHeight + phrasePanelHeight + clipboardPanelHeight + emojiPanelHeight
        let perfHeight: CGFloat = (PerfProbe.enabled && topHeight == 0) ? 16 : 0
        let totalHeight = topHeight + perfHeight + candidateHeight + keysHeight
        return LayoutMetrics(capturePanelHeight: capturePanelHeight,
                             phrasePanelHeight: phrasePanelHeight,
                             clipboardPanelHeight: clipboardPanelHeight,
                             emojiPanelHeight: emojiPanelHeight,
                             topHeight: topHeight, perfHeight: perfHeight,
                             candidateHeight: candidateHeight, keysHeight: keysHeight,
                             totalHeight: totalHeight)
    }

    /// 要求高さを現在の状態の値に合わせてルートビューへ公開する
    /// （高さの公開はここが唯一の入口）。build 54 ではビルド45の方式に
    /// 戻し、優先度999の高さ制約の定数を更新するだけにする
    /// （KeyboardInputView の fitting 上書きは廃止）。
    /// 帯の表示/非表示が切り替わったその場（renderState）からも呼ぶことで、
    /// 高さの変更要求がレイアウトパスの完了を待たず、状態変化と同じ
    /// ターンでホストへ伝わる。force のときは値が同じでも定数を
    /// セットし直して再レイアウトを促す。
    private func updateRequestedHeight(force: Bool = false) {
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let total = layoutMetrics(width: width).totalHeight
        if force || abs((heightConstraint?.constant ?? 0) - total) > 0.5 {
            heightConstraint?.constant = total
            view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        // 寸法は1回だけ計算し、要求高さはフレーム配置より先に同じ値で
        // 公開する（build 50: 以前は高さの更新がレイアウト末尾で、配置済み
        // フレームと要求高さが別々に決まっていた）。
        let metrics = layoutMetrics(width: width)
        let keysHeight = metrics.keysHeight
        let candidateHeight = metrics.candidateHeight
        updateRequestedHeight()
        // 背景画像とスクリムはキーボード全面に敷く。画像のフレームは
        // 保存された拡大率・位置から決める (未調整では従来の全面/全体
        // 表示と一致する)。QWERTY 面・フリック面ともキャンバスが透明に
        // なり、このルート側の画像がそのまま見える。
        if !backgroundClipView.isHidden {
            backgroundClipView.frame = view.bounds
            backgroundScrimView.frame = view.bounds
            if let image = backgroundImageView.image, let appearance = backgroundAppearance {
                backgroundImageView.frame = CustomAppearance.backgroundImageRect(
                    containerSize: view.bounds.size, imageSize: image.size,
                    fillsScreen: appearance.backgroundImageFillsScreen,
                    scale: appearance.backgroundImageScale,
                    offsetX: appearance.backgroundImageOffsetX,
                    offsetY: appearance.backgroundImageOffsetY)
            } else {
                backgroundImageView.frame = view.bounds
            }
        }
        // 登録中はキーボード全体を画面の約6割まで広げ、その大半を定型文の枠に充てる。
        // 完全な全画面は拡張の仕様上できないため、これが上限の目安。
        // パネル高さは layoutMetrics で計算済み（ここでは配置だけを行う）。
        let capturePanelHeight = metrics.capturePanelHeight
        capturePanel.isHidden = !isCapturing
        if isCapturing {
            capturePanel.backgroundColor = currentPalette.panelBackground.uiColor
            capturePanel.layer.borderColor = currentPalette.panelBorder.uiColor.cgColor
            capturePanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, capturePanelHeight - 12))
            let panelWidth = capturePanel.bounds.width
            let panelHeight = capturePanel.bounds.height
            captureTitle.frame = CGRect(x: 12, y: 8, width: max(0, panelWidth - 24), height: 18)
            captureButtonRow.frame = CGRect(x: 12, y: max(30, panelHeight - 50), width: max(0, panelWidth - 24), height: 42)
            captureDisplay.frame = CGRect(x: 12, y: 30, width: max(0, panelWidth - 24), height: max(0, panelHeight - 30 - 56))
        }
        let phrasePanelHeight = metrics.phrasePanelHeight
        phrasePanel.isHidden = !isPicking
        if isPicking && !isCapturing {
            phrasePanel.backgroundColor = currentPalette.panelBackground.uiColor
            phrasePanel.layer.borderColor = currentPalette.panelBorder.uiColor.cgColor
            phrasePanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, phrasePanelHeight - 12))
            let panelWidth = phrasePanel.bounds.width
            let panelHeight = phrasePanel.bounds.height
            phraseTitle.frame = CGRect(x: 12, y: 10, width: 200, height: 28)
            phraseCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            phraseScroll.frame = CGRect(x: 8, y: 48, width: max(0, panelWidth - 16), height: max(0, panelHeight - 48 - 50))
            phraseAddButton.frame = CGRect(x: 12, y: max(0, panelHeight - 46), width: 160, height: 38)
            phraseReorderToggle.frame = CGRect(x: max(0, panelWidth - 142), y: max(0, panelHeight - 46), width: 130, height: 38)
            // 有料機能が無効な間は、追加・編集の入口自体を出さない
            // （パネル本体には購入案内の行だけが出る）。
            phraseAddButton.isHidden = !premiumFeaturesEnabled
            phraseReorderToggle.isHidden = !premiumFeaturesEnabled
        }
        let clipboardPanelHeight = metrics.clipboardPanelHeight
        clipboardPanel.isHidden = !isClipboardPicking
        if isClipboardPicking && !isCapturing && !isPicking {
            clipboardPanel.backgroundColor = currentPalette.panelBackground.uiColor
            clipboardPanel.layer.borderColor = currentPalette.panelBorder.uiColor.cgColor
            clipboardPanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, clipboardPanelHeight - 12))
            let panelWidth = clipboardPanel.bounds.width
            let panelHeight = clipboardPanel.bounds.height
            clipboardTitle.frame = CGRect(x: 12, y: 10, width: 200, height: 28)
            clipboardCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            clipboardScroll.frame = CGRect(x: 8, y: 48, width: max(0, panelWidth - 16), height: max(0, panelHeight - 48 - 50))
            clipboardClearButton.frame = CGRect(x: max(0, panelWidth - 112), y: max(0, panelHeight - 46), width: 100, height: 38)
            // 有料機能が無効な間は全削除も履歴機能の一部として隠す。
            clipboardClearButton.isHidden = !premiumFeaturesEnabled
        }
        let emojiPanelHeight = metrics.emojiPanelHeight
        emojiPanel.isHidden = !isEmojiPicking
        if isEmojiPicking && !isCapturing && !isPicking && !isClipboardPicking {
            emojiPanel.backgroundColor = currentPalette.panelBackground.uiColor
            emojiPanel.layer.borderColor = currentPalette.panelBorder.uiColor.cgColor
            emojiPanel.frame = CGRect(x: 8, y: 6, width: max(0, width - 16), height: max(0, emojiPanelHeight - 12))
            let panelWidth = emojiPanel.bounds.width
            let panelHeight = emojiPanel.bounds.height
            emojiTitle.frame = CGRect(x: 12, y: 10, width: 200, height: 28)
            emojiCloseButton.frame = CGRect(x: max(0, panelWidth - 52), y: 6, width: 40, height: 36)
            emojiCategoryScroll.frame = CGRect(x: 8, y: 44, width: max(0, panelWidth - 16), height: 36)
            emojiScroll.frame = CGRect(x: 8, y: 86, width: max(0, panelWidth - 16), height: max(0, panelHeight - 86 - 8))
        }
        let topHeight = metrics.topHeight
        // PerfProbe の帯は候補欄の上に専用スペースを確保する。重ね表示だと
        // 候補のボタンやホスト側の角丸に隠れて見えないことがあったため。
        // パネル表示中は帯ごと隠す。
        let perfHeight = metrics.perfHeight
        if PerfProbe.enabled {
            perfLabel.isHidden = perfHeight == 0
            if perfHeight > 0 { perfLabel.frame = CGRect(x: 0, y: topHeight, width: width, height: perfHeight) }
            view.bringSubviewToFront(perfLabel)
            updatePerfOverlay()
        }
        // 候補バーは二段とも常時表示 (candidateHeight は上段+下段の合計。
        // 日本語モードでは予測の有無によらず下段の枠も予約する)。
        // 英語モードでは下段が無く、その分は candidateHeight に含まれない。
        candidateStrip.isHidden = false
        candidateStrip.frame = CGRect(x: 0, y: topHeight + perfHeight, width: width, height: candidateStripHeight)
        let predictionHeight = candidateHeight - candidateStripHeight
        predictionStrip.isHidden = !isJapanese
        predictionStrip.frame = CGRect(x: 0, y: topHeight + perfHeight + candidateStripHeight,
                                       width: width, height: predictionHeight)
        // ペーストボタンは候補帯の子。帯のフレームが決まった後に
        // 表示可否と右端配置を合わせる（build 95）。
        updatePasteButton()
        let canvasFrame = CGRect(x: 0, y: topHeight + perfHeight + candidateHeight, width: width, height: keysHeight)
        canvas.frame = canvasFrame
        flickCanvas.frame = canvasFrame
        // 要求高さは関数の先頭で metrics.totalHeight に公開済み。
        // 配置したフレームの合計と常に一致する（build 50）。
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
        if editor.hostDidChange() { committedContext = ""; resetComposition() }
    }
    private func rebuildCanvas() {
        let snapshot = settings.snapshot
        overrideUserInterfaceStyle = snapshot.theme == 1 ? .light : snapshot.theme == 2 ? .dark : .unspecified
        refreshAppearance()
        canvas.isHidden = flickActive
        flickCanvas.isHidden = !flickActive
        activeSurface.configure(snapshot, shifted: shifted, symbols: symbols, japanese: isJapanese)
        activeSurface.setJapaneseMode(isJapanese)
        activeSurface.updateShift(shifted, caps: capsLocked)
        renderState(updateMarked: false)
        view.setNeedsLayout()
    }
    /// 実効パレットと背景画像を現在の設定へ合わせる。パネル・候補バーの
    /// 色は currentPalette を参照して描く側 (レイアウト/renderState) が
    /// 付けるため、ここではルートの背景と画像まわりだけを確定させる。
    /// OFF ではパレットは現行色の standard になり、画像は隠れる。
    private func refreshAppearance() {
        let snapshot = settings.snapshot
        // パネル類の従来判定 (== .light か否か) と同じ物差しで明暗を決める。
        let dark = traitCollection.userInterfaceStyle != .light
        currentPalette = snapshot.resolvedPalette(dark: dark)
        view.backgroundColor = currentPalette.background.uiColor
        if snapshot.usesBackgroundImage, let name = snapshot.customAppearance.backgroundImageFileName {
            if loadedBackgroundImageName != name {
                backgroundImageView.image = KeyboardBackgroundImageStore.loadImage(fileName: name)
                loadedBackgroundImageName = name
            }
            // 拡大率・位置はレイアウト時にフレームへ反映する。
            backgroundAppearance = snapshot.customAppearance
            backgroundClipView.isHidden = false
            backgroundScrimView.backgroundColor = currentPalette.background.uiColor
            backgroundScrimView.alpha = CGFloat(snapshot.customAppearance.backgroundImageDim)
            backgroundScrimView.isHidden = false
        } else {
            backgroundClipView.isHidden = true
            backgroundScrimView.isHidden = true
            backgroundAppearance = nil
            if loadedBackgroundImageName != nil {
                loadedBackgroundImageName = nil
                backgroundImageView.image = nil
            }
        }
        applyPanelTextColors()
    }
    /// パネルのタイトル文字色。パネル文字色が明示的にピックされた場合に
    /// だけその色を付け、未ピック時は従来どおりシステムのラベル色
    /// (タイトルは動的色、登録タイトルは secondaryLabel) のままにする
    /// (OFF 等価性を壊さないため)。
    private func applyPanelTextColors() {
        guard panelsBuilt else { return }
        let snapshot = settings.snapshot
        let explicit = snapshot.customizationEnabled ? snapshot.customAppearance.panelText?.uiColor : nil
        phraseTitle.textColor = explicit
        clipboardTitle.textColor = explicit
        emojiTitle.textColor = explicit
        captureTitle.textColor = explicit ?? .secondaryLabel
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
        // クリップボード履歴が有料機能として無効な間は、取り込み自体も止める
        // （changeCount も進めないので、購入後はその時点の内容から再開する）。
        guard premiumFeaturesEnabled else { return }
        guard hasFullAccess else { return }
        let pasteboard = UIPasteboard.general
        let last = UserDefaults.standard.integer(forKey: Self.clipboardChangeCountKey)
        guard pasteboard.changeCount != last else { return }
        UserDefaults.standard.set(pasteboard.changeCount, forKey: Self.clipboardChangeCountKey)
        if let text = pasteboard.string { clipboardStore.record(text) }
    }
    /// ペーストボタンの表示可否を現在の状態へ合わせる（build 95）。
    /// 出すのは「組成が無く、候補帯が空で、どのパネルも開いていない」
    /// アイドル時だけ。クリップボードの中身は見ない（空でも出す）。
    /// 読み取りはタップされた瞬間だけ。
    private func updatePasteButton() {
        let stripEmpty = bracketCandidates.isEmpty
            && (isJapanese ? candidates.isEmpty : englishSuggestions.isEmpty)
        let idle = composition.isEmpty && stripEmpty
            && !isPicking && !isClipboardPicking && !isEmojiPicking && !isCapturing
        guard idle else { pasteButton.isHidden = true; return }
        if pastePaletteApplied != currentPalette {
            pasteButton.tintColor = currentPalette.candidateText.uiColor
            pastePaletteApplied = currentPalette
        }
        pasteButton.isHidden = false
        layoutPasteButton()
    }
    /// ペーストボタンを候補帯の右端へ置く（固定幅のアイコンボタン）。
    private func layoutPasteButton() {
        guard !pasteButton.isHidden, candidateStrip.bounds.width > 0 else { return }
        pasteButton.frame = CGRect(x: candidateStrip.bounds.width - 46, y: 0,
                                   width: 44, height: candidateStripHeight)
    }
    /// ペーストボタン: クリップボードの文字列をそのまま文書へ挿入する。
    /// 挿入は定型文と同じ editor.insert（即時確定）を通る。フルアクセスが
    /// 無い・文字列が無い・整形後に空になる場合は何もしない。
    @objc private func pasteButtonTapped() {
        guard hasFullAccess, let raw = UIPasteboard.general.string else { return }
        let text = PasteText.sanitized(raw)
        guard !text.isEmpty else { return }
        syncHostChange(); commitCurrent()
        editor.insert(text)
        renderState()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        KeyboardSettings.recordActivation()
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
        if !bracketCandidates.isEmpty { bracketCandidates = []; renderState(updateMarked: false) }
        editor.insert(emoji)
        recentEmojiStore.record(emoji)
        pendingAutocorrectUndo = nil
        if emojiCategoryIndex == 0 { rebuildEmojiGrid() }
    }
    /// パネルの空状態などの注記行。PhraseRowView のカードと同じ左位置・
    /// 上下余白にそろえる（素の UILabel を直接置くと、行のテキスト位置とずれる）。
    private func panelNoteView(_ text: String) -> UIView {
        let container = UIView()
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        return container
    }
    /// 有料機能が無効なときにパネルへ出す購入案内の行。タップで本体アプリを
    /// 開く試みをする（開けなくても文言で案内できる形。旧・期限切れ全画面
    /// 案内と同じ作法）。
    private func panelPurchaseNoteView(_ text: String) -> UIView {
        let container = panelNoteView(text + "\nタップで One Keyboard アプリを開きます。")
        container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openHostApp)))
        return container
    }
    @objc private func openHostApp() {
        guard let url = URL(string: "onekeyboard://") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
    private func rebuildClipboardRows() {
        for arranged in clipboardStack.arrangedSubviews {
            clipboardStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        openClipboardRow = nil
        func noteRow(_ text: String) {
            clipboardStack.addArrangedSubview(panelNoteView(text))
        }
        // クリップボード履歴は有料機能。無効な間は履歴を見せず購入案内だけ出す
        // （保存済みの履歴自体は消さない。購入すればそのまま戻る）。
        guard premiumFeaturesEnabled else {
            clipboardStack.addArrangedSubview(panelPurchaseNoteView("体験期間が終了しました。クリップボード履歴は購入すると使えます。"))
            return
        }
        guard hasFullAccess else {
            noteRow("フルアクセスが必要です。設定 → 一般 → キーボード → One Keyboardで「フルアクセスを許可」をオンにしてください。")
            return
        }
        clipboardStore.reload()
        let items = clipboardStore.items
        if items.isEmpty { noteRow("履歴はまだありません") }
        for (index, item) in items.enumerated() {
            let alreadyPhrase = phraseStore.phrases.contains(item)
            let row = PhraseRowView(phrase: item, cardColor: currentPalette.panelCardBackground.uiColor,
                                    textColor: currentPalette.panelText.uiColor,
                                    reorderMode: false, isFirst: false, isLast: false,
                                    showsRegister: true,
                                    registerTitle: alreadyPhrase ? "登録済" : "定型文",
                                    registerEnabled: !alreadyPhrase)
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
            row.onRegister = { [weak self] in
                guard let self else { return }
                if self.phraseStore.add(item) { self.rebuildClipboardRows() }
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
        // 定型文は有料機能。無効な間は一覧を出さず購入案内だけ出す
        // （登録済みの定型文自体は消さない。購入すればそのまま戻る）。
        guard premiumFeaturesEnabled else {
            phraseStack.addArrangedSubview(panelPurchaseNoteView("体験期間が終了しました。定型文は購入すると使えます。"))
            return
        }
        let phrases = phraseStore.phrases
        if phrases.isEmpty {
            phraseStack.addArrangedSubview(panelNoteView("定型文はまだありません"))
        }
        if pickerReorderMode && !phrases.isEmpty {
            phraseStack.addArrangedSubview(panelNoteView("タップで編集できます"))
        }
        for (index, phrase) in phrases.enumerated() {
            let row = PhraseRowView(phrase: phrase, cardColor: currentPalette.panelCardBackground.uiColor,
                                    textColor: currentPalette.panelText.uiColor,
                                    reorderMode: pickerReorderMode,
                                    isFirst: index == 0, isLast: index == phrases.count - 1)
            row.onTap = { [weak self] in
                guard let self else { return }
                if self.pickerReorderMode {
                    self.beginCapture(editingIndex: index, initialText: phrase)
                } else {
                    self.hidePhrasePicker()
                    self.insertPhrase(phrase)
                }
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
        phraseReorderToggle.setTitle(pickerReorderMode ? "編集・並び替え中" : "編集・並び替え", for: .normal)
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
    private func beginCapture(editingIndex: Int? = nil, initialText: String = "") {
        guard !isCapturing else { return }
        // 定型文の登録・編集も有料機能の一部（通常はパネル側で入口が隠れるが、
        // 入口をここでも閉じておく）。
        guard premiumFeaturesEnabled else { return }
        buildPanelsIfNeeded()
        hidePhrasePicker()
        hideClipboardPanel()
        syncHostChange(); commitCurrent()
        captureEditingIndex = editingIndex
        captureTitle.text = editingIndex != nil ? "定型文を編集" : "定型文を登録"
        let document = BufferDocument()
        document.onChange = { [weak self] text, cursorOffset in
            guard let self else { return }
            self.captureText = text
            self.captureCursorOffset = cursorOffset
            self.renderCaptureDisplay()
        }
        captureDocument = document
        documentOverride = document
        captureText = ""
        captureCursorOffset = 0
        captureCursorVisible = true
        if !initialText.isEmpty { document.loadInitialText(initialText) }
        renderCaptureDisplay()
        captureBlinkTimer?.invalidate()
        captureBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                self.captureCursorVisible.toggle()
                self.renderCaptureDisplay()
            }
        }
        updateCaptureStrip()
        view.setNeedsLayout()
    }
    /// 登録・編集パネルの表示。ラベルにはシステムのカーソルが付かないので、
    /// 現在位置に「|」を差し込んで点滅させる（色を消すだけなので幅は動かない）。
    private func renderCaptureDisplay() {
        let font = captureDisplay.font ?? .systemFont(ofSize: 20)
        let baseColor: UIColor = currentPalette.panelText.uiColor
        let cursorColor: UIColor = captureCursorVisible ? .systemBlue : .clear
        if captureText.isEmpty {
            let attr = NSMutableAttributedString(string: "|", attributes: [.font: font, .foregroundColor: cursorColor])
            attr.append(NSAttributedString(string: "ここに定型文を入力", attributes: [.font: font, .foregroundColor: UIColor.placeholderText]))
            captureDisplay.attributedText = attr
            return
        }
        let offset = min(max(captureCursorOffset, 0), captureText.count)
        var display = captureText
        let idx = display.index(display.startIndex, offsetBy: offset)
        let utf16Offset = display.utf16.distance(from: display.utf16.startIndex, to: idx.samePosition(in: display.utf16)!)
        display.insert("|", at: idx)
        let attr = NSMutableAttributedString(string: display, attributes: [.font: font, .foregroundColor: baseColor])
        attr.addAttribute(.foregroundColor, value: cursorColor, range: NSRange(location: utf16Offset, length: 1))
        captureDisplay.attributedText = attr
    }
    private func endCapture(save: Bool) {
        guard let document = captureDocument else { return }
        let editingIndex = captureEditingIndex
        if save {
            commitCurrent()
            let text = document.text
            let truncated = String(text.prefix(PhraseBook.maxLength))
            if let editingIndex {
                if !phraseStore.update(at: editingIndex, text), truncated != text,
                   phraseStore.update(at: editingIndex, truncated) {
                    presentTruncationAlert()
                }
            } else if !phraseStore.add(text), truncated != text, phraseStore.add(truncated) {
                presentTruncationAlert()
            }
        } else {
            resetComposition()
        }
        captureDocument = nil
        documentOverride = nil
        captureEditingIndex = nil
        captureBlinkTimer?.invalidate()
        captureBlinkTimer = nil
        updateCaptureStrip()
        view.setNeedsLayout()
        // 編集後は一覧へ戻して、書き換わった結果を見せる。
        if editingIndex != nil { showPhrasePicker() }
    }
    private func presentTruncationAlert() {
        let alert = UIAlertController(title: "定型文を保存しました",
                                      message: "100文字を超えたため、先頭100文字で保存しました。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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
        // 改行は定型文の中身として維持する。整形規則は PasteText に集約
        // （改行コードを \n にそろえ、改行以外の制御文字を落とす）。
        let sanitized = PasteText.sanitized(pasted)
        guard !sanitized.isEmpty else { return }
        commitCurrent()
        editor.insert(sanitized)
    }
    @discardableResult
    func applyLayoutString(_ text: String) -> Bool {
        guard let snapshot = LayoutSettings.decode(text) else { return false }
        syncHostChange(); commitCurrent()
        settings.apply(snapshot)
        shifted = false; capsLocked = false; symbols = false; bracketCandidates = []
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
        if !bracketCandidates.isEmpty { bracketCandidates = []; renderState(updateMarked: false) }
        editor.insert(phrase)
    }

    private func setLanguage(_ japanese: Bool) {
        guard settings.japanese != japanese else { return }
        syncHostChange(); commitCurrent()
        settings.japanese = japanese
        predictedCandidates = []
        shifted = false; capsLocked = false; symbols = false; bracketCandidates = []
        rebuildCanvas()
    }
    private func handle(_ action: KeyboardAction) {
        if action != .delete { pendingAutocorrectUndo = nil }
        syncHostChange()
        let hadBracketCandidates = !bracketCandidates.isEmpty
        if action != .delete { bracketCandidates = [] }
        switch action {
        case .shift:
            if symbols { symbols = false; rebuildCanvas() }
            else { shifted.toggle(); capsLocked = false; activeSurface.updateShift(shifted, caps: false) }
        case .delete: backspace()
        case .symbols:
            symbols.toggle(); rebuildCanvas()
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
        // 括弧候補を消したのに帯が残らないよう、再描画が伴わない
        // アクションでも帯だけは追随させる。
        if hadBracketCandidates, bracketCandidates.isEmpty { renderState(updateMarked: false) }
    }
    private func insert(_ text: String) {
        syncHostChange()
        let hadBracketCandidates = !bracketCandidates.isEmpty
        bracketCandidates = []
        if !isJapanese, !symbols, composition.isEmpty, text.count == 1, ".?!,".contains(text) {
            autocorrectEnglishWord(delimiter: text)
        }
        let roman = text.count == 1 && text.first.map { $0.isASCII && ($0.isLetter || $0 == "'") } == true
        let isRomanInput = roman && !symbols
        if isJapanese && (isRomanInput || !composition.isEmpty) {
            if composition.input.count >= 96 { commitRaw() }
            if text == "-", !symbols {
                // 「-」キーは長音符として組成に入れる。全角ハイフン (U+FF0D)
                // で入れると読みが「ら－めん」になり辞書引きが外れて、
                // ラーメン等のカタカナ語が一切変換できなくなる。
                // ローマ字テーブルには「-」→「ー」の対応が無いため、
                // キーボード側で直接入れる (長押し候補の先頭も「ー」)。
                composition.insertAtCursorPosition("ー", inputStyle: .direct)
                selected = nil
                scheduleConversion()
            } else if isRomanInput && handleEnglishWordKey(text) {
                // B案: 英単語モードの打鍵は handleEnglishWordKey が処理した
                // (組成への挿入と候補更新まで済んでいる)。
                selected = nil
            } else if englishWordMode && !composition.isEmpty && !symbols
                        && text.count == 1 && text.first?.isASCII == true && text.first?.isNumber == true {
                // 英単語モード中の数字は半角のまま組成に足す (PDF2 等)。
                composition.insertAtCursorPosition(text, inputStyle: .direct)
                selected = nil
                showEnglishWordCandidates()
            } else {
                let inputText = isRomanInput ? text.lowercased() : japaneseFullWidth(text)
                composition.insertAtCursorPosition(inputText, inputStyle: isRomanInput ? .roman2kana : .direct)
                selected = nil
                scheduleConversion()
            }
        } else {
            commitCurrent()
            let committedText = isJapanese && symbols ? japaneseFullWidth(text) : text
            editor.insert(shifted && !isJapanese ? text.uppercased() : committedText)
            // 記号モードの入力は全て変換対象: 直後に変換候補を帯に出す
            // (括弧は括弧組、それ以外は全角/半角ペアと関連記号)。
            if symbols, let variants = Self.symbolVariants(for: committedText, japanese: isJapanese) {
                bracketCandidates = variants
            }
        }
        if shifted && !capsLocked { shifted = false; activeSurface.updateShift(false, caps: false) }
        if !isJapanese, composition.isEmpty { renderState() }
        else if hadBracketCandidates || !bracketCandidates.isEmpty { renderState(updateMarked: false) }
    }
    /// 記号モードの変換候補。括弧は括弧組、それ以外は全角/半角ペアと
    /// 関連記号。候補のない記号では nil。
    private static func symbolVariants(for inserted: String, japanese: Bool) -> [String]? {
        if let brackets = bracketVariants(for: inserted, japanese: japanese) { return brackets }
        guard inserted.count == 1 else { return nil }
        var out = [inserted]
        let half = halfWidthForm(inserted)
        for v in [half, japaneseFullWidth(inserted)] {
            if let v, v != inserted, !out.contains(v) { out.append(v) }
        }
        let base = half ?? inserted
        for v in relatedSymbols[base] ?? relatedSymbols[inserted] ?? [] {
            if !out.contains(v) { out.append(v) }
        }
        return out.count > 1 ? out : nil
    }
    private static let relatedSymbols: [String: [String]] = [
        ".": ["。", "．", "・"],
        ",": ["、", "，"],
        "-": ["ー", "―", "–", "‐"],
        "'": ["‘", "’"],
        "\"": ["“", "”"],
        "<": ["〈", "《"],
        ">": ["〉", "》"],
        "~": ["〜", "～"],
        "〜": ["～", "~"],
    ]
    /// 括弧の変換候補。開き/閉じと全角/半角で組が決まる。括弧キー
    /// 以外の入力では nil (候補を出さない)。
    private static func bracketVariants(for inserted: String, japanese: Bool) -> [String]? {
        let openers = japanese ? ["（", "［", "｛", "「", "【", "〔"] : ["(", "[", "{"]
        let closers = japanese ? ["）", "］", "｝", "」", "】", "〕"] : [")", "]", "}"]
        if openers.contains(inserted) { return openers }
        if closers.contains(inserted) { return closers }
        return nil
    }
    /// 帯で選ばれた括弧へ、挿入済みの括弧を置き換える。
    private func applyBracketVariant(_ value: String) {
        bracketCandidates = []
        editor.deleteBackward()
        editor.insert(value)
        renderState(updateMarked: false)
    }
    /// フリック面からのかな入力。通常の insert() は「組成が空でかな入力」だと
    /// 直接挿入に落ちて変換が始まらないため、フリックでは組成を強制的に
    /// 始める。句読点だけは QWERTY と同じく、組成が空なら直接挿入する。
    private func insertFlick(_ text: String) {
        syncHostChange()
        bracketCandidates = []
        guard isJapanese else { insert(text); return }
        if composition.isEmpty && (text == "、" || text == "。") { insert(text); return }
        if composition.input.count >= 96 { commitRaw() }
        composition.insertAtCursorPosition(text, inputStyle: .direct)
        selected = nil
        scheduleConversion()
    }

    /// フリック面の「゛゜小」キー。カーソル直前のかなを、濁点→半濁点→
    /// 小書きの順に循環変換する (純正の循環仕様)。カーソルが組成末尾に
    /// あるときだけ対象にする (フリック入力中は通常末尾にある)。
    private func applyDakuten() {
        syncHostChange()
        guard isJapanese, !composition.isEmpty,
              composition.convertTargetCursorPosition == composition.convertTarget.count,
              let last = composition.convertTarget.last,
              let next = Self.dakutenCycle[last] else { return }
        composition.deleteBackwardFromCursorPosition(count: 1)
        composition.insertAtCursorPosition(String(next), inputStyle: .direct)
        selected = nil
        scheduleConversion()
    }

    private static let dakutenCycle: [Character: Character] = [
        "か": "が", "が": "か", "き": "ぎ", "ぎ": "き", "く": "ぐ", "ぐ": "く", "け": "げ", "げ": "け", "こ": "ご", "ご": "こ",
        "さ": "ざ", "ざ": "さ", "し": "じ", "じ": "し", "す": "ず", "ず": "す", "せ": "ぜ", "ぜ": "せ", "そ": "ぞ", "ぞ": "そ",
        "た": "だ", "だ": "た", "ち": "ぢ", "ぢ": "ち", "つ": "っ", "っ": "づ", "づ": "つ", "て": "で", "で": "て", "と": "ど", "ど": "と",
        "は": "ば", "ば": "ぱ", "ぱ": "は", "ひ": "び", "び": "ぴ", "ぴ": "ひ", "ふ": "ぶ", "ぶ": "ぷ", "ぷ": "ふ",
        "へ": "べ", "べ": "ぺ", "ぺ": "へ", "ほ": "ぼ", "ぼ": "ぽ", "ぽ": "ほ",
        "う": "ゔ", "ゔ": "ぅ", "ぅ": "う", "あ": "ぁ", "ぁ": "あ", "い": "ぃ", "ぃ": "い", "え": "ぇ", "ぇ": "え", "お": "ぉ", "ぉ": "お",
        "や": "ゃ", "ゃ": "や", "ゆ": "ゅ", "ゅ": "ゆ", "よ": "ょ", "ょ": "よ", "わ": "ゎ", "ゎ": "わ",
        "カ": "ガ", "ガ": "カ", "キ": "ギ", "ギ": "キ", "ク": "グ", "グ": "ク", "ケ": "ゲ", "ゲ": "ケ", "コ": "ゴ", "ゴ": "コ",
        "サ": "ザ", "ザ": "サ", "シ": "ジ", "ジ": "シ", "ス": "ズ", "ズ": "ス", "セ": "ゼ", "ゼ": "セ", "ソ": "ゾ", "ゾ": "ソ",
        "タ": "ダ", "ダ": "タ", "チ": "ヂ", "ヂ": "チ", "ツ": "ッ", "ッ": "ヅ", "ヅ": "ツ", "テ": "デ", "デ": "テ", "ト": "ド", "ド": "ト",
        "ハ": "バ", "バ": "パ", "パ": "ハ", "ヒ": "ビ", "ビ": "ピ", "ピ": "ヒ", "フ": "ブ", "ブ": "プ", "プ": "フ",
        "ヘ": "ベ", "ベ": "ペ", "ペ": "ヘ", "ホ": "ボ", "ボ": "ポ", "ポ": "ホ",
        "ウ": "ヴ", "ヴ": "ゥ", "ゥ": "ウ", "ア": "ァ", "ァ": "ア", "イ": "ィ", "ィ": "イ", "エ": "ェ", "ェ": "エ", "オ": "ォ", "ォ": "オ",
        "ヤ": "ャ", "ャ": "ヤ", "ユ": "ュ", "ュ": "ユ", "ヨ": "ョ", "ョ": "ヨ", "ワ": "ヮ", "ヮ": "ワ",
    ]

    private func scheduleConversion() {
        let inputStamp = PerfProbe.stamp()
        revision += 1
        let requestRevision = revision, snapshot = composition
        let contextSnapshot = committedContext
        conversionReady = false; waitingSpaceCount = 0; selected = nil
        // 候補を毎打鍵でリセットすると候補欄が点滅して遅く見える。前回の候補を
        // 残したまま新しい変換結果を待つ。
        // 空のときの「基本候補で先埋め」もしない: 単語の打ち始めに [かな, カナ]
        // が一瞬出てから本候補に総入れ替えされる二度表示が、ちらつきの主因。
        // 変換は約5msで返るので、先埋めなしでも空白は知覚できない。
        if snapshot.isEmpty { candidates = []; englishExtraValues = []; packExtraValues = []; predictedCandidates = [] }
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
                return
            }
            guard !Task.isCancelled else {
                return
            }
            // 世代遅れでスキップされたら nil。状態は新しいタスクが持つので触らない。
            let awaitStamp = PerfProbe.stamp()
            let serviceResult = await service.candidates(for: snapshot, generation: requestRevision, context: contextSnapshot)
            guard let result = serviceResult else {
                return
            }
            PerfProbe.shared.record("await", since: awaitStamp)
            guard !Task.isCancelled, let self else {
                return
            }
            guard self.revision == requestRevision else {
                return
            }
            // ここで syncHostChange() はしない。変換中にホスト側で編集があれば
            // textDidChange / selectionDidChange 側のチェックで composition が
            // リセットされ、revision ガードでこの結果は捨てられる。毎回の
            // documentContext 読み直し（ホスト往復）を候補表示の経路から外す。
            var seen = Set<String>()
            let merged = Array((result + self.baseCandidates()).filter { seen.insert($0).inserted })
            let withEnglish = self.insertEnglishExtras(merged, raw: self.rawRomaji(of: snapshot), kana: snapshot.convertTarget)
            let withPacks = self.insertPackExtras(withEnglish, kana: snapshot.convertTarget)
            // 選択履歴は統合の最終段で適用する: 一度確定した候補は
            // SNS の先頭固定よりも前に来る (優先順位: 履歴 > SNS > その他)。
            let withHistory = SelectionHistoryStore.applyingHistory(
                self.selectionHistory.choices(for: snapshot.convertTarget), to: withPacks)
            let newCandidates = Array(withHistory.prefix(30))
            let candidatesChanged = newCandidates != self.candidates
            if candidatesChanged { self.candidates = newCandidates }
            self.conversionReady = true
            self.selected = self.waitingSpaceCount > 0 && !self.candidates.isEmpty ? (self.waitingSpaceCount - 1) % self.candidates.count : nil
            let hadWaitingSpace = self.waitingSpaceCount > 0
            self.waitingSpaceCount = 0
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
    /// 日本語の候補列に英字そのまま候補を差し込む。読みに未変換のローマ字が
    /// 残っていて英単語として成立する綴りなら先頭 (「ok」→ おk になる問題への
    /// 対策)、完全にかな変換できる英単語なら2番手、それ以外は3番手。
    /// 英字候補は日本語変換の学習対象にしない。
    private func insertEnglishExtras(_ list: [String], raw: String, kana: String) -> [String] {
        guard isJapanese, let lexicon = englishLexicon else { englishExtraValues = []; return list }
        let (merged, extras) = lexicon.insertingExtras(into: list, raw: raw, kana: kana)
        // 分割候補 (okdatta → OKだった): 組成全体が英単語+日本語の連結なら
        // 先頭に出す。残りの読みは組成エンジンで変換して渡す。
        let segmented = lexicon.segmentedExtras(raw: raw, kana: kana) { remainder in
            var tail = ComposingText()
            tail.insertAtCursorPosition(remainder, inputStyle: .roman2kana)
            return tail.convertTarget
        }.filter { !merged.contains($0) }
        englishExtraValues = Set(extras + segmented)
        guard !segmented.isEmpty else { return merged }
        var out = merged
        out.insert(contentsOf: segmented, at: 0)
        return out
    }
    /// B案: 日本語モードで Shift を押して大文字から打ち始めた単語は、かな変換を
    /// 通さず英字のまま確定できるようにする。打鍵を処理したら true、通常の
    /// ローマ字入力として処理すべき場合は false を返す (false の場合、副作用は
    /// 英単語モードの解除だけ)。判定は EnglishWordMode (テスト可能部品) に委譲。
    private func handleEnglishWordKey(_ text: String) -> Bool {
        switch englishWordTracker.handleKey(text, shifted: shifted, capsLocked: capsLocked,
                                            compositionIsEmpty: composition.isEmpty,
                                            currentRaw: rawRomaji(of: composition),
                                            lexicon: englishLexicon) {
        case .insertDirect(let typed):
            composition.insertAtCursorPosition(typed, inputStyle: .direct)
            showEnglishWordCandidates()
            return true
        case .passThrough:
            return false
        }
    }
    /// 英単語モード中の候補は入力そのままだけ。変換は回さない。
    private func showEnglishWordCandidates() {
        revision += 1; conversionTask?.cancel()
        let raw = rawRomaji(of: composition)
        predictedCandidates = []
        candidates = [raw]
        englishExtraValues = [raw]
        conversionReady = true
        selected = nil
        renderState()
    }
    /// 辞書パックの候補を候補列に差し込む (二段構成, build 88)。
    /// 上段 (本体の候補列) は build 86 までの構成そのまま: SNS は候補列の
    /// 先頭に固定し (変換・リランクの後段なので並び替えでは動かない)、
    /// それ以外のパックは先頭候補の直後に差し込む (ユーザーが明示的に
    /// 有効化した専用語彙で、読みが完全一致すれば意図はほぼ確定のため。
    /// 末尾追加だった頃は変換ノイズの後ろに埋もれた)。
    /// 前方一致の予測 (読みが入力途中のもの) は上段には混ぜず、下段の
    /// 予測専用帯 (predictedCandidates) にだけ渡す。build 87 では上段の
    /// 末尾に足していたが、末尾では目に入らず機能が死ぬための分離。
    /// 予測の規律は据え置き: 3文字以上・SNS を除く・完全一致と重なる
    /// 表記は除く・合計10件まで (predictedSurfaces 側で担保)。
    /// パック候補は英字そのまま候補と同様、日本語変換の学習対象にしない
    /// (予測も packExtraValues に入れて学習から外す)。
    private func insertPackExtras(_ list: [String], kana: String) -> [String] {
        guard isJapanese else { packExtraValues = []; predictedCandidates = []; return list }
        // 辞書パックは有料機能。無効な間は、ON/OFF の設定自体はそのままに
        // 適用だけを止める（購入すれば設定どおりに即戻る）。
        guard premiumFeaturesEnabled else { packExtraValues = []; predictedCandidates = []; return list }
        let pinned = dictionaryLibrary.pinnedSurfaces(forKana: kana, store: dictionaryStore)
        let appended = dictionaryLibrary.appendedSurfaces(forKana: kana, store: dictionaryStore)
        let predicted = kana.count >= 3
            ? dictionaryLibrary.predictedSurfaces(forKana: kana, store: dictionaryStore)
            : []
        predictedCandidates = predicted
        packExtraValues = Set(pinned + appended + predicted)
        return DictionaryPackLibrary.mergingPacks(
            into: list, pinned: pinned, appended: appended)
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
    /// 選択中（スペース変換でフォーカスされた候補）のハイライト色。
    /// build 55: 未選択の候補キーは背景なし（文字のみ）に戻した
    /// （build 45 で付けたピル背景はユーザーの指示で撤去）。
    private var selectedCandidateColor: UIColor { currentPalette.candidateSelectedBackground.uiColor }
    private func renderState(updateMarked: Bool = true) {
        if !isJapanese { refreshEnglishSuggestions() }
        if updateMarked {
            let display = selected.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil } ?? composition.convertTarget
            let caret = selected == nil ? String(display.prefix(composition.convertTargetCursorPosition)).utf16.count : display.utf16.count
            PerfProbe.shared.measure("show") { editor.show(display, caret: caret) }
        }
        activeSurface.setComposing(!composition.isEmpty)
        // 候補バーは常時表示 (高さ固定) のため、候補の有無で帯の
        // 表示・高さは変わらない。帯まわりの高さ交渉は不要になった。
        let stripStamp = PerfProbe.stamp()
        let stripCount = !bracketCandidates.isEmpty ? bracketCandidates.count
            : (isJapanese ? candidates.count : englishSuggestions.count)
        while candidateKeys.count > stripCount {
            let key = candidateKeys.removeLast()
            key.removeFromSuperview()
        }
        while candidateKeys.count < stripCount {
            // build 45: .system ボタンは iOS 27 SDK でホスト側リモートビューに
            // ラベル/マテリアルが合成されず候補欄が空白になる疑いがあるため
            // .custom に変更。背景は build 55 でクリアに戻した（文字のみ）。
            let key = CandidateKey(type: .custom)
            key.titleLabel?.font = .systemFont(ofSize: 17)
            key.setTitleColor(currentPalette.candidateText.uiColor, for: .normal)
            key.backgroundColor = .clear
            key.contentEdgeInsets = .init(top: 0, left: 10, bottom: 0, right: 10)
            key.layer.cornerRadius = 4
            key.addTarget(key, action: #selector(CandidateKey.activate), for: .touchUpInside)
            candidateKeys.append(key)
            // build 48: コンテナ (旧 candidateStack) を介さず帯の直下へ
            // 直接置く（build 58 で帯は candidateStrip）。
            candidateStrip.addSubview(key)
        }
        // パレットが変わったときだけ全キーの色を付け直す (明暗の切替に
        // 加え、着せ替えの個別色変更にも追随させるため、比較はスタイルで
        // なく解決済みパレットそのもので行う)。
        if candidatePaletteApplied != currentPalette {
            candidateKeys.forEach { key in
                key.setTitleColor(currentPalette.candidateText.uiColor, for: .normal)
                key.backgroundColor = key.isSelectedCandidate == true ? selectedCandidateColor : .clear
            }
            candidatePaletteApplied = currentPalette
        }
        let displayedRevision = revision
        for (index, key) in candidateKeys.enumerated() {
            if !bracketCandidates.isEmpty {
                let value = bracketCandidates[index]
                if key.renderedValue != value {
                    key.setTitle(value, for: .normal)
                    key.accessibilityIdentifier = "candidate." + value
                    key.renderedValue = value
                }
                if key.isSelectedCandidate == true {
                    key.backgroundColor = .clear
                    key.isSelectedCandidate = false
                }
                key.onSelect = { [weak self] in self?.applyBracketVariant(value) }
                key.actionRevision = displayedRevision
                continue
            }
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
                key.backgroundColor = isSelected ? selectedCandidateColor : .clear
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
        // build 58: 配置は layoutCandidateKeys() に集約する（パンの
        // 途中でも同じ計算で付け直せるようにするため）。内容が変われば
        // 総幅も変わるので、オフセットを範囲内に収めてから配置する。
        layoutCandidateKeys()
        PerfProbe.shared.record("strip", since: stripStamp)
        // 候補リストが変わったら候補欄を左端に戻し、必ず左から見せる。
        // （選択ハイライトだけの変化では戻さない。旧 contentOffset の
        // リセット相当。）
        let stripValues = !bracketCandidates.isEmpty ? bracketCandidates
            : (isJapanese ? candidates : englishSuggestions)
        if stripValues != lastStripValues {
            lastStripValues = stripValues
            // リストが差し替わったら慣性減速も止める（build 59）。
            stopStripDeceleration()
            if stripContentOffsetX != 0 {
                stripContentOffsetX = 0
                layoutCandidateKeys()
            }
        }
        renderPredictionStrip()
        // 組成・候補の有無が変わるたびにペーストボタンの表示も合わせる。
        updatePasteButton()
    }

    /// 下段の予測キーの文字色。上段の候補文字色を薄めたもので、格下の
    /// 扱いにする。パレット由来なので、着せ替えで候補文字色を変えれば
    /// 下段も追随し、テーマ OFF では標準パレットの色になる。
    private var predictionTextColor: UIColor {
        currentPalette.candidateText.uiColor.withAlphaComponent(0.55)
    }

    /// 下段の予測帯を描き直す (build 88)。データは predictedCandidates
    /// (insertPackExtras が変換完了のたびに差し替える) だけ。予測が
    /// 無いときはキーが0個になるだけで、帯の枠と高さは残る (常時予約)。
    /// キーの管理・配置・タップ確定は上段と同じ作法で、確定は候補と
    /// 同じ経路 (commit) を通り、学習は shouldLearn が packExtraValues
    /// で弾く (予測は学習対象にしない)。
    private func renderPredictionStrip() {
        let values = isJapanese ? predictedCandidates : []
        while predictionKeys.count > values.count {
            let key = predictionKeys.removeLast()
            key.removeFromSuperview()
        }
        while predictionKeys.count < values.count {
            let key = CandidateKey(type: .custom)
            key.titleLabel?.font = .systemFont(ofSize: 15)
            key.setTitleColor(predictionTextColor, for: .normal)
            key.backgroundColor = .clear
            key.contentEdgeInsets = .init(top: 0, left: 10, bottom: 0, right: 10)
            key.layer.cornerRadius = 4
            key.addTarget(key, action: #selector(CandidateKey.activate), for: .touchUpInside)
            predictionKeys.append(key)
            predictionStrip.addSubview(key)
        }
        if predictionPaletteApplied != currentPalette {
            predictionKeys.forEach { key in
                key.setTitleColor(predictionTextColor, for: .normal)
            }
            predictionPaletteApplied = currentPalette
        }
        let displayedRevision = revision
        for (index, key) in predictionKeys.enumerated() {
            let value = values[index]
            let valueChanged = key.renderedValue != value
            if valueChanged {
                key.setTitle(value, for: .normal)
                key.accessibilityIdentifier = "prediction." + value
                key.renderedValue = value
            }
            if key.actionRevision != displayedRevision || valueChanged {
                key.onSelect = { [weak self] in
                    guard let self else { return }
                    // 変換待ちの間に残っている前回予測は、確定に使わない
                    // (上段の候補と同じガード)。
                    guard self.conversionReady else { return }
                    self.syncHostChange()
                    guard self.revision == displayedRevision else { return }
                    self.commit(value, learn: self.shouldLearn(value))
                }
                key.actionRevision = displayedRevision
            }
        }
        // 予測リストが変わったら帯を左端に戻して必ず左から見せる
        // (上段と同じ扱い。慣性減速も止める)。
        if values != lastPredictionValues {
            lastPredictionValues = values
            stopPredictionDeceleration()
            predictionContentOffsetX = 0
        }
        layoutPredictionKeys()
    }

    /// 予測キーを手動フレームで配置する (上段の layoutCandidateKeys と
    /// 同じ計算: 左端 6pt・間隔 8pt・右端余白 6pt)。
    private func layoutPredictionKeys() {
        var widths: [CGFloat] = []
        widths.reserveCapacity(predictionKeys.count)
        var contentWidth: CGFloat = 0
        for key in predictionKeys {
            var w = key.intrinsicContentSize.width
            if w <= 0 {
                w = key.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: predictionStripHeight)).width
            }
            widths.append(w)
            contentWidth += w + 8
        }
        predictionContentWidth = predictionKeys.isEmpty ? 0 : contentWidth - 8 + 12
        predictionContentOffsetX = clampedPredictionOffset(predictionContentOffsetX)
        var x: CGFloat = 6 - predictionContentOffsetX
        for (index, key) in predictionKeys.enumerated() {
            key.frame = CGRect(x: x, y: 0, width: widths[index], height: predictionStripHeight)
            x += widths[index] + 8
        }
    }

    /// 予測帯のスクロールオフセットの許容範囲へのクランプ。
    private func clampedPredictionOffset(_ offset: CGFloat) -> CGFloat {
        let maxOffset = max(0, predictionContentWidth - predictionStrip.bounds.width)
        return min(max(0, offset), maxOffset)
    }

    /// オフセットを変えて予測キーを付け直す（パン中の再配置）。
    private func setPredictionOffset(_ offset: CGFloat) {
        let clamped = clampedPredictionOffset(offset)
        guard clamped != predictionContentOffsetX else { return }
        predictionContentOffsetX = clamped
        layoutPredictionKeys()
    }

    /// 予測帯の横スクロール（上段と同じパン自前実装 + 慣性減速）。
    @objc private func handlePredictionPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopPredictionDeceleration()
            predictionPanBase = predictionContentOffsetX
        case .changed:
            setPredictionOffset(predictionPanBase - gesture.translation(in: predictionStrip).x)
        case .ended, .cancelled:
            startPredictionDeceleration(offsetVelocity: -gesture.velocity(in: predictionStrip).x)
        default:
            break
        }
    }

    /// 予測帯の慣性減速の開始（上段と同じ指数減衰 ×0.998/ms）。
    private func startPredictionDeceleration(offsetVelocity: CGFloat) {
        stopPredictionDeceleration()
        guard abs(offsetVelocity) > 30,
              max(0, predictionContentWidth - predictionStrip.bounds.width) > 0 else { return }
        predictionDecelVelocity = offsetVelocity
        predictionLastFrameTime = 0
        let link = CADisplayLink(target: self, selector: #selector(stepPredictionDeceleration(_:)))
        link.add(to: .main, forMode: .common)
        predictionDisplayLink = link
    }

    /// 予測帯の慣性減速の停止。
    private func stopPredictionDeceleration() {
        predictionDisplayLink?.invalidate()
        predictionDisplayLink = nil
        predictionDecelVelocity = 0
    }

    /// 予測帯の減速の1フレーム分（上段と同じ計算）。
    @objc private func stepPredictionDeceleration(_ link: CADisplayLink) {
        let dt: CFTimeInterval
        if predictionLastFrameTime > 0 {
            dt = min(link.timestamp - predictionLastFrameTime, 0.05)
        } else {
            dt = link.duration
        }
        predictionLastFrameTime = link.timestamp
        guard dt > 0 else { return }
        let next = predictionContentOffsetX + predictionDecelVelocity * CGFloat(dt)
        let clamped = clampedPredictionOffset(next)
        setPredictionOffset(next)
        if clamped != next || abs(predictionDecelVelocity) < 5 {
            stopPredictionDeceleration()
            return
        }
        predictionDecelVelocity *= CGFloat(pow(0.998, dt * 1000))
    }

    /// 候補キーを手動フレームで配置する（build 58）。キーは帯
    /// （candidateStrip）の直下の子で、frame はコンテンツ座標から
    /// 現在のスクロールオフセットを差し引いたもの。左端 6pt から
    /// 8pt 間隔で並べる（右端にも 6pt の余白を残す）。キーの幅計算は
    /// build 46 以来の計算そのまま。総幅は stripContentWidth に残し、
    /// オフセットは [0, 総幅 − 帯幅] にクランプする。
    private func layoutCandidateKeys() {
        let stripHeight = candidateStripHeight
        var widths: [CGFloat] = []
        widths.reserveCapacity(candidateKeys.count)
        var contentWidth: CGFloat = 0
        for key in candidateKeys {
            var w = key.intrinsicContentSize.width
            if w <= 0 {
                w = key.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: stripHeight)).width
            }
            widths.append(w)
            contentWidth += w + 8
        }
        stripContentWidth = candidateKeys.isEmpty ? 0 : contentWidth - 8 + 12
        stripContentOffsetX = clampedStripOffset(stripContentOffsetX)
        var x: CGFloat = 6 - stripContentOffsetX
        for (index, key) in candidateKeys.enumerated() {
            key.frame = CGRect(x: x, y: 0, width: widths[index], height: stripHeight)
            x += widths[index] + 8
        }
    }

    /// スクロールオフセットの許容範囲へのクランプ。
    private func clampedStripOffset(_ offset: CGFloat) -> CGFloat {
        let maxOffset = max(0, stripContentWidth - candidateStrip.bounds.width)
        return min(max(0, offset), maxOffset)
    }

    /// オフセットを変えて候補キーを付け直す（パン中の再配置）。
    private func setStripOffset(_ offset: CGFloat) {
        let clamped = clampedStripOffset(offset)
        guard clamped != stripContentOffsetX else { return }
        stripContentOffsetX = clamped
        layoutCandidateKeys()
    }

    /// 候補帯の横スクロール（build 58: UIPanGestureRecognizer による
    /// 自前実装）。指を左へ動かすとコンテンツが左へ寄る。認識器の
    /// cancelsTouchesInView により、ドラッグが始まった時点で候補
    /// ボタンのタッチはキャンセルされるので、スクロール目的の
    /// ドラッグで候補が確定することはない。
    @objc private func handleCandidatePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 新しいタッチが来たら慣性減速は即座に止める（build 59）。
            stopStripDeceleration()
            stripPanBase = stripContentOffsetX
        case .changed:
            setStripOffset(stripPanBase - gesture.translation(in: candidateStrip).x)
        case .ended, .cancelled:
            // 指を離した時点の横速度で慣性スクロールを始める（build 59）。
            // オフセットは「指が左へ動くほど増える」向きなので、オフセット
            // 方向の速度は velocity.x の符号反転になる。
            startStripDeceleration(offsetVelocity: -gesture.velocity(in: candidateStrip).x)
        default:
            break
        }
    }

    /// 慣性減速の開始（build 59）。指に 1:1 追随するだけだと離した瞬間に
    /// 止まって「固い」動きになるため、UIScrollView と同等の減衰
    /// （1ms あたり ×0.998 の指数減衰）で滑らかに止める。コンテンツが
    /// 帯に収まっている・速度が小さい場合は始めない。
    private func startStripDeceleration(offsetVelocity: CGFloat) {
        stopStripDeceleration()
        guard abs(offsetVelocity) > 30,
              max(0, stripContentWidth - candidateStrip.bounds.width) > 0 else { return }
        stripDecelVelocity = offsetVelocity
        stripLastFrameTime = 0
        let link = CADisplayLink(target: self, selector: #selector(stepStripDeceleration(_:)))
        link.add(to: .main, forMode: .common)
        stripDisplayLink = link
    }

    /// 慣性減速の停止（新しいタッチ・候補リスト更新でのオフセット
    /// リセット時に即座に呼ぶ）。
    private func stopStripDeceleration() {
        stripDisplayLink?.invalidate()
        stripDisplayLink = nil
        stripDecelVelocity = 0
    }

    /// 減速の1フレーム分：オフセットを速度ぶん進め、速度を指数減衰させる。
    /// 端 [0, 総幅 − 帯幅] に達したらそこで停止する（ラバーバンドなし）。
    @objc private func stepStripDeceleration(_ link: CADisplayLink) {
        let dt: CFTimeInterval
        if stripLastFrameTime > 0 {
            dt = min(link.timestamp - stripLastFrameTime, 0.05)
        } else {
            dt = link.duration
        }
        stripLastFrameTime = link.timestamp
        guard dt > 0 else { return }
        let next = stripContentOffsetX + stripDecelVelocity * CGFloat(dt)
        let clamped = clampedStripOffset(next)
        setStripOffset(next)
        // 端に当たった、または速度が十分小さくなったら終了。
        if clamped != next || abs(stripDecelVelocity) < 5 {
            stopStripDeceleration()
            return
        }
        stripDecelVelocity *= CGFloat(pow(0.998, dt * 1000))
    }

    /// 候補帯のパンは横方向のドラッグだけ開始する（旧 UIScrollView の
    /// directional lock 相当。縦ドラッグは帯では扱わない）。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === candidatePan {
            let velocity = candidatePan.velocity(in: candidateStrip)
            return abs(velocity.x) > abs(velocity.y)
        }
        if gestureRecognizer === predictionPan {
            let velocity = predictionPan.velocity(in: predictionStrip)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
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
        // パックが有料機能として無効な間は足さない（設定はそのまま残る）。
        if premiumFeaturesEnabled {
            for extra in dictionaryLibrary.patternCompletions(forTyped: typed, store: dictionaryStore) where !merged.contains(extra) {
                merged.append(extra)
            }
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
        // スペースでは自動補正しない: 打った文字列をそのまま確定する。
        // 候補への置き換えは候補帯のタップでのみ行う（build 57〜）。
        pendingAutocorrectUndo = nil
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
        // 英単語モード中のスペースは英単語の確定 (候補送りはしない)。
        if englishWordMode, !composition.isEmpty {
            commit(rawRomaji(of: composition))
            return
        }
        guard !composition.isEmpty else {
            // 日本語モードではスペースも全角（U+3000）にする。記号ページ表示中でも
            // 日本語モードなら全角。半角スペースは英字モード側の englishSpace() のみ。
            if isJapanese { editor.insert("　") } else if symbols { editor.insert(" ") } else { englishSpace() }
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
        // 英単語モードの末尾 n は英字の一部 (「On」等) なので ん にしない。
        if !englishWordMode, text.hasSuffix("n") { text.removeLast(); text += "ん" }
        commit(text)
    }
    private func commit(_ text: String, learn: Bool = false) {
        if learn {
            // 確定した候補を (読み → 候補) で記録し、次回同じ読みでは
            // 候補列の先頭に並べる。読みは候補生成に使った
            // composition.convertTarget そのもの (確定で composition が
            // リセットされる前に取る)。英字そのまま候補と辞書パック
            // 候補は learn=false で来るため記録されない (shouldLearn 参照)。
            selectionHistory.record(reading: composition.convertTarget, choice: text)
            Task { await service.learn(text) }
        }
        editor.commit(text)
        resetComposition()
        // 確定したテキストを LM v3 の文脈として蓄積する (末尾 120 字まで)。
        committedContext = String((committedContext + text).suffix(120))
    }
    private func resetComposition() {
        revision += 1; conversionTask?.cancel()
        englishWordMode = false
        predictedCandidates = []
        composition = ComposingText(); candidates = []; selected = nil
        conversionReady = false; waitingSpaceCount = 0
        if isViewLoaded { renderState(updateMarked: false) }
    }
    private func backspace() {
        let hadBracketCandidates = !bracketCandidates.isEmpty
        bracketCandidates = []
        if composition.isEmpty {
            if undoEnglishAutocorrectIfApplicable() { renderState(); return }
            editor.deleteBackward()
            if !committedContext.isEmpty { committedContext.removeLast() }
            if !isJapanese { renderState() }
        }
        else if selected != nil { selected = nil; renderState() }
        else {
            composition.deleteBackwardFromCursorPosition(count: 1)
            if composition.isEmpty { englishWordMode = false }
            scheduleConversion()
        }
        if hadBracketCandidates { renderState(updateMarked: false) }
    }
    private func moveCursor(_ offset: Int) {
        syncHostChange()
        // カーソルが動くと「直前テキスト = 追跡中の文脈」が崩れるので捨てる。
        if composition.isEmpty { committedContext = ""; editor.move(offset) }
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
    var onRegister: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onSwipeStart: (() -> Void)?

    let panRecognizer = UIPanGestureRecognizer()
    private let card = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let registerButton = UIButton(type: .system)
    private let showsRegister: Bool
    private var panBase: CGFloat = 0
    private(set) var isOpen = false
    private static let deleteWidth: CGFloat = 76
    private static let registerWidth: CGFloat = 76
    /// スワイプで露出するアクション領域の幅（登録ボタンがある行は2つ分）。
    private var revealWidth: CGFloat {
        Self.deleteWidth + (showsRegister ? Self.registerWidth : 0)
    }

    init(phrase: String, cardColor: UIColor, textColor: UIColor, reorderMode: Bool, isFirst: Bool, isLast: Bool,
         showsRegister: Bool = false, registerTitle: String = "定型文", registerEnabled: Bool = true) {
        self.showsRegister = showsRegister
        super.init(frame: .zero)
        deleteButton.setTitle("削除", for: .normal)
        deleteButton.setTitleColor(.white, for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        deleteButton.backgroundColor = .systemRed
        deleteButton.layer.cornerRadius = 8
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        addSubview(deleteButton)

        if showsRegister {
            registerButton.setTitle(registerTitle, for: .normal)
            registerButton.setTitleColor(.white, for: .normal)
            registerButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            registerButton.backgroundColor = registerEnabled ? .systemBlue : .systemGray
            registerButton.layer.cornerRadius = 8
            registerButton.isEnabled = registerEnabled
            registerButton.addAction(UIAction { [weak self] _ in self?.onRegister?() }, for: .touchUpInside)
            addSubview(registerButton)
        }

        card.contentHorizontalAlignment = .left
        card.titleLabel?.numberOfLines = 3
        card.titleLabel?.font = .systemFont(ofSize: 18)
        card.titleLabel?.lineBreakMode = .byTruncatingTail
        card.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: reorderMode ? 56 : 12)
        card.layer.cornerRadius = 8
        card.backgroundColor = cardColor
        card.setTitle(phrase, for: .normal)
        card.setTitleColor(textColor, for: .normal)
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
        if showsRegister {
            registerButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                registerButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor),
                registerButton.topAnchor.constraint(equalTo: topAnchor),
                registerButton.bottomAnchor.constraint(equalTo: bottomAnchor),
                registerButton.widthAnchor.constraint(equalToConstant: Self.registerWidth)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setOpen(_ open: Bool, animated: Bool) {
        isOpen = open
        let target = CGAffineTransform(translationX: open ? -revealWidth : 0, y: 0)
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
            let x = min(0, max(-revealWidth, panBase + gesture.translation(in: self).x))
            card.transform = CGAffineTransform(translationX: x, y: 0)
        case .ended, .cancelled:
            let shouldOpen = card.transform.tx < -revealWidth / 2 || gesture.velocity(in: self).x < -300
            setOpen(shouldOpen, animated: true)
        default:
            break
        }
    }
}
