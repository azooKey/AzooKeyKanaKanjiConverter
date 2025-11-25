# Zenzai

신경망 기반 가나-한자 변환 엔진 "Zenzai"를 활성화하면 고정밀도 변환을 제공할 수 있습니다. 사용하려면 변환 옵션의 `zenzaiMode`를 설정합니다.

## 기본 사용법

### Async API (권장)

#### Zenzai (llama.cpp) 사용하기

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
            weight: url,  // gguf 파일 경로 지정
            inferenceLimit: 1,
            versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
        ),
        metadata: .init(versionString: "Your App Version X")
    )

    let results = await converter.requestCandidatesAsync(composingText, options: options)
}
```

#### ZenzaiCoreML 사용하기 (iOS 18+, macOS 15+)

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
        zenzaiMode: .coreML(  // weight 경로 지정 불필요 (번들 모델 사용)
            inferenceLimit: 1,
            versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
        ),
        metadata: .init(versionString: "Your App Version X")
    )

    let results = await converter.requestCandidatesAsync(composingText, options: options)
}
```

### 동기 API (레거시)

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

// 비권장: UI 스레드를 블로킹할 수 있습니다
let results = converter.requestCandidates(composingText, options: options)
```

### 매개변수

#### `.on(weight:inferenceLimit:versionDependentMode:)` - Zenzai (llama.cpp)용

* `weight`: `gguf` 형식의 가중치 파일 경로를 지정합니다. 가중치 파일은 [Hugging Face](https://huggingface.co/Miwa-Keita/zenz-v3-small-gguf)에서 다운로드할 수 있습니다.
* `inferenceLimit`: 추론 반복 횟수의 상한을 지정합니다. 일반적으로 `1`이면 충분하지만, 속도가 느려도 높은 정밀도 변환을 원하는 경우 `5` 정도의 값을 사용할 수 있습니다.

#### `.coreML(inferenceLimit:versionDependentMode:)` - ZenzaiCoreML용 (iOS 18+, macOS 15+)

* `weight` 경로 지정 불필요: CoreML은 앱에 번들로 포함된 모델을 자동으로 사용합니다.
* `inferenceLimit`: 추론 반복 횟수의 상한을 지정합니다. 일반적으로 `1`이면 충분하지만, 속도가 느려도 높은 정밀도 변환을 원하는 경우 `5` 정도의 값을 사용할 수 있습니다.

## Trait 선택

Zenzai를 사용하려면 Swift Package Traits 설정이 필요합니다. 자세한 내용은 [README](../README.ko.md#zenzai-사용하기)를 참조하세요.

### Zenzai (llama.cpp + GPU)
GPU(Metal/CUDA)를 사용한 범용 고속 추론.

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["Zenzai"])
```

### ZenzaiCoreML (CoreML + Stateful)
iOS 18+, macOS 15+에서 사용 가능한 Stateful 모델. CPU/GPU 최적화 추론.

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["ZenzaiCoreML"])
```

### ZenzaiCPU (llama.cpp + CPU only)
GPU를 사용할 수 없는 환경이나 디버깅용.

```swift
.package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
         .upToNextMinor(from: "0.8.0"),
         traits: ["ZenzaiCPU"])
```

## 동작 환경

### llama.cpp 기반 (Zenzai / ZenzaiCPU Trait)
* M1 이상의 스펙을 가진 macOS 환경을 권장합니다. GPU를 사용합니다.
* 모델 크기에 따라 다르지만 현재 약 150MB의 메모리가 필요합니다
* Linux/Windows 환경에서도 CUDA를 사용하여 동작합니다.

### CoreML 기반 (ZenzaiCoreML Trait)
* iOS 18+, macOS 15+ 필요
* Stateful 모델을 사용하며 CPU/GPU에서 고속으로 동작합니다
* KV 캐싱을 활용하여 효율적인 추론을 실현합니다
* Swift Concurrency를 활용한 비동기 실행으로 UI 스레드를 블로킹하지 않습니다
* Stateful 모델의 구조에 대한 자세한 내용은 [Apple 공식 문서](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)를 참조하세요

## 작동 원리
가장 이해하기 쉬운 설명은 [Zenn 블로그 (일본어)](https://zenn.dev/azookey/articles/ea15bacf81521e)를 읽어보시기 바랍니다.

## 용어
* **Zenzai**: 신경망 기반 가나-한자 변환 시스템
* **zenz-v1**: Zenzai에서 사용할 수 있는 가나-한자 변환 모델 "zenz"의 1세대. `\uEE00<input_katakana>\uEE01<output></s>` 형식의 가나-한자 변환 작업에 특화.
* **zenz-v2**: 가나-한자 변환 모델 "zenz"의 2세대. 1세대 기능에 더해 `\uEE00<input_katakana>\uEE02<context>\uEE01<output></s>` 형식으로 왼쪽 문맥을 읽는 기능 추가.
* **zenz-v3**: 가나-한자 변환 모델 "zenz"의 3세대. 2세대와 달리 `\uEE02<context>\uEE00<input_katakana>\uEE01<output></s>`처럼 문맥을 앞에 두는 방식을 권장. 또한 `\uEE03` 뒤에 입력된 프로필 정보를 고려하는 동작이 기본적으로 학습되어 있음. 실험적으로 `\uEE04`+주제, `\uEE05`+스타일, `\uEE06`+설정도 고려할 수 있습니다.
