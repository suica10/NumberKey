import SwiftUI

@main
struct NumberKeyApp: App {
    init() { KeyboardSettings.migrateLegacyAppPreferences() }
    var body: some Scene { WindowGroup { SettingsView() } }
}

struct SettingsView: View {
    @State private var layout = KeyboardSettings().snapshot
    @State private var sample = ""
    @State private var packEnabled: [DictionaryPackID: Bool] = [:]
    private let packStore = DictionaryPackStore()
    @StateObject private var store = StoreManager()
    @State private var gateState: PurchaseState = PurchaseGate.evaluateForDisplay()
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
                        Text("体験期間は1週間です。終了後はキーボードが使えなくなります。購入すると、そのまま引き続き使えます。")
                            .font(.footnote).foregroundStyle(.secondary)
                        purchaseButtons
                    case .expired:
                        Text("体験期間が終了しました")
                        Text("購入すると、引き続き使えます。")
                            .font(.footnote).foregroundStyle(.secondary)
                        purchaseButtons
                    }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("表示") {
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
                Section("辞書パック") {
                    ForEach(DictionaryPackID.allCases, id: \.rawValue) { id in
                        Toggle(id.displayName, isOn: Binding(
                            get: { packEnabled[id] ?? packStore.isEnabled(id) },
                            set: { value in
                                packEnabled[id] = value
                                packStore.setEnabled(id, value)
                            }))
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
                    Text("リターンを長押し：クリップボードのテキストを貼り付け（フルアクセスが必要）")
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
