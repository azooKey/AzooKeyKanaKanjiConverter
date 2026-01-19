# Zenzai

By enabling the neural Kana-Kanji conversion engine "Zenzai", you can provide high-precision conversion. To use it, configure the `zenzaiMode` option in conversion options.

## Basic Usage

### Async API (Recommended)

#### Using Zenzai (llama.cpp)

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
            weight: url,  // Specify path to gguf file
            inferenceLimit: 1,
            versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
        ),
        metadata: .init(versionString: "Your App Version X")
    )

    let results = await converter.requestCandidatesAsync(composingText, options: options)
}
```

#### Using ZenzaiCoreML (iOS 18+, macOS 15+)

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
        zenzaiMode: .coreML(  // No weight path needed (uses bundled model)
            inferenceLimit: 1,
            versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
        ),
        metadata: .init(versionString: "Your App Version X")
    )

    let results = await converter.requestCandidatesAsync(composingText, options: options)
}
```

### Synchronous API (Legacy)

```swift
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
        weight: url,
        inferenceLimit: 1,
        versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
    ),
    metadata: .init(versionString: "Your App Version X")
)

// Deprecated: May block UI thread
let results = converter.requestCandidates(composingText, options: options)
```

### Parameters

#### `.on(weight:inferenceLimit:versionDependentMode:)` - For Zenzai (llama.cpp)

* `weight`: Specify the path to `gguf` format weight file. Weight files can be downloaded from [Hugging Face](https://huggingface.co/Miwa-Keita/zenz-v3-small-gguf).
* `inferenceLimit`: Specify the upper limit of inference iterations. Usually `1` is sufficient, but you can use a value around `5` for higher precision conversion at the cost of speed.

#### `.coreML(inferenceLimit:versionDependentMode:)` - For ZenzaiCoreML (iOS 18+, macOS 15+)

* No `weight` path needed: CoreML automatically uses the model bundled with the app.
* `inferenceLimit`: Specify the upper limit of inference iterations. Usually `1` is sufficient, but you can use a value around `5` for higher precision conversion at the cost of speed.

## Trait Selection

To use Zenzai, you need to configure Swift Package Traits. For details, see [README](../README.en.md#using-zenzai).

### Zenzai (llama.cpp + GPU)
General-purpose fast inference using GPU (Metal/CUDA).

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["Zenzai"])
```

### ZenzaiCoreML (CoreML + Stateful)
Stateful model available on iOS 18+, macOS 15+. CPU/GPU optimized inference.

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["ZenzaiCoreML"])
```

### ZenzaiCPU (llama.cpp + CPU only)
For environments without GPU or for debugging.

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["ZenzaiCPU"])
```

## Requirements

### llama.cpp-based (Zenzai / ZenzaiCPU Trait)
* macOS environment with M1 or higher specs is recommended. Uses GPU.
* Requires approximately 150MB of memory depending on model size
* Also works on Linux/Windows environments using CUDA.

### CoreML-based (ZenzaiCoreML Trait)
* Requires iOS 18+, macOS 15+
* Uses Stateful models and runs fast on CPU/GPU
* Enables efficient inference by leveraging KV caching
* Leverages Swift Concurrency for async execution without blocking the UI thread
* For more information about Stateful models, see [Apple's official documentation](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)

## How It Works
The clearest explanation can be found in [Zenn Blog (Japanese)](https://zenn.dev/azookey/articles/ea15bacf81521e).

## Terminology
* **Zenzai**: Neural Kana-Kanji conversion system
* **zenz-v1**: First generation of the "zenz" Kana-Kanji conversion model that can be used with Zenzai. Specialized for Kana-Kanji conversion tasks in the format `\uEE00<input_katakana>\uEE01<output></s>`.
* **zenz-v2**: Second generation of the "zenz" Kana-Kanji conversion model. In addition to first generation features, adds the ability to read left context in the format `\uEE00<input_katakana>\uEE02<context>\uEE01<output></s>`.
* **zenz-v3**: Third generation of the "zenz" Kana-Kanji conversion model. Unlike the second generation, recommends a format with context prefixed like `\uEE02<context>\uEE00<input_katakana>\uEE01<output></s>`. Also natively trained to consider profile information entered after `\uEE03`. Experimentally can also consider `\uEE04`+topic, `\uEE05`+style, `\uEE06`+settings.
