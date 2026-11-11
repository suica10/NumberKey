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
                Section("定型文") {
                    Text("ここに登録した文章は、キーボードのスペースキーを長押しすると上からリストで表示されます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(layout.phrases.indices), id: \.self) { index in
                        HStack(spacing: 10) {
                            TextField("定型文を入力", text: $layout.phrases[index], axis: .vertical)
                                .lineLimit(1...3)
                            Button(role: .destructive) {
                                layout.phrases.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("定型文を削除")
                        }
                    }
                    if layout.phrases.count < 20 {
                        Button {
                            layout.phrases.append("")
                        } label: {
                            Label("定型文を追加", systemImage: "plus")
                        }
                    }
                    Text("\(layout.phrases.count) / 20")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("キーボードに反映") {
                    Button(copied ? "コピーしました" : "配置・定型文をコピー") {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: layout.exportString()]], options: [.localOnly: true])
                        copied = true
                    }.font(.headline)
                    Text("配置をコピーしたあと、キーボードの「123」を長押しして「配置・定型文を読み込む」を選びます。")
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
                    Text("「123」の長押し：カーソル移動・配置と定型文の読み込み")
                    Text("地球儀：日本語／English切り替え（長押しメニューで次のキーボードへ）")
                    Text("シフトを2回タップ：大文字を固定")
                    Text("スペースを長押し：入力モード選択・定型文入力")
                    Text("削除を長押し：連続削除")
                    Text("キーボードの追加：設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → NumberKey 日本語")
                }
                Section {
                    Text("NumberKey v0.3.0 ・ iOS 17以降").foregroundStyle(.secondary)
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
