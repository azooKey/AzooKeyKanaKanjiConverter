# Zenzai

ニューラルかな漢字変換エンジン「Zenzai」を有効化することで、高精度な変換を提供できます。利用するには変換オプションの`zenzaiMode`を設定します。

## 基本的な使い方

### Async API（推奨）

#### Zenzai（llama.cpp）を使用する場合

```swift
import KanaKanjiConverterModuleWithDefaultDictionary
let converter = KanaKanjiConverter.withDefaultDictionary()

@MainActor
func convert() async {
    let options = ConvertRequestOptions(
        requireJapanesePrediction: true,
        requireEnglishPrediction: false,
        keyboardLanguage: .ja_JP,
        learningType: .nothing,
        memoryDirectoryURL: documents,
        sharedContainerURL: documents,
        textReplacer: .withDefaultEmojiDictionary(),
        specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
        zenzaiMode: .on(
            weight: url,  // ggufファイルのパスを指定
            inferenceLimit: 1,
            versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
        ),
        metadata: .init(versionString: "Your App Version X")
    )

    let results = await converter.requestCandidatesAsync(composingText, options: options)
}
```

#### ZenzaiCoreMLを使用する場合（iOS 18+, macOS 15+）

```swift
import KanaKanjiConverterModuleWithDefaultDictionary
let converter = KanaKanjiConverter.withDefaultDictionary()

@MainActor
func convert() async {
    let options = ConvertRequestOptions(
        requireJapanesePrediction: true,
        requireEnglishPrediction: false,
        keyboardLanguage: .ja_JP,
        learningType: .nothing,
        memoryDirectoryURL: documents,
        sharedContainerURL: documents,
        textReplacer: .withDefaultEmojiDictionary(),
        specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
        zenzaiMode: .coreML(  // weight指定不要（バンドルモデルを使用）
            inferenceLimit: 1,
            versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
        ),
        metadata: .init(versionString: "Your App Version X")
    )

    let results = await converter.requestCandidatesAsync(composingText, options: options)
}
```

### 同期 API（レガシー）

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
    zenzaiMode: .on(
        weight: url,
        inferenceLimit: 1,
        versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
    ),
    metadata: .init(versionString: "Your App Version X")
)

// 非推奨: UIスレッドをブロックする可能性があります
let results = converter.requestCandidates(composingText, options: options)
```

### パラメータ

#### `.on(weight:inferenceLimit:versionDependentMode:)` - Zenzai（llama.cpp）用

* `weight`: `gguf`形式の重みファイルのパスを指定します。重みファイルは[Hugging Face](https://huggingface.co/Miwa-Keita/zenz-v3-small-gguf)からダウンロードできます。
* `inferenceLimit`: 推論回数の上限を指定します。通常`1`で十分ですが、低速でも高精度な変換を得たい場合は`5`程度の値にすることもできます。

#### `.coreML(inferenceLimit:versionDependentMode:)` - ZenzaiCoreML用（iOS 18+, macOS 15+）

* `weight`指定不要: CoreMLはバンドルに含まれるモデルを自動的に使用します。
* `inferenceLimit`: 推論回数の上限を指定します。通常`1`で十分ですが、低速でも高精度な変換を得たい場合は`5`程度の値にすることもできます。

## Trait の選択

Zenzaiを使用するには、Swift Package Traitsの設定が必要です。詳細は[README](../README.md#zenzaiを使う)を参照してください。

### Zenzai（llama.cpp + GPU）
GPU（Metal/CUDA）を使用した汎用的な高速推論。

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["Zenzai"])
```

### ZenzaiCoreML（CoreML + Stateful）
iOS 18+、macOS 15+ で利用可能な Stateful モデル。CPU/GPU で最適化された推論。

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["ZenzaiCoreML"])
```

### ZenzaiCPU（llama.cpp + CPU only）
GPUが使えない環境やデバッグ用。

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["ZenzaiCPU"])
```

## 動作環境

### llama.cpp ベース（Zenzai / ZenzaiCPU Trait）
* M1以上のスペックのあるmacOS環境が望ましいです。GPUを利用します。
* モデルサイズに依存しますが、現状150MB程度のメモリを必要とします
* Linux環境・Windows環境でもCUDAを用いて動作します。

### CoreML ベース（ZenzaiCoreML Trait）
* iOS 18+、macOS 15+ が必要です
* Stateful モデルを使用し、CPU/GPU で高速に動作します
* KV キャッシングを活用することで効率的な推論を実現します
* Swift Concurrency を活用した非同期実行により、UI スレッドをブロックしません
* Stateful モデルの仕組みについては [Apple の公式ドキュメント](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)を参照してください

## 仕組み
[Zennのブログ](https://zenn.dev/azookey/articles/ea15bacf81521e)をお読みいただくのが最もわかりやすい解説です。

## 用語
* **Zenzai**: ニューラルかな漢字変換システム
* **zenz-v1**: Zenzaiで用いることのできるかな漢字変換モデル「zenz」の第1世代。`\uEE00<input_katakana>\uEE01<output></s>`というフォーマットでかな漢字変換タスクを行う機能に特化。
* **zenz-v2**: Zenzaiで用いることのできるかな漢字変換モデル「zenz」の第2世代。第1世代の機能に加えて`\uEE00<input_katakana>\uEE02<context>\uEE01<output></s>`というフォーマットで、左文脈を読み込む機能を追加。
* **zenz-v3**: Zenzaiで用いることのできるかな漢字変換モデル「zenz」の第3世代。第2世代と異なり、`\uEE02<context>\uEE00<input_katakana>\uEE01<output></s>`のようにコンテキストを前置する方式を推奨。また、`\uEE03`に続けて入力されたプロフィール情報を考慮する動作をネイティブに学習済み。このほか、実験的に`\uEE04`+トピック、`\uEE05`+スタイル、`\uEE06`+設定も考慮できるようになっています。
