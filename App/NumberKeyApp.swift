import SwiftUI
import PhotosUI
import UIKit

@main
struct NumberKeyApp: App {
    init() { KeyboardSettings.migrateLegacyAppPreferences() }
    var body: some Scene { WindowGroup { SettingsView() } }
}

struct SettingsView: View {
    @State private var layout = KeyboardSettings().snapshot
    @State private var sample = ""
    @Environment(\.colorScheme) private var colorScheme
    /// 着せ替えの背景画像ピッカーの選択と、プレビュー用の読み込み済み画像。
    @State private var backgroundPhotoItem: PhotosPickerItem?
    @State private var backgroundPreviewImage: UIImage?
    /// 背景画像プレビューのドラッグ開始時点の位置 (正規化オフセット)。
    @State private var backgroundDragBase: (x: Double, y: Double)?
    @State private var packEnabled: [DictionaryPackID: Bool] = [:]
    private let packStore = DictionaryPackStore()
    @StateObject private var store = StoreManager()
    @State private var gateState: PurchaseState = PurchaseGate.evaluateForDisplay()
    @AppStorage("setupGuide.seen.v1") private var setupGuideSeen = false
    @State private var showSetupGuide = false
    @State private var keyboardActivated = KeyboardSettings.lastActivatedAt != nil
    /// 購入状態の表示は StoreKit の確認結果を優先し、未確認の間は共有フラグ側の判定を使う。
    private var displayState: PurchaseState { store.isPurchased ? .unlocked : gateState }
    var body: some View {
        NavigationStack {
            Form {
                Section("ご利用状況") {
                    switch displayState {
                    case .unlocked:
                        Label("購入済み", systemImage: "checkmark.circle")
                        Text("全機能を利用できます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .trial(let daysLeft):
                        Text("体験中（残り\(daysLeft)日）")
                        Text("体験期間は1週間です。終了後は定型文・クリップボード履歴・辞書パックが使えなくなります（入力そのものはそのまま使えます）。購入すると、全機能を引き続き使えます。")
                            .font(.footnote).foregroundStyle(.secondary)
                        purchaseButtons
                    case .expired:
                        Text("体験期間が終了しました")
                        Text("入力そのものはそのまま使えます。購入すると、定型文・クリップボード履歴・辞書パックも使えるようになります。")
                            .font(.footnote).foregroundStyle(.secondary)
                        purchaseButtons
                    }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("セットアップ") {
                    Button("キーボードの設定方法") { showSetupGuide = true }
                    Text(keyboardActivated
                         ? "キーボードの起動を確認済みです（フルアクセス許可済み）。"
                         : "まだキーボードが開かれていません。設定方法を確認してください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("表示") {
                    Picker("入力方式", selection: $layout.flickMode) {
                        Text("QWERTY").tag(false); Text("フリック").tag(true)
                    }
                    Picker("配色", selection: $layout.theme) {
                        Text("自動").tag(0); Text("ライト").tag(1); Text("ダーク").tag(2)
                    }
                    Toggle("画像に合わせたキーの高さ", isOn: Binding(
                        get: { layout.keyHeight == 0 },
                        set: { layout.keyHeight = $0 ? 0 : 43 }))
                    if layout.keyHeight != 0 {
                        HStack {
                            Text("高さ")
                            Slider(value: $layout.keyHeight, in: 32...60, step: 1)
                            Text("\(Int(layout.keyHeight))").monospacedDigit()
                        }
                    }
                    Toggle("日本語ローマ字入力で開始", isOn: $layout.japanese)
                }
                Section("着せ替え") {
                    Toggle("着せ替えを使う", isOn: $layout.customizationEnabled)
                    Text("オフのときは「配色」の設定どおりに表示します。オンにすると、背景画像と下で選んだ色がキーボードに適用されます。色を選んでいない要素は、配色どおりの色のままです。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if layout.customizationEnabled {
                        appearancePreview
                        PhotosPicker(selection: $backgroundPhotoItem, matching: .images, photoLibrary: .shared()) {
                            Label("背景画像を選ぶ", systemImage: "photo")
                        }
                        if layout.customAppearance.backgroundImageFileName != nil {
                            Picker("画像の表示", selection: $layout.customAppearance.backgroundImageFillsScreen) {
                                Text("全面に広げる").tag(true)
                                Text("全体を表示").tag(false)
                            }
                            HStack {
                                Text("画像に背景色を重ねる")
                                Slider(value: $layout.customAppearance.backgroundImageDim,
                                       in: CustomAppearance.backgroundImageDimRange)
                            }
                            backgroundAdjustPreview
                            HStack {
                                Text("画像の大きさ")
                                Slider(value: $layout.customAppearance.backgroundImageScale,
                                       in: CustomAppearance.backgroundImageScaleRange)
                            }
                            if layout.customAppearance.backgroundImageScale != 1
                                || layout.customAppearance.backgroundImageOffsetX != 0
                                || layout.customAppearance.backgroundImageOffsetY != 0 {
                                Button("画像の位置と大きさをリセット") {
                                    layout.customAppearance.backgroundImageScale = 1
                                    layout.customAppearance.backgroundImageOffsetX = 0
                                    layout.customAppearance.backgroundImageOffsetY = 0
                                }
                            }
                            Button("背景画像を削除", role: .destructive) {
                                if let name = layout.customAppearance.backgroundImageFileName {
                                    KeyboardBackgroundImageStore.remove(fileName: name)
                                }
                                layout.customAppearance.backgroundImageFileName = nil
                                backgroundPreviewImage = nil
                            }
                        }
                        colorRow("背景", \.background, standard: standardPalette.background)
                        colorRow("キーの面", \.keyFace, standard: standardPalette.keyFace)
                        colorRow("キーを押したとき", \.keyPressed, standard: standardPalette.keyPressed)
                        colorRow("キーの文字", \.keyText, standard: standardPalette.keyText)
                        colorRow("候補の文字", \.candidateText, standard: standardPalette.candidateText)
                        colorRow("候補の選択背景", \.candidateSelectedBackground, standard: standardPalette.candidateSelectedBackground)
                        colorRow("パネルの背景", \.panelBackground, standard: standardPalette.panelBackground)
                        colorRow("パネルの枠", \.panelBorder, standard: standardPalette.panelBorder)
                        colorRow("パネルの行", \.panelCardBackground, standard: standardPalette.panelCardBackground)
                        colorRow("パネルの文字", \.panelText, standard: standardPalette.panelText)
                        colorRow("フリック選択中の背景", \.popupSelectedBackground, standard: standardPalette.popupSelectedBackground)
                        colorRow("フリック選択中の文字", \.popupSelectedText, standard: standardPalette.popupSelectedText)
                        Button("色をすべてデフォルトに戻す") { layout.customAppearance.resetColors() }
                    }
                }
                .onChange(of: backgroundPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        defer { backgroundPhotoItem = nil }
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data),
                           let name = KeyboardBackgroundImageStore.save(image) {
                            layout.customAppearance.backgroundImageFileName = name
                            // 画像が替わったら位置・大きさは初期状態から調整する。
                            layout.customAppearance.backgroundImageScale = 1
                            layout.customAppearance.backgroundImageOffsetX = 0
                            layout.customAppearance.backgroundImageOffsetY = 0
                            backgroundPreviewImage = KeyboardBackgroundImageStore.loadImage(fileName: name)
                        }
                    }
                }
                Section("辞書パック") {
                    ForEach(DictionaryPackID.allCases, id: \.rawValue) { id in
                        Toggle(id.displayName, isOn: Binding(
                            get: { packEnabled[id] ?? packStore.isEnabled(id) },
                            set: { value in
                                packEnabled[id] = value
                                packStore.setEnabled(id, value)
                            }))
                            // 期限切れの間はパック自体が無効。設定値そのものは
                            // 変えず、購入すればこの設定どおりに戻る。
                            .disabled(displayState == .expired)
                    }
                    if displayState == .expired {
                        Text("体験期間が終了したため、辞書パックは現在使えません。購入すると、ここの設定どおりに使えます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("ON の辞書だけを読み込みます。SNS の候補は、変換候補の先頭に出ます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("定型文") {
                    Text("定型文はキーボードの中で登録・削除します。スペースキーを長押しして「定型文を追加」を選ぶと、そのまま入力して保存できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("定型文はキーボード拡張の中だけに保存されるため、再署名の方法に左右されません。以前このアプリで登録した定型文は、キーボードを初めて開いたときに自動で引き継がれます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("クリップボード") {
                    Text("コピーしたテキストは、キーボードを開いたときにクリップボード履歴へ自動で記録されます。リターンキーを長押しすると履歴が開き、タップでそのまま入力できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("クリップボードの読み取りにはフルアクセスが必要です。履歴はこの端末の中（アプリ共有領域）だけに保存され、外部に送信されることはありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("キーボードへの反映") {
                    Text("設定は自動保存されます。キーボードを次に開いたときに反映されます。")
                    Text("入力内容は送信せず、選んだ変換候補を端末内に学習します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("入力を試す") {
                    TextEditor(text: $sample)
                        .frame(minHeight: 120).autocorrectionDisabled()
                    Text("日本語の未確定文字は、この入力欄に直接表示されます。スペースで変換し、候補タップまたは確定キーで確定します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("使い方") {
                    Text("「123」の長押し：カーソルを左右に移動")
                    Text("地球儀：日本語／English切り替え（長押しメニューで次のキーボードへ）")
                    Text("シフトを2回タップ：大文字を固定")
                    Text("スペースを長押し：入力モード選択・定型文入力")
                    Text("リターンを長押し：クリップボード履歴を開く（フルアクセスが必要）")
                    Text("削除を長押し：連続削除")
                    Text("キーボードの追加：設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → One Keyboard")
                }
                Section {
                    Text("One Keyboard v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-") ・ iOS 17以降").foregroundStyle(.secondary)
                    NavigationLink("オープンソースライセンス") {
                        ScrollView { Text(licenseText).font(.system(.footnote, design: .monospaced)).padding().textSelection(.enabled) }
                            .navigationTitle("ライセンス")
                    }
                }
            }
            .navigationTitle("One Keyboard")
            .onChange(of: layout) { _, value in KeyboardSettings().apply(value) }
            .task {
                packEnabled = DictionaryPackID.allCases.reduce(into: [:]) { $0[$1] = packStore.isEnabled($1) }
                await store.refresh()
                // 購入確認で unlocked フラグが書かれた可能性があるので判定し直す。
                gateState = PurchaseGate.currentState()
            }
            .onChange(of: store.isPurchased) { _, purchased in
                if purchased { gateState = .unlocked }
            }
            .sheet(isPresented: $showSetupGuide, onDismiss: { setupGuideSeen = true }) {
                SetupGuideView()
            }
            .onAppear {
                keyboardActivated = KeyboardSettings.lastActivatedAt != nil
                if backgroundPreviewImage == nil, let name = layout.customAppearance.backgroundImageFileName {
                    backgroundPreviewImage = KeyboardBackgroundImageStore.loadImage(fileName: name)
                }
                if !setupGuideSeen { showSetupGuide = true }
            }
        }
    }
    /// このアプリの表示モードに対する現行パレット (ピッカーの初期値用)。
    private var standardPalette: KeyboardPalette { KeyboardPalette.standard(dark: colorScheme == .dark) }
    /// 着せ替えを反映した実効パレット (プレビュー用)。
    private var effectivePalette: KeyboardPalette { layout.resolvedPalette(dark: colorScheme == .dark) }

    /// 背景画像の描画矩形。キーボード側と共有の計算を使うため、
    /// プレビューで見たままがキーボードに出る。
    private func backgroundRect(containerSize: CGSize, image: UIImage) -> CGRect {
        CustomAppearance.backgroundImageRect(
            containerSize: containerSize, imageSize: image.size,
            fillsScreen: layout.customAppearance.backgroundImageFillsScreen,
            scale: layout.customAppearance.backgroundImageScale,
            offsetX: layout.customAppearance.backgroundImageOffsetX,
            offsetY: layout.customAppearance.backgroundImageOffsetY)
    }

    /// 背景画像の位置調整プレビュー。ドラッグで位置を動かす
    /// (大きさは下のスライダー)。計算はキーボード側と同一。
    private var backgroundAdjustPreview: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(uiColor: effectivePalette.background.uiColor)
                if let image = backgroundPreviewImage {
                    let rect = backgroundRect(containerSize: geo.size, image: image)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(backgroundDragGesture(containerSize: geo.size))
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func backgroundDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let image = backgroundPreviewImage else { return }
                if backgroundDragBase == nil {
                    backgroundDragBase = (layout.customAppearance.backgroundImageOffsetX,
                                          layout.customAppearance.backgroundImageOffsetY)
                }
                guard let base = backgroundDragBase else { return }
                // 移動量 (pt) を正規化オフセットへ換算する。オフセット 1 は
                // 「はみ出し/余白の半分」の移動にあたる (rect 計算と対)。
                // rect の寸法はオフセットに依存しないためドラッグ中も安定する。
                let rect = backgroundRect(containerSize: containerSize, image: image)
                let slackX = containerSize.width - rect.width
                let slackY = containerSize.height - rect.height
                if abs(slackX) > 1 {
                    layout.customAppearance.backgroundImageOffsetX =
                        min(1, max(-1, base.x + Double(value.translation.width) / (abs(slackX) / 2)))
                }
                if abs(slackY) > 1 {
                    layout.customAppearance.backgroundImageOffsetY =
                        min(1, max(-1, base.y + Double(value.translation.height) / (abs(slackY) / 2)))
                }
            }
            .onEnded { _ in backgroundDragBase = nil }
    }

    /// 着せ替えのミニプレビュー。背景画像＋背景色の重ねの上に、候補と
    /// キーのサンプルを実効パレットで描く。
    private var appearancePreview: some View {
        let palette = effectivePalette
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image = backgroundPreviewImage {
                    let rect = backgroundRect(containerSize: geo.size, image: image)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Color(uiColor: palette.background.uiColor)
                        .opacity(layout.customAppearance.backgroundImageDim)
                } else {
                    Color(uiColor: palette.background.uiColor)
                }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("候補")
                        .foregroundStyle(Color(uiColor: palette.candidateText.uiColor))
                    Text("選択中")
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(uiColor: palette.candidateSelectedBackground.uiColor))
                        .foregroundStyle(Color(uiColor: palette.candidateText.uiColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
                .font(.system(size: 14))
                HStack(spacing: 5) {
                    ForEach(["Q", "W", "E", "R", "T"], id: \.self) { character in
                        Text(character)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color(uiColor: palette.keyFace.uiColor))
                            .foregroundStyle(Color(uiColor: palette.keyText.uiColor))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                .font(.system(size: 15))
            }
            .padding(8)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 要素ごとの色ピッカー行。未ピックの要素は現行パレットの色を初期値
    /// として見せ、ピック済みの要素にはデフォルトへ戻すボタンを出す。
    private func colorRow(_ title: String, _ keyPath: WritableKeyPath<CustomAppearance, KeyboardColor?>,
                          standard: KeyboardColor) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { (layout.customAppearance[keyPath: keyPath] ?? standard).cgColor },
                set: { newValue in
                    if let picked = KeyboardColor(cgColor: newValue) {
                        layout.customAppearance[keyPath: keyPath] = picked
                    }
                }), supportsOpacity: true)
            if layout.customAppearance[keyPath: keyPath] != nil {
                Button {
                    layout.customAppearance[keyPath: keyPath] = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(title)をデフォルトに戻す")
            }
        }
    }

    @ViewBuilder
    private var purchaseButtons: some View {
        Button {
            Task { await store.purchase() }
        } label: {
            if let product = store.product {
                Text("購入する（\(product.displayPrice)）")
            } else {
                Text("購入する")
            }
        }
        .disabled(store.isWorking || store.product == nil)
        Button("購入を復元") { Task { await store.restore() } }
            .disabled(store.isWorking)
        if store.isWorking { ProgressView() }
    }
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "ライセンス情報を読み込めませんでした。" }
        return text
    }
}

/// 初回起動時に表示するセットアップガイド。キーボードの追加と
/// フルアクセス許可の手順を案内する。キーボード設定画面への直接の
/// リンクは iOS に無いため、手順は設定アプリの階層で示す。
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var activated = KeyboardSettings.lastActivatedAt != nil
    @State private var testText = ""

    private let steps = [
        "設定アプリを開きます。",
        "「一般」→「キーボード」→「キーボード」の順にタップします。",
        "「新しいキーボードを追加…」から One Keyboard を選びます。",
        "追加された One Keyboard をタップし、「フルアクセスを許可」をオンにします。",
        "この画面の一番下にあるテスト入力でキーボードを切り替えて、One Keyboard が出れば完了です。"
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("キーボードの設定方法") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.footnote.weight(.bold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor))
                                .foregroundStyle(.white)
                            Text(step)
                        }
                    }
                }
                Section("フルアクセスについて") {
                    Text("フルアクセスは、定型文・クリップボード履歴・辞書パックなどのデータを本体アプリとキーボードで共有するために使います。入力した内容が端末の外に送信されることはありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("設定の確認") {
                    if activated {
                        Label("キーボードの起動を確認済みです", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Text("まだキーボードが開かれていません。設定後にキーボードを一度開くと、ここに確認結果が表示されます。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("再確認") { activated = KeyboardSettings.lastActivatedAt != nil }
                    }
                }
                Section("テスト入力") {
                    TextEditor(text: $testText)
                        .frame(height: 90)
                    Text("ここをタップするとキーボードが開きます。地球儀キーで One Keyboard に切り替えて、そのまま入力を試せます。外部のアプリを開く必要はありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("セットアップ")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear { activated = KeyboardSettings.lastActivatedAt != nil }
        }
    }
}
