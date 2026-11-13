# NumberKey v0.3.4

数字列付きの日本語ローマ字入力／英字QWERTYキーボードです。iOS 17以降に対応します。

## 今回の変更

- 参照画像に合わせたキー配置。Lの右にハイフンを追加し、最下段に読点・句点キーを配置しました。
- 待機中はキーだけを表示。説明文やキーボード内の配置編集画面は表示しません。
- 地球儀をタップすると日本語とEnglishを切り替えます。地球儀の長押しメニューから他のキーボードへ移動できます。
- 日本語の未確定文字を入力先に直接表示。スペースで候補を選び、候補タップまたは確定キーで確定します。
- 定型文は最大20件、各100文字まで。登録・削除はキーボード内で完結します（スペース長押し→「定型文を追加」で入力して保存、その場で変換も使えます）。スペース長押しで入力モードと定型文リストを開きます。
- キーを押すと文字を拡大表示します。
- 日本語モードの数字・記号は全角で入力します。日本語のスペースキーには「日本語」と表示します。
- 日本語入力中に数字・記号キーを押すと、未確定文字に続けて変換対象へ加えます。変換確定後に句読点が先頭へ飛ばないようにします。
- キーボードを開いた時とスペースキーのメニューを開く時に共有設定を再読込します。定型文はキーボード内の保存のため再読込は不要です。
- 本体アプリでキーの位置を入れ替えられます。2つのキーを順に選ぶと交換します。
- 配色、キーの高さ、開始時の入力言語も本体アプリで設定します。

## アプリ設定の共有

アプリとキーボード拡張は `group.jp.suica10.NumberKey` App Groupを使ってキー配置を共有します。再署名時にApp Groupが外れると配置の共有は止まりますが、定型文はキーボード拡張内に保存されるため影響を受けません。以前のアプリ設定は初回起動時に共有領域へ移行します。旧バージョンで共有領域に登録した定型文は、キーボードを初めて開いたときに拡張内へ自動で引き継がれます。

## キー操作

- 123／ABC：英字配列と記号配列を切り替え。記号画面の#+=で次の記号ページへ
- 123を長押し：カーソル移動
- 地球儀をタップ：日本語／Englishを切り替え。長押しメニュー：次のキーボードへ
- spaceを長押し：入力モード選択と定型文リスト
- 読点・句点キー：日本語モードでは「、」「。」、英語モードでは`,`と`.`
- 3段目のLの右：`-`
- returnを長押し：クリップボードのテキストを貼り付け（フルアクセスが必要）
- シフト：大文字。2回タップで大文字固定
- 削除の長押し：連続削除
- 日本語のスペース：変換候補を選択・切り替え。未入力時は空白
- 日本語の確定キー：未確定文字を確定。未入力時は改行

## IPAの生成と再署名

GitHub Actionsの Build unsigned IPA を実行し、Artifactsの NumberKey-unsigned-IPA をダウンロードします。ZIP内のNumberKey-unsigned.ipaを自分の署名環境で再署名してください。本体、キーボード拡張、同梱フレームワークが署名対象です。

ビルドではかな漢字変換のテストを実施し、実機用llama.frameworkを本体アプリのFrameworksへ同梱します。完成IPAのMach-O依存関係を再帰的に検査し、必要なライブラリの欠落があれば失敗させます。学習は有効で、選択した変換候補をキーボード拡張のApplication Supportに保存し、端末内で候補順に反映します。入力内容は外部へ送信しません。ニューラル変換モデルは使用しません。変換エンジンはキーボード表示時に先行初期化し、候補キーを再利用して候補表示の更新負荷を抑えます。

iOS 27シミュレーターの診断ワークフローでは、キー寸法の画像、未確定文字の表示・確定、削除、入力先の変更、配置データの読み込みを検査します。実機のアプリごとの入力動作と再署名後の動作は別途確認が必要です。

## Macで開発する

Xcode（Swift 6.1以降対応）とXcodeGenが必要です。

```bash
bash scripts/bootstrap.sh
xcodegen generate
swift test --configuration release
xcodebuild -resolvePackageDependencies -project NumberKey.xcodeproj -scheme NumberKey -clonedSourcePackagesDirPath build/SourcePackages
python3 scripts/collect_licenses.py
xcodebuild build -project NumberKey.xcodeproj -scheme NumberKey -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
python3 scripts/package_ipa.py
```

日本語変換エンジンはAzooKeyKanaKanjiConverterの5a9c4f672f627c8db48241a3abc22409257f92cbに固定しています。辞書・依存ライブラリのライセンスは本体アプリ内に同梱します。
