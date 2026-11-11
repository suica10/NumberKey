import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct NumberKeyApp: App {
    var body: some Scene { WindowGroup { SettingsView() } }
}

struct SettingsView: View {
    @State private var layout = KeyboardSettings().snapshot
    @State private var selected: Slot?
    @State private var copied = false
    @State private var sample = ""
    private struct Slot: Equatable { let row: Int; let column: Int }
    var body: some View {
        NavigationStack {
            Form {
                Section("キー配置") {
                    Text("入れ替えたい2つのキーを順にタップ")
                        .font(.footnote).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        let gap: CGFloat = 4
                        let width = max(18, (geometry.size.width - gap * 9) / 10)
                        VStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { row in
                                HStack(spacing: gap) {
                                    ForEach(0..<layout.rows[row].count, id: \.self) { column in
                                        let slot = Slot(row: row, column: column)
                                        Button { select(slot) } label: {
                                            Text(layout.rows[row][column])
                                                .font(.system(size: 20))
                                                .frame(width: width, height: 38)
                                                .background(selected == slot ? Color.accentColor : Color(white: 0.38))
                                                .foregroundStyle(.white)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain)
                                    }
                                }.frame(maxWidth: .infinity)
                            }
                        }.padding(.vertical, 7)
                    }.frame(height: 186)
                    Button("標準の配置に戻す") { layout.rows = LayoutSettings.defaults.rows; selected = nil }
                }
                Section("表示") {
                    Picker("配色", selection: $layout.theme) {
                        Text("自動").tag(0); Text("ライト").tag(1); Text("ダーク").tag(2)
                    }
                    Toggle("画像に合わせたキーの高さ", isOn: Binding(
                        get: { layout.keyHeight == 0 },
                        set: { layout.keyHeight = $0 ? 0 : 38 }))
                    if layout.keyHeight != 0 {
                        HStack {
                            Text("高さ")
                            Slider(value: $layout.keyHeight, in: 32...60, step: 1)
                            Text("\(Int(layout.keyHeight))").monospacedDigit()
                        }
                    }
                    Toggle("日本語ローマ字入力で開始", isOn: $layout.japanese)
                }
                Section("キーボードに反映") {
                    Button(copied ? "配置をコピーしました" : "配置をコピー") {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: layout.exportString()]], options: [.localOnly: true])
                        copied = true
                    }.font(.headline)
                    Text("コピー後、キーボードの「123」を長押しして「配置を読み込む」を選びます。")
                    Text("読み込みには、iPhoneの設定 → 一般 → キーボード → キーボード → NumberKeyで「フルアクセスを許可」をオンにしてください。貼り付けの確認が出たら許可します。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("配置は明示的に読み込んだときだけクリップボードから取得します。入力内容を送信する通信処理はありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("入力を試す") {
                    TextEditor(text: $sample)
                        .frame(minHeight: 120).autocorrectionDisabled()
                    Text("日本語の未確定文字は、この入力欄に直接表示されます。スペースで変換し、候補タップまたは確定キーで確定します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("使い方") {
                    Text("「123」の長押し：日本語／Englishの切り替え・カーソル移動・配置の読み込み")
                    Text("地球儀：キーボードの切り替え")
                    Text("シフトを2回タップ：大文字を固定")
                    Text("削除を長押し：連続削除")
                    Text("キーボードの追加：設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → NumberKey 日本語")
                }
                Section {
                    Text("NumberKey v0.2.0 ・ iOS 17以降").foregroundStyle(.secondary)
                    NavigationLink("オープンソースライセンス") {
                        ScrollView { Text(licenseText).font(.system(.footnote, design: .monospaced)).padding().textSelection(.enabled) }
                            .navigationTitle("ライセンス")
                    }
                }
            }
            .navigationTitle("NumberKey")
            .onChange(of: layout) { _, value in KeyboardSettings().snapshot = value; copied = false }
        }
    }
    private func select(_ slot: Slot) {
        guard let previous = selected else { selected = slot; return }
        if previous != slot {
            let old = layout.rows[previous.row][previous.column]
            layout.rows[previous.row][previous.column] = layout.rows[slot.row][slot.column]
            layout.rows[slot.row][slot.column] = old
        }
        selected = nil
    }
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "ライセンス情報を読み込めませんでした。" }
        return text
    }
}
