#if ZenzaiCoreML && canImport(CoreML)

import Foundation

extension KanaKanjiConverter {
    @available(iOS 18, macOS 15, *)
    final class ZenzCoreMLService {
        unowned let owner: KanaKanjiConverter
        private let stateLock = NSLock()
        private var zenz: Zenz?

        init(owner: KanaKanjiConverter) {
            self.owner = owner
        }

        private func withStateLock<T>(_ operation: () -> T) -> T {
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            return operation()
        }

        func stopComposition() async {
            let zenz = self.withStateLock { () -> Zenz? in
                defer {
                    self.zenz = nil
                }
                return self.zenz
            }
            if let zenz {
                await zenz.endSession()
            }
        }

        func getOrLoadModel(modelURL: URL) async -> Zenz? {
            if let cached = self.withStateLock({ self.zenz?.resourceURL == modelURL ? self.zenz : nil }) {
                self.owner.updateZenzStatus("load \(modelURL.absoluteString)")
                return cached
            }
            do {
                let model = try await Zenz(resourceURL: modelURL)
                self.withStateLock {
                    self.zenz = model
                }
                self.owner.updateZenzStatus("load \(modelURL.absoluteString)")
                return model
            } catch {
                self.owner.updateZenzStatus("load \(modelURL.absoluteString)    " + error.localizedDescription)
                return nil
            }
        }

        func predictNextCharacters(leftSideContext: String, count: Int, options: ConvertRequestOptions) async -> [(character: Character, value: Float)] {
            guard options.zenzaiMode.versionDependentMode.version == .v2 else {
                print("next character prediction requires zenz-v2 models, not zenz-v1 nor zenz-v3 and later")
                return []
            }
            guard let zenz = await self.getOrLoadModel(modelURL: options.zenzaiMode.weightURL) else {
                print("zenz-v2 model unavailable")
                return []
            }
            return await zenz.predictNextCharacter(leftSideContext: leftSideContext, count: count)
        }
    }
}

#endif
