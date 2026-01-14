## Zenz / CoreML 가용성 가이드라인

[English](./ZenzAvailability.en.md) | [日本語](./ZenzAvailability.md) | **한국어**

AzooKey의 Zenz 관련 코드는 여러 플랫폼에서 동작해야 합니다.
아래 규칙을 따르면 `#if` 가드나 `@available` 검사가 흩어지지 않고 유지보수성을 유지할 수 있습니다.

1. **공통 로직은 항상 공개하기**
   `PrefixConstraint`나 래티스 구축, 후보 검토 등 CoreML 외에서도 사용하는 기능은 `#if ZenzaiCoreML` / `@available`로 숨기지 않습니다. `FullInputProcessingWithPrefixConstraint.swift`나 `zenzai.swift`는 항상 빌드 대상에 포함되어야 합니다.

2. **CoreML 전용 진입점만 가드하기**
   CoreML 백엔드, `ZenzContext+CoreML`, `ZenzCoreMLService` 등 실제로 CoreML 런타임이 필요한 부분에만 `#if ZenzaiCoreML && canImport(CoreML)` + `@available(iOS 18, macOS 15, *)`를 적용합니다. 호출하는 쪽에서는 `coreMLService?.convert(...)`처럼 단일 진입점을 통해 사용합니다.

3. **런타임 판정은 서비스에 캡슐화하기**
   `KanaKanjiConverter` 본체는 CoreML 유무를 의식하지 않고, `ZenzCoreMLService`가 `#available` 판정과 모델 캐시 관리를 담당합니다. 다른 플랫폼에서는 서비스가 `nil`이 되어 기존 처리 경로가 그대로 사용됩니다.

4. **새 코드를 추가하면 이 문서를 업데이트하기**
   CoreML 전용 파일이나 가용성 규칙에 변경사항이 있으면 반드시 이 문서를 업데이트하여 의도를 공유합니다.
