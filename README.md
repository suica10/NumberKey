# NumberKey v0.3.0

数字列付きの日本語ローマ字入力／英字QWERTYキーボードです。iOS 17以降に対応します。

## 今回の変更

- 参照画像の比率に合わせたキーの幅・高さ・余白・配色。最下段は123／地球儀／space／return。
- 待機中はキーだけを表示。説明文やキーボード内の配置編集画面は表示しません。
- 地球儀をタップすると日本語とEnglishを切り替えます。地球儀の長押しメニューから他のキーボードへ移動できます。
- 日本語の未確定文字を入力先に直接表示。スペースで候補を選び、候補タップまたは確定キーで確定します。
- 本体アプリに定型文を最大20件、各100文字まで登録し、配置と一緒にコピーしてキーボードへ読み込めます。スペース長押しで入力モードと定型文のリストを開き、定型文を選ぶと入力します。
- キーを押すと文字を拡大表示します。
- 本体アプリで数字・英字36キーの位置を入れ替えられます。2つのキーを順に選ぶと交換します。
- 配色、キーの高さ、開始時の入力言語も本体アプリで設定します。

## 配置をキーボードへ反映

1. NumberKeyアプリで配置を編集します。
2. アプリの「配置をコピー」を押します。
3. キーボードの123キーを長押しし、「配置・定型文を読み込む」を選びます。

初回はiPhoneの設定 → 一般 → キーボード → キーボード → NumberKeyで「フルアクセスを許可」をオンにしてください。貼り付けの確認が出たら許可します。

クリップボードを読むのは、読み込みを明示的に選択したときだけです。設定はコピー先の端末内で反映し、入力内容を外部へ送信する通信処理はありません。App Groupsは使用しません。

## キー操作

- 123をタップ：記号配列と英字配列を切り替え
- 123を長押し：カーソル移動、配置と定型文の読み込み
- 地球儀をタップ：日本語／Englishを切り替え。長押しメニュー：次のキーボードへ
- spaceを長押し：入力モード選択と定型文リスト
- シフト：大文字。2回タップで大文字固定
- 削除の長押し：連続削除
- 日本語のスペース：変換候補を選択・切り替え。未入力時は空白
- 日本語の確定キー：未確定文字を確定。未入力時は改行

## IPAの生成と再署名

GitHub Actionsの Build unsigned IPA を実行し、Artifactsの NumberKey-unsigned-IPA をダウンロードします。ZIP内のNumberKey-unsigned.ipaを自分の署名環境で再署名してください。本体、キーボード拡張、同梱フレームワークが署名対象です。

ビルドではかな漢字変換のテストを実施し、実機用llama.frameworkを本体アプリのFrameworksへ同梱します。完成IPAのMach-O依存関係を再帰的に検査し、必要なライブラリの欠落があれば失敗させます。ニューラル変換モデルは使用しません。

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
