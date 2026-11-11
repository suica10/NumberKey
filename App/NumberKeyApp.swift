import SwiftUI

@main
struct NumberKeyApp: App {
    var body: some Scene {
        WindowGroup { WelcomeView() }
    }
}

struct WelcomeView: View {
    @State private var sample = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("数字を、いつでも。", systemImage: "keyboard")
                        .font(.title2.bold())
                    Text("日本語ローマ字入力と英字入力のための、数字列つきQWERTYキーボード。")
                }
                Section("使い始める") {
                    Text("1. iPhoneの「設定」を開く")
                    Text("2. 一般 → キーボード → キーボード → 新しいキーボードを追加")
                    Text("3. NumberKey 日本語を追加")
                    Text("4. 入力欄の地球儀キーでNumberKeyに切り替える")
                    Text("フルアクセスは不要です。入力内容は送信しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("入力を試す") {
                    TextEditor(text: $sample)
                        .frame(minHeight: 130)
                        .autocorrectionDisabled()
                    Text("nihongo → スペースで候補選択 → 確定。候補をタップしても入力できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("キーの使い方") {
                    Text("日本語 / ABC：入力言語の切り替え")
                    Text("スペース：変換候補の選択・切り替え")
                    Text("↵：変換中は確定、確定後は改行")
                    Text("← / →：未確定文字内、または入力欄のカーソル移動")
                    Text("⌫ 長押し：連続削除")
                    Text("数字・記号の長押し：別の記号を入力")
                    Text("⚙：キーの高さ・配色・最上段10キーの変更")
                }
                Section("この版について") {
                    Text("v0.1 開発版・iOS 17以降")
                    Text("未確定の日本語はキーボード内の上部に表示します。確定すると入力欄に入ります。入力欄やキーボードを切り替えると未確定文字は取り消されます。")
                    Text("パスワード欄など、iOSの制限によって標準キーボードが表示される場所があります。")
                    Text("日本語変換：AzooKeyKanaKanjiConverter。ニューラルモデル・学習・通信は使用しません。")
                    NavigationLink("オープンソースライセンス") {
                        ScrollView {
                            Text(licenseText)
                                .font(.system(.footnote, design: .monospaced))
                                .padding().textSelection(.enabled)
                        }.navigationTitle("ライセンス")
                    }
                }
            }
            .navigationTitle("NumberKey")
        }
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "ライセンス情報の読み込みに失敗しました。"
        }
        return text
    }
}
