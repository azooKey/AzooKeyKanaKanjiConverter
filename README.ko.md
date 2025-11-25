# AzooKeyKanaKanjiConverter

[日本語](README.md) | [English](README.en.md) | **한국어**

AzooKeyKanaKanjiConverter는 [azooKey](https://github.com/ensan-hcl/azooKey)를 위해 개발된 가나-한자 변환 엔진입니다. 몇 줄의 코드만으로 iOS / macOS / visionOS 애플리케이션에 가나-한자 변환 기능을 통합할 수 있습니다.

또한 AzooKeyKanaKanjiConverter는 신경망 기반 가나-한자 변환 시스템 "Zenzai"를 활용한 고정밀도 변환을 지원합니다.

## 동작 환경
iOS 16+, macOS 13+, visionOS 1+, Ubuntu 22.04+에서 동작을 확인했습니다. Swift 6.1 이상이 필요합니다.

### Swift Concurrency 지원
AzooKeyKanaKanjiConverter는 Swift 6 strict concurrency checking을 완전히 지원하며 다음 기능을 제공합니다:

- **MainActor 격리**: Darwin(iOS/macOS/visionOS)에서 `KanaKanjiConverter`가 `@MainActor`로 동작하여 UI 스레드 안전성 보장
- **비동기 API**: 모든 주요 API에 비동기 버전을 제공하여 UI 스레드 블로킹 방지
- **크로스 플랫폼**: Linux 환경에서도 동등한 기능 제공 (MainActor 격리 없음)

> [!NOTE]
> Linux 플랫폼에서는 MainActor 격리가 적용되지 않으므로, 스레드 안전성 보장 메커니즘이 Darwin과 다릅니다.

개발 가이드는 [개발 가이드](Docs/development_guide.md)를 참조하세요.
학습 데이터 저장 위치 및 초기화 방법은 [Docs/learning_data.md](Docs/learning_data.md)를 참조하세요.

## KanaKanjiConverterModule
가나-한자 변환을 담당하는 모듈입니다.

### 설정
* Xcode 프로젝트의 경우, Xcode에서 Add Package를 사용하여 추가하세요.

* Swift Package의 경우, Package.swift의 `Package` 인자에 다음 `dependencies`를 추가하세요:
  ```swift
  dependencies: [
      .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"))
  ],
  ```
  타겟의 `dependencies`에도 추가하세요:
  ```swift
  .target(
      name: "MyPackage",
      dependencies: [
          .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
      ],
  ),
  ```

> [!IMPORTANT]
> AzooKeyKanaKanjiConverter는 버전 1.0 릴리스까지 개발 버전으로 운영되므로, 마이너 버전 변경 시 호환성이 깨질 수 있습니다. 버전을 지정할 때는 `.upToNextMinor(from: "0.8.0")`처럼 마이너 버전이 올라가지 않도록 지정하는 것을 권장합니다.


### 사용법

#### Async/Await API (권장)
iOS 16+에서는 비동기 API를 사용하여 UI 스레드 블로킹을 방지합니다. 키보드 앱 등 UI 응답성이 중요한 경우 권장됩니다.

```swift
// 기본 사전이 포함된 변환 모듈 임포트
import KanaKanjiConverterModuleWithDefaultDictionary

// 변환기 초기화 (기본 사전 사용)
let converter = KanaKanjiConverter.withDefaultDictionary()

// async 함수 내에서 사용
@MainActor
func convertText() async {
    // 입력 초기화
    var c = ComposingText()
    // 변환할 문장 추가
    c.insertAtCursorPosition("あずーきーはしんじだいのきーぼーどあぷりです", inputStyle: .direct)
    // 변환 옵션을 지정하여 변환 요청 (비동기)
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
    // 첫 번째 결과 출력
    print(results.mainResults.first!.text)  // azooKeyは新時代のキーボードアプリです
}
```

#### 동기 API (레거시)
기존 코드와의 호환성을 위해 동기 API도 계속 사용 가능하지만 비권장입니다.

```swift
// 변환기 초기화 (기본 사전 사용)
let converter = KanaKanjiConverter.withDefaultDictionary()
var c = ComposingText()
c.insertAtCursorPosition("あずーきーはしんじだいのきーぼーどあぷりです", inputStyle: .direct)

// 동기 API (비권장 - UI 스레드를 블로킹할 수 있습니다)
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

`ConvertRequestOptions`는 변환 요청에 필요한 정보를 지정합니다. 자세한 내용은 코드의 문서 주석을 참조하세요.

#### 사용 가능한 Async API 목록
다음 비동기 API를 사용할 수 있습니다:
- `requestCandidatesAsync(_:options:)` - 변환 후보를 비동기로 가져오기
- `stopCompositionAsync()` - 변환 세션을 비동기로 종료
- `resetMemoryAsync()` - 학습 데이터를 비동기로 초기화
- `predictNextCharacterAsync(leftSideContext:count:options:)` - 다음 문자를 비동기로 예측 (zenz-v2 모델 필요, Zenzai 또는 ZenzaiCoreML trait에서 사용 가능)

> [!NOTE]
-> Swift Concurrency 마이그레이션 문서는 이 브랜치에서는 포함하지 않습니다.


### `ConvertRequestOptions`
`ConvertRequestOptions`는 변환 요청에 필요한 설정값입니다. 예를 들어 다음과 같이 설정합니다:

```swift
let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!
let options = ConvertRequestOptions(
    // 일본어 예측 변환
    requireJapanesePrediction: true,
    // 영어 예측 변환
    requireEnglishPrediction: false,
    // 입력 언어
    keyboardLanguage: .ja_JP,
    // 학습 타입
    learningType: .nothing,
    // 학습 데이터를 저장할 디렉토리 URL (문서 폴더 지정)
    memoryDirectoryURL: documents,
    // 사용자 사전 데이터가 있는 디렉토리 URL (문서 폴더 지정)
    sharedContainerURL: documents,
    // 메타데이터
    metadata: .init(versionString: "Your App Version X"),
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders
)
```

열 때 저장 처리가 중단된 `.pause` 파일이 남아있는 경우, 변환기가 자동으로 복구를 시도하고 파일을 삭제합니다.

### `ComposingText`
`ComposingText`는 입력 관리를 하면서 변환을 요청하기 위한 API입니다. 로마자 입력 등을 적절하게 처리하기 위해 사용할 수 있습니다. 자세한 내용은 [문서](./Docs/composing_text.md)를 참조하세요.

### Zenzai 사용하기
신경망 기반 가나-한자 변환 시스템 "Zenzai"를 사용하려면 추가로 [Swift Package Traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md) 설정이 필요합니다. AzooKeyKanaKanjiConverter는 3가지 Trait를 지원합니다. 환경에 맞게 하나를 추가하세요.

```swift
dependencies: [
    // GPU (Metal/CUDA 등) 사용 - llama.cpp 기반
    .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["Zenzai"]),

    // CoreML 사용 (iOS 18+, macOS 15+) - Stateful 모델, CPU/GPU 최적화
    // .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["ZenzaiCoreML"]),

    // CPU만 사용 (오프로딩 비활성화)
    // .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0"), traits: ["ZenzaiCPU"]),
],
```

#### Trait 선택 가이드

| Trait | 백엔드 | 지원 OS | 가속기 | 권장 용도 |
|-------|--------|---------|--------|----------|
| `Zenzai` | llama.cpp | iOS 16+, macOS 13+, Linux | Metal/CUDA | 범용 GPU 가속 |
| `ZenzaiCoreML` | CoreML (Stateful) | iOS 18+, macOS 15+ | CPU/GPU | Apple 기기에서 CPU/GPU 최적화 추론 |
| `ZenzaiCPU` | llama.cpp (CPU only) | iOS 16+, macOS 13+, Linux | 없음 | GPU를 사용할 수 없는 환경, 디버깅용 |

> [!NOTE]
-> `ZenzaiCoreML`은 Swift Concurrency를 활용한 비동기 실행을 통해 UI 스레드를 블로킹하지 않으면서 Stateful 모델에서 고속 추론을 실현합니다.

`ConvertRequestOptions`의 `zenzaiMode`를 지정합니다. 자세한 인자 정보는 [문서](./Docs/zenzai.ko.md)를 참조하세요.

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

### 사전 데이터

AzooKeyKanaKanjiConverter의 기본 사전으로 [azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage)가 서브모듈로 지정되어 있습니다. 과거 버전의 사전 데이터는 [Google Drive](https://drive.google.com/drive/folders/1Kh7fgMFIzkpg7YwP3GhWTxFkXI-yzT9E?usp=sharing)에서도 다운로드할 수 있습니다.

또한 다음 형식이라면 자체 준비한 사전 데이터를 사용할 수도 있습니다. 커스텀 사전 데이터 지원은 제한적이므로 소스 코드를 확인 후 사용하세요.

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

기본 사전 이외의 사전 데이터를 사용하는 경우, 타겟의 `dependencies`에 다음을 추가하세요:
```swift
.target(
  name: "MyPackage",
  dependencies: [
      .product(name: "KanaKanjiConverterModule", package: "AzooKeyKanaKanjiConverter")
  ],
),
```

사용 시 사전 데이터의 디렉토리를 명시적으로 지정해야 합니다 (옵션이 아닌 변환기 초기화 시 지정).
```swift
// 기본 사전을 포함하지 않는 변환 모듈 지정
import KanaKanjiConverterModule

let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!
// 커스텀 사전 디렉토리를 지정하여 변환기 초기화
let dictionaryURL = Bundle.main.bundleURL.appending(path: "Dictionary", directoryHint: .isDirectory)
let converter = KanaKanjiConverter(dictionaryURL: dictionaryURL, preloadDictionary: true)

// 변환 요청 시 옵션 준비
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
`dictionaryResourceURL`은 `ConvertRequestOptions`에서 제거되었습니다. 기본 사전을 사용하는 경우 `KanaKanjiConverterModuleWithDefaultDictionary`를, 커스텀 사전을 사용하는 경우 `KanaKanjiConverterModule`을 사용하고 변환기 초기화 시 사전 디렉토리를 지정하세요.

## SwiftUtils
Swift 일반에 사용할 수 있는 유틸리티 모듈입니다.
