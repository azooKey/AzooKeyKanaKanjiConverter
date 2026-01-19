## Zenz / CoreML Availability Guidelines

**English** | [日本語](./ZenzAvailability.md) | [한국어](./ZenzAvailability.ko.md)

AzooKey's Zenz-related code needs to run on multiple platforms.
By following the rules below, you can maintain code quality without scattered `#if` guards and `@available` checks.

1. **Always expose common logic**
   Features used outside of CoreML, such as `PrefixConstraint`, lattice construction, and candidate review, should not be hidden behind `#if ZenzaiCoreML` / `@available`. Files like `FullInputProcessingWithPrefixConstraint.swift` and `zenzai.swift` should always be included in the build.

2. **Guard only CoreML-specific entry points**
   Apply `#if ZenzaiCoreML && canImport(CoreML)` + `@available(iOS 18, macOS 15, *)` only to parts that actually require the CoreML runtime, such as the CoreML backend, `ZenzContext+CoreML`, and `ZenzCoreMLService`. The calling side should use a single entry point like `coreMLService?.convert(...)`.

3. **Encapsulate runtime checks in services**
   The `KanaKanjiConverter` main body should not be aware of CoreML availability. `ZenzCoreMLService` handles `#available` checks and model cache management. On other platforms, the service will be `nil`, allowing the existing processing path to work as is.

4. **Update this document when adding new code**
   If there are changes to CoreML-specific files or availability rules, always update this document to share the intent.
