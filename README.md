# AzooKeyKanaKanjiConverter

AzooKeyKanaKanjiConverterは[azooKey](https://github.com/ensan-hcl/azooKey)のために開発したかな漢字変換エンジンです。数行のコードでかな漢字変換をiOS / macOS / visionOSのアプリケーションに組み込むことができます。

また、AzooKeyKanaKanjiConverterはニューラルかな漢字変換システム「Zenzai」を利用した高精度な変換もサポートしています。

## 動作環境
iOS 16以降, macOS 13以降, visionOS 1以降, Ubuntu 22.04以降で動作を確認しています。Swift 6.1以上が必要です。

AzooKeyKanaKanjiConverterの開発については[開発ガイド](Docs/development_guide.md)をご覧ください。
学習データの保存先やリセット方法については[Docs/learning_data.md](Docs/learning_data.md)を参照してください。

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

// 変換器を初期化する（デフォルト辞書を利用）
let converter = KanaKanjiConverter.withDefaultDictionary()
// 入力を初期化する
var c = ComposingText()
// 変換したい文章を追加する
c.insertAtCursorPosition("あずーきーはしんじだいのきーぼーどあぷりです", inputStyle: .direct)
// 変換のためのオプションを指定して、変換を要求
let results = converter.requestCandidates(c, options: .init(
    N_best: 10,
    requireJapanesePrediction: .autoMix,
    requireEnglishPrediction: .disabled,
    keyboardLanguage: .ja_JP,
    englishCandidateInRoman2KanaInput: true,
    fullWidthRomanCandidate: false,
    halfWidthKanaCandidate: false,
    learningType: .inputAndOutput,
    maxMemoryCount: 65536,
    shouldResetMemory: false,
    memoryDirectoryURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!,
    sharedContainerURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!,
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
    metadata: .init(versionString: "Your App Version X")
))
// 結果の一番目を表示
print(results.mainResults.first!.text)  // azooKeyは新時代のキーボードアプリです
```
`ConvertRequestOptions`は変換リクエストに必要な情報を指定します。詳しくはコード内のドキュメントコメントを参照してください。


### `ConvertRequestOptions`
`ConvertRequestOptions`は変換リクエストに必要な設定値です。例えば以下のように設定します。

```swift
let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!
let options = ConvertRequestOptions(
    // 日本語予測変換
    requireJapanesePrediction: .autoMix,
    // 英語予測変換 
    requireEnglishPrediction: .disabled,
    // 入力言語 
    keyboardLanguage: .ja_JP,
    // 学習タイプ 
    learningType: .nothing, 
    // 学習データを保存するディレクトリのURL（書類フォルダを指定）
    memoryDirectoryURL: documents,
    // ユーザ辞書データのあるディレクトリのURL（書類フォルダを指定）
    sharedContainerURL: documents,
    // メタデータ
    metadata: .init(versionString: "Your App Version X"),
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders
)
```

開く際に保存処理が中断された `.pause` ファイルが残っている場合は、変換器が自動的に復旧を試みてファイルを削除します。

### `ComposingText`
`ComposingText`は入力管理を行いつつ変換をリクエストするためのAPIです。ローマ字入力などを適切にハンドルするために利用できます。詳しくは[ドキュメント](./Docs/composing_text.md)を参照してください。

### Zenzaiを使う
ニューラルかな漢字変換システム「Zenzai」を利用するには、追加で[Swift Package Traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)の設定を行う必要があります。AzooKeyKanaKanjiConverterはGPU向けの「Zenzai」およびCPU専用の「ZenzaiCPU」というTraitをサポートしています。環境に応じていずれかを追加してください。

```swift
dependencies: [
    // GPU (Metal/CUDA 等) を使う場合
    .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["Zenzai"]),
    // CPU のみで動作させる場合（オフロード無効）
    // .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["ZenzaiCPU"]),
],
```

`ConvertRequestOptions`の`zenzaiMode`を指定します。詳しい引数の情報については[ドキュメント](./Docs/zenzai.md)を参照してください。

```swift
let options = ConvertRequestOptions(
    // ...
    requireJapanesePrediction: .autoMix,
    requireEnglishPrediction: .disabled,
    keyboardLanguage: .ja_JP,
    learningType: .nothing,
    memoryDirectoryURL: documents,
    sharedContainerURL: documents,
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
    zenzaiMode: .on(weight: url, inferenceLimit: 10),
    metadata: .init(versionString: "Your App Version X")
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

利用時に、辞書データのディレクトリを明示的に指定する必要があります（オプションではなく、変換器の初期化時に指定します）。
```swift
// デフォルト辞書を含まない変換モジュールを指定
import KanaKanjiConverterModule

let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!
// カスタム辞書ディレクトリを指定して変換器を初期化
let dictionaryURL = Bundle.main.bundleURL.appending(path: "Dictionary", directoryHint: .isDirectory)
let converter = KanaKanjiConverter(dictionaryURL: dictionaryURL, preloadDictionary: true)

// 変換リクエスト時のオプションを用意
let options = ConvertRequestOptions(
    requireJapanesePrediction: .autoMix,
    requireEnglishPrediction: .disabled,
    keyboardLanguage: .ja_JP,
    learningType: .nothing,
    memoryDirectoryURL: documents,
    sharedContainerURL: documents,
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
    metadata: .init(versionString: "Your App Version X")
)
```
`dictionaryResourceURL` は `ConvertRequestOptions` から廃止されました。デフォルト辞書を使う場合は `KanaKanjiConverterModuleWithDefaultDictionary` を、カスタム辞書を使う場合は `KanaKanjiConverterModule` を利用し、変換器初期化時に辞書ディレクトリを指定してください。

## SwiftUtils
Swift一般に利用できるユーティリティのモジュールです。
