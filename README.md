# AzooKeyKanaKanjiConverter

AzooKeyKanaKanjiConverterは[azooKey](https://github.com/ensan-hcl/azooKey)のために開発したかな漢字変換エンジンです。数行のコードでかな漢字変換をiOS / macOS / visionOSのアプリケーションに組み込むことができます。

また、AzooKeyKanaKanjiConverterはニューラルかな漢字変換システム「Zenzai」を利用した高精度な変換もサポートしています。

## 動作環境
iOS 16以降, macOS 13以降, visionOS 1以降, Ubuntu 22.04以降で動作を確認しています。Swift 6.1以上が必要です。

AzooKeyKanaKanjiConverterの開発については[開発ガイド](Docs/development_guide.md)をご覧ください。

## KanaKanjiConverterModule
かな漢字変換を受け持つモジュールです。

### セットアップ
* Xcodeprojの場合、XcodeでAdd Packageしてください。

* Swift Packageの場合、Package.swiftの`Package`の引数に`dependencies`以下の記述を追加してください。
  ```swift
  dependencies: [
      .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"))
  ],
  ```
  また、ターゲットの`dependencies`にも同様に追加してください。
  ```swift
  .target(
      name: "MyPackage",
      dependencies: [
          .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
      ],
  ),
  ```

> [!IMPORTANT]  
> AzooKeyKanaKanjiConverterはバージョン1.0のリリースまで開発版として運用するため、マイナーバージョンの変更で破壊的変更を実施する可能性があります。バージョンを指定する際にはマイナーバージョンが上がらないよう、`.upToNextMinor(from: "0.8.0")`のように指定することを推奨します。


### 使い方
```swift
// デフォルト辞書つきの変換モジュールをインポート
import KanaKanjiConverterModuleWithDefaultDictionary

// 変換器を初期化する
let converter = KanaKanjiConverter()
// 入力を初期化する
var c = ComposingText()
// 変換したい文章を追加する
c.insertAtCursorPosition("あずーきーはしんじだいのきーぼーどあぷりです", inputStyle: .direct)
// 変換のためのオプションを指定して、変換を要求
let results = converter.requestCandidates(c, options: .withDefaultDictionary(...))
// 結果の一番目を表示
print(results.mainResults.first!.text)  // azooKeyは新時代のキーボードアプリです
```
`options: .withDefaultDictionary(...)`は、`ConvertRequestOptions`を生成し、変換リクエストに必要な情報を指定します。詳しくはコード内のドキュメントコメントを参照してください。


### `ConvertRequestOptions`
`ConvertRequestOptions`は変換リクエストに必要な設定値です。例えば以下のように設定します。

```swift
let options = ConvertRequestOptions.withDefaultDictionary(
    // 日本語予測変換
    requireJapanesePrediction: true,
    // 英語予測変換 
    requireEnglishPrediction: false,
    // 入力言語 
    keyboardLanguage: .ja_JP,
    // 学習タイプ 
    learningType: .nothing, 
    // 学習データを保存するディレクトリのURL（書類フォルダを指定）
    memoryDirectoryURL: .documentsDirectory, 
    // ユーザ辞書データのあるディレクトリのURL（書類フォルダを指定）
    sharedContainerURL: .documentsDirectory, 
    // メタデータ
    metadata: .init(versionString: "You App Version X")
)
```

### `ComposingText`
`ComposingText`は入力管理を行いつつ変換をリクエストするためのAPIです。ローマ字入力などを適切にハンドルするために利用できます。詳しくは[ドキュメント](./Docs/composing_text.md)を参照してください。

### Zenzaiを使う
ニューラルかな漢字変換システム「Zenzai」を利用するには、追加で[Swift Package Traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)の設定を行う必要があります。AzooKeyKanaKanjiConverterは「Zenzai」というTraitをサポートしているので、これを追加してください。

```swift
dependencies: [
    .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["Zenzai"])
],
```

`ConvertRequestOptions`の`zenzaiMode`を指定します。詳しい引数の情報については[ドキュメント](./Docs/zenzai.md)を参照してください。

```swift
let options = ConvertRequestOptions.withDefaultDictionary(
    // ...
    zenzaiMode: .on(weight: url, inferenceLimit: 10)
    // ...
)
```

### 辞書データ

AzooKeyKanaKanjiConverterのデフォルト辞書として[azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage)がサブモジュールとして指定されています。過去のバージョンの辞書データは[Google Drive](https://drive.google.com/drive/folders/1Kh7fgMFIzkpg7YwP3GhWTxFkXI-yzT9E?usp=sharing)からもダウンロードすることができます。

また、以下のフォーマットであれば自前で用意した辞書データを利用することもできます。カスタム辞書データのサポートは限定的なので、ソースコードを確認の上ご利用ください。

```
- Dictionary/
  - louds/
    - charId.chid
    - X.louds
    - X.loudschars2
    - X.loudstxt3
    - ...
  - p/
    - X.csv
  - cb/
    - 0.binary
    - 1.binary
    - ...
  - mm.binary
```

デフォルト以外の辞書データを利用する場合、ターゲットの`dependencies`に以下を追加してください。
```swift
.target(
  name: "MyPackage",
  dependencies: [
      .product(name: "KanaKanjiConverterModule", package: "AzooKeyKanaKanjiConverter")
  ],
),
```

利用時に、辞書データのディレクトリを明示的に指定する必要があります。
```swift
// デフォルト辞書を含まない変換モジュールを指定
import KanaKanjiConverterModule

let options = ConvertRequestOptions(
    // 日本語予測変換
    requireJapanesePrediction: true,
    // 英語予測変換 
    requireEnglishPrediction: false,
    // 入力言語 
    keyboardLanguage: .ja_JP,
    // 学習タイプ 
    learningType: .nothing, 
    // ここが必要
    // 辞書データのURL（先ほど追加した辞書リソースを指定）
    dictionaryResourceURL: Bundle.main.bundleURL.appending(path: "Dictionary", directoryHint: .isDirectory),
    // 学習データを保存するディレクトリのURL（書類フォルダを指定）
    memoryDirectoryURL: .documentsDirectory, 
    // ユーザ辞書データのあるディレクトリのURL（書類フォルダを指定）
    sharedContainerURL: .documentsDirectory, 
    // メタデータ
    metadata: .init(versionString: "You App Version X")
)
```

`dictionaryResourceURL`のオプションは`KanaKanjiConverterModuleWithDefaultDictionary`モジュールでも利用できますが、バンドルに含まれる辞書リソースが利用されないため、アプリケーションサイズが不必要に大きくなります。デフォルトでない辞書データを利用する場合は`KanaKanjiConverterModule`を利用してください。

## SwiftUtils
Swift一般に利用できるユーティリティのモジュールです。
