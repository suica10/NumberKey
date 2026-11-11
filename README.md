# NumberKey v0.1.2

iOS 17以降の日本語ローマ字入力／英字QWERTYキーボード。最上段に数字を常時表示します。

## 状態

GitHub ActionsでiPhone/iPad（arm64）向けの未署名IPA生成に成功した開発版です。
ローマ字入力・促音拗音・辞書変換・連続変換の4件の自動テストが成功しました。
iOS 27シミュレーター上で、キーボード画面の起動・再表示・設定画面への往復の2件のテストも成功しました。
実機での地球儀による切り替えと、Feather再署名後の動作は再確認が必要です。

[成功したビルドとIPA](https://github.com/suica10/NumberKey/actions/runs/42948006584)

Artifactsの `NumberKey-unsigned-IPA` をダウンロードし、ZIP内の `NumberKey-unsigned.ipa` を取り出してください。

## v0.1.2の修正

キーボード拡張が参照する `@rpath/llama.framework/llama` が配布IPAに含まれず、画面の起動前に `DYLD / Library missing` で終了する不具合を修正しました。Xcodeの解決済みパッケージからiOS実機用フレームワークを本体アプリの `Frameworks` に同梱します。ニューラル変換は引き続き無効です。

完成IPAのMach-O依存関係を本体・キーボード拡張・同梱ライブラリについて再帰的に検査し、欠落がある場合はビルドを失敗させます。今回のIPAは依存関係検査・変換テスト4件・iOS 27の画面起動テスト2件に成功しました。Featherで再署名した実機の切り替えは再確認が必要です。

[今回の起動テスト](https://github.com/suica10/NumberKey/actions/runs/42947840152)

## v0.1.1の修正

入力先の準備前に `textDocumentProxy.documentIdentifier` を読み取ると、nilからUUIDへの変換で起動時にクラッシュする不具合を修正しました。画面初期化時の識別子読み取りを廃止し、入力先の変更は既存の `textWillChange` と画面終了時の通知で処理します。

[修正後の起動テスト](https://github.com/suica10/NumberKey/actions/runs/42944599367)

## 機能

- 日本語ローマ字入力・かな漢字変換候補・英字入力
- 最上段10キーの数字／記号割り当て変更
- 矢印・削除長押し・数字／記号の長押し代替入力
- キーの高さ・自動／ライト／ダーク配色
- オフライン辞書変換。フルアクセス、通信、App Groupは不要

未確定文字はキーボード内に表示し、候補タップまたは確定キーで入力先に挿入します。
スペースで候補を選択・切り替えます。入力欄／キーボード切り替え時に未確定文字は取り消します。
英語の予測変換、入力学習、文節ごとの部分確定、ニューラル変換はこの版に含みません。
任意文字列によるキー編集ではなく、設定パレットから最上段キーを変更できます。

## GitHubでIPAを生成する

1. 自分のGitHubアカウントに `NumberKey` リポジトリを作成します。非公開で構いません。
2. このフォルダの内容をリポジトリ直下へ配置します。`.github/workflows/build-ipa.yml` も必要です。
3. `main` にpushするか、Actions → Build unsigned IPA → Run workflow を実行します。
4. 成功した実行のArtifactsから `NumberKey-unsigned-IPA` をダウンロードします。
5. ZIP内の `NumberKey-unsigned.ipa` を自分の署名環境で再署名します。

Apple ID、証明書、秘密鍵、Provisioning ProfileをGitHubへ登録する必要はありません。
未署名IPAはそのままインストールできません。本体と埋め込みキーボード拡張の両方を署名してください。
署名ツールでBundle IDを変更する場合は、本体と拡張の親子関係を保ってください。
利用プランによりGitHub Actionsの実行枠・ストレージ上限があります。

## Macで実行

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

日本語変換エンジンは `5a9c4f672f627c8db48241a3abc22409257f92cb` に固定し、辞書サブモジュールも固定リビジョンから取得します。
上流エンジンはMITライセンスです。辞書と依存パッケージのライセンスはビルド時に収集し本体アプリ内に同梱します。

## 実機で確認する項目

- `nihongo` → 日本語、`toukyou` → 東京、`gakkou` → がっこう
- 高速入力直後のスペース・候補選択中の追加入力・長文
- 入力欄の切り替え、キーボード切り替え、横画面、iPad
- 長押し削除を離したときに止まること、数字／記号長押しの二重入力がないこと
- 他アプリ・Web入力欄・絵文字付近のカーソル移動
- メモリ不足でキーボード拡張が終了しないこと
