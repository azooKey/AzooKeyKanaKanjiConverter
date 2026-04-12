import Dispatch
package import Foundation

fileprivate final class KanaKanjiConverterBlockingAsyncResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func store(_ value: T) {
        self.lock.lock()
        self.value = value
        self.lock.unlock()
    }

    func load() -> T? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

extension KanaKanjiConverter {
    func blockingAsync<T: Sendable>(_ operation: @Sendable @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = KanaKanjiConverterBlockingAsyncResultBox<T>()
        Task.detached {
            resultBox.store(await operation())
            semaphore.signal()
        }
        semaphore.wait()
        return resultBox.load()!
    }
}

#if ZenzaiCoreML && canImport(CoreML)
extension KanaKanjiConverter {
    @available(iOS 18, macOS 15, *)
    func resolvedCoreMLService() -> ZenzCoreMLService {
        if let service = self.coreMLServiceStorage as? ZenzCoreMLService {
            return service
        }
        let service = ZenzCoreMLService(owner: self)
        self.coreMLServiceStorage = service
        return service
    }

    func stopZenzBackendComposition() {
        if #available(iOS 18, macOS 15, *), let service = self.coreMLServiceStorage as? ZenzCoreMLService {
            self.blockingAsync {
                await service.stopComposition()
            }
            self.coreMLServiceStorage = nil
        }
        self.zenzaiCoreMLCache = nil
    }

    @available(iOS 18, macOS 15, *)
    package func getModel(modelURL: URL) -> Zenz? {
        self.blockingAsync {
            await self.resolvedCoreMLService().getOrLoadModel(modelURL: modelURL)
        }
    }

    public func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        guard #available(iOS 18, macOS 15, *) else {
            print("zenz-v2 model unavailable")
            return []
        }
        return self.blockingAsync {
            await self.resolvedCoreMLService().predictNextCharacters(leftSideContext: leftSideContext, count: count, options: options)
        }
    }
}
#elseif Zenzai
extension KanaKanjiConverter {
    func stopZenzBackendComposition() {
        self.zenzaiModel = nil
    }

    package func getModel(modelURL: URL) -> Zenz? {
        if let cached = self.zenzaiModel, cached.resourceURL == modelURL {
            self.updateZenzStatus("load \(modelURL.absoluteString)")
            return cached
        }
        let model = self.blockingAsync {
            try? await Zenz(resourceURL: modelURL)
        }
        if let model {
            self.updateZenzStatus("load \(modelURL.absoluteString)")
            self.zenzaiModel = model
            return model
        } else {
            self.updateZenzStatus("zenz model unavailable")
            return nil
        }
    }

    public func predictNextCharacterAsync(leftSideContext: String, count: Int, options: ConvertRequestOptions) async -> [(character: Character, value: Float)] {
        guard options.zenzaiMode.versionDependentMode.version == .v2 else {
            debug("next character prediction requires zenz-v2 models, not zenz-v1 nor zenz-v3 and later")
            return []
        }
        guard let zenz = await self.getModel(modelURL: options.zenzaiMode.weightURL) else {
            debug("zenz-v2 model unavailable")
            return []
        }
        return await zenz.predictNextCharacter(leftSideContext: leftSideContext, count: count)
    }

    @available(*, deprecated, message: "Use async version 'predictNextCharacterAsync' instead to avoid blocking the calling thread")
    nonisolated public func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        let converter = self
        return self.blockingAsync {
            await converter.predictNextCharacterAsync(leftSideContext: leftSideContext, count: count, options: options)
        }
    }
}
#else
extension KanaKanjiConverter {
    func stopZenzBackendComposition() {}

    package func getModel(modelURL: URL) -> Zenz? {
        self.updateZenzStatus("zenz-v2 model unavailable on this platform")
        return nil
    }

    public func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        print("zenz-v2 model unavailable")
        return []
    }
}
#endif
