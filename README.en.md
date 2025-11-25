# AzooKeyKanaKanjiConverter

[日本語](README.md) | **English** | [한국어](README.ko.md)

AzooKeyKanaKanjiConverter is a Kana-Kanji conversion engine developed for [azooKey](https://github.com/ensan-hcl/azooKey). You can integrate Kana-Kanji conversion into your iOS / macOS / visionOS applications with just a few lines of code.

AzooKeyKanaKanjiConverter also supports high-precision conversion using the neural Kana-Kanji conversion system "Zenzai".

## Requirements
Tested on iOS 16+, macOS 13+, visionOS 1+, and Ubuntu 22.04+. Requires Swift 6.1 or later.

For development guides, see [Development Guide](Docs/development_guide.md).
For information on learning data storage and reset methods, see [Docs/learning_data.md](Docs/learning_data.md).

## KanaKanjiConverterModule
This module handles Kana-Kanji conversion.

### Setup
* For Xcode projects, add the package using Add Package in Xcode.

* For Swift Packages, add the following to the `dependencies` in your Package.swift:
  ```swift
  dependencies: [
      .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"))
  ],
  ```
  Also add it to your target's `dependencies`:
  ```swift
  .target(
      name: "MyPackage",
      dependencies: [
          .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
      ],
  ),
  ```

> [!IMPORTANT]
> AzooKeyKanaKanjiConverter will operate as a development version until version 1.0 release, so breaking changes may occur with minor version updates. When specifying versions, we recommend using `.upToNextMinor(from: "0.8.0")` to prevent minor version updates.


### Usage

#### Async/Await API (Recommended)
On iOS 16+, using async APIs prevents UI thread blocking. Recommended for keyboard apps and other UI-responsive applications.

```swift
// Import the converter module with default dictionary
import KanaKanjiConverterModuleWithDefaultDictionary

// Initialize the converter (using default dictionary)
let converter = KanaKanjiConverter.withDefaultDictionary()

// Use within an async function
@MainActor
func convertText() async {
    // Initialize input
    var c = ComposingText()
    // Add text to convert
    c.insertAtCursorPosition("あずーきーはしんじだいのきーぼーどあぷりです", inputStyle: .direct)
    // Request conversion with options (async)
    let results = await converter.requestCandidatesAsync(c, options: .init(
        N_best: 10,
        requireJapanesePrediction: true,
        requireEnglishPrediction: false,
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
    // Display the first result
    print(results.mainResults.first!.text)  // azooKeyは新時代のキーボードアプリです
}
```

#### Synchronous API (Legacy)
For backward compatibility, synchronous APIs are still available but deprecated.

```swift
// Initialize the converter (using default dictionary)
let converter = KanaKanjiConverter.withDefaultDictionary()
var c = ComposingText()
c.insertAtCursorPosition("あずーきーはしんじだいのきーぼーどあぷりです", inputStyle: .direct)

// Synchronous API (deprecated - may block UI thread)
let results = converter.requestCandidates(c, options: .init(
    N_best: 10,
    requireJapanesePrediction: true,
    requireEnglishPrediction: false,
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
print(results.mainResults.first!.text)
```

`ConvertRequestOptions` specifies the information required for conversion requests. See the documentation comments in the code for details.

#### Available Async APIs
The following async APIs are available:
- `requestCandidatesAsync(_:options:)` - Get conversion candidates asynchronously
- `stopCompositionAsync()` - End conversion session asynchronously
- `resetMemoryAsync()` - Reset learning data asynchronously
- `predictNextCharacterAsync(leftSideContext:count:options:)` - Predict next character asynchronously (requires zenz-v2 model, available with Zenzai or ZenzaiCoreML trait)


### `ConvertRequestOptions`
`ConvertRequestOptions` contains the settings required for conversion requests. Configure as follows:

```swift
let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!
let options = ConvertRequestOptions(
    // Japanese prediction
    requireJapanesePrediction: true,
    // English prediction
    requireEnglishPrediction: false,
    // Input language
    keyboardLanguage: .ja_JP,
    // Learning type
    learningType: .nothing,
    // Directory URL for saving learning data (specify documents folder)
    memoryDirectoryURL: documents,
    // Directory URL for user dictionary data (specify documents folder)
    sharedContainerURL: documents,
    // Metadata
    metadata: .init(versionString: "Your App Version X"),
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders
)
```

If interrupted `.pause` files remain when opening, the converter will automatically attempt recovery and delete the files.

### `ComposingText`
`ComposingText` is an API for managing input while requesting conversion. It can be used to properly handle romaji input and more. For details, see [documentation](./Docs/composing_text.md).

### Using Zenzai
To use the neural Kana-Kanji conversion system "Zenzai", you need to configure [Swift Package Traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md). AzooKeyKanaKanjiConverter supports three Traits. Add one according to your environment.

```swift
dependencies: [
    // For GPU (Metal/CUDA etc.) - llama.cpp based
    .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["Zenzai"]),

    // For CoreML (iOS 18+, macOS 15+) - Stateful model with CPU/GPU optimization
    // .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["ZenzaiCoreML"]),

    // For CPU only (no offloading)
    // .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["ZenzaiCPU"]),
],
```

#### Trait Selection Guide

| Trait | Backend | Supported OS | Accelerator | Recommended Use |
|-------|---------|--------------|-------------|-----------------|
| `Zenzai` | llama.cpp | iOS 16+, macOS 13+, Linux | Metal/CUDA | General purpose GPU acceleration |
| `ZenzaiCoreML` | CoreML (Stateful) | iOS 18+, macOS 15+ | CPU/GPU | CPU/GPU optimized inference on Apple devices |
| `ZenzaiCPU` | llama.cpp (CPU only) | iOS 16+, macOS 13+, Linux | None | Environments without GPU, debugging |

> [!NOTE]
 Specify `zenzaiMode` in `ConvertRequestOptions`. For detailed argument information, see [documentation](./Docs/zenzai.en.md).

```swift
let options = ConvertRequestOptions(
    // ...
    requireJapanesePrediction: true,
    requireEnglishPrediction: false,
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

### Dictionary Data

[azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage) is specified as a submodule for AzooKeyKanaKanjiConverter's default dictionary. Past versions of dictionary data can also be downloaded from [Google Drive](https://drive.google.com/drive/folders/1Kh7fgMFIzkpg7YwP3GhWTxFkXI-yzT9E?usp=sharing).

You can also use your own dictionary data in the following format. Custom dictionary data support is limited, so please check the source code before use.

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

To use dictionary data other than the default, add the following to your target's `dependencies`:
```swift
.target(
  name: "MyPackage",
  dependencies: [
      .product(name: "KanaKanjiConverterModule", package: "AzooKeyKanaKanjiConverter")
  ],
),
```

When using, you must explicitly specify the dictionary data directory (not in options, but when initializing the converter).
```swift
// Import converter module without default dictionary
import KanaKanjiConverterModule

let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!
// Initialize converter specifying custom dictionary directory
let dictionaryURL = Bundle.main.bundleURL.appending(path: "Dictionary", directoryHint: .isDirectory)
let converter = KanaKanjiConverter(dictionaryURL: dictionaryURL, preloadDictionary: true)

// Prepare options for conversion request
let options = ConvertRequestOptions(
    requireJapanesePrediction: true,
    requireEnglishPrediction: false,
    keyboardLanguage: .ja_JP,
    learningType: .nothing,
    memoryDirectoryURL: documents,
    sharedContainerURL: documents,
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
    metadata: .init(versionString: "Your App Version X")
)
```
`dictionaryResourceURL` has been removed from `ConvertRequestOptions`. Use `KanaKanjiConverterModuleWithDefaultDictionary` for the default dictionary, or use `KanaKanjiConverterModule` for custom dictionaries and specify the dictionary directory when initializing the converter.

## SwiftUtils
A module of utilities available for general Swift use.
