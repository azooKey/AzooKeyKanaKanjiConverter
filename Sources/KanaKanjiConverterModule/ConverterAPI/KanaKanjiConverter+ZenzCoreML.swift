#if ZenzaiCoreML && canImport(CoreML)

import Foundation

extension KanaKanjiConverter {
    @available(iOS 18, macOS 15, *)
    final class ZenzCoreMLBridge {
        unowned let owner: KanaKanjiConverter
        private var zenz: Zenz?
        private var zenzaiCache: Kana2Kanji.ZenzaiCache?

        init(owner: KanaKanjiConverter) {
            self.owner = owner
        }

        func stopComposition() {
            self.zenz?.endSession()
            self.zenzaiCache = nil
        }

        func getOrLoadModel(modelURL: URL) -> Zenz? {
            if let model = self.zenz, model.resourceURL == modelURL {
                self.owner.zenzStatus = "load \(modelURL.absoluteString)"
                return model
            }
            do {
                let model = try Zenz(resourceURL: modelURL)
                self.zenz = model
                self.owner.zenzStatus = "load \(modelURL.absoluteString)"
                return model
            } catch {
                self.owner.zenzStatus = "load \(modelURL.absoluteString)    " + error.localizedDescription
                return nil
            }
        }

        func predictNextCharacters(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
            guard options.zenzaiMode.versionDependentMode.version == .v2 else {
                print("next character prediction requires zenz-v2 models, not zenz-v1 nor zenz-v3 and later")
                return []
            }
            guard let zenz = self.getOrLoadModel(modelURL: options.zenzaiMode.weightURL) else {
                print("zenz-v2 model unavailable")
                return []
            }
            return zenz.predictNextCharacter(leftSideContext: leftSideContext, count: count)
        }

        func convertIfPossible(
            inputData: ComposingText,
            N_best: Int,
            zenzaiMode: ConvertRequestOptions.ZenzaiMode,
            needTypoCorrection: Bool
        ) -> (result: LatticeNode, lattice: Lattice)? {
            _ = needTypoCorrection
            guard zenzaiMode.enabled else {
                return nil
            }
            guard let model = self.getOrLoadModel(modelURL: zenzaiMode.weightURL) else {
                return nil
            }
            let (result, nodes, cache) = self.owner.converter.all_zenzai(
                inputData,
                zenz: model,
                zenzaiCache: self.zenzaiCache,
                inferenceLimit: zenzaiMode.inferenceLimit,
                requestRichCandidates: zenzaiMode.requestRichCandidates,
                personalizationMode: self.owner.getZenzaiPersonalization(mode: zenzaiMode.personalizationMode),
                versionDependentConfig: zenzaiMode.versionDependentMode,
                dicdataStoreState: self.owner.dicdataStoreState
            )
            self.zenzaiCache = cache
            self.owner.previousInputData = inputData
            return (result, nodes)
        }
    }
}

#endif
