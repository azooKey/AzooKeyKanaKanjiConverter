#if ZenzaiCoreML && canImport(CoreML)

import Foundation

extension KanaKanjiConverter {
    @available(iOS 18, macOS 15, *)
    actor ZenzCoreMLService {
        unowned let owner: KanaKanjiConverter
        private var zenz: Zenz?

        init(owner: KanaKanjiConverter) {
            self.owner = owner
        }

        func stopComposition() async {
            if let zenz {
                await zenz.endSession()
            }
            self.zenz = nil
        }

        private func getOrLoadModel(modelURL: URL) async -> Zenz? {
            if let cached = self.zenz, cached.resourceURL == modelURL {
                self.owner.updateZenzStatus("load \(modelURL.absoluteString)")
                return cached
            }
            do {
                let model = try await Zenz(resourceURL: modelURL)
                self.zenz = model
                self.owner.updateZenzStatus("load \(modelURL.absoluteString)")
                return model
            } catch {
                self.owner.updateZenzStatus("load \(modelURL.absoluteString)    " + error.localizedDescription)
                return nil
            }
        }

        func prepareModelIfNeeded(modelURL: URL) async -> Bool {
            await self.getOrLoadModel(modelURL: modelURL) != nil
        }

        func evaluate(
            modelURL: URL,
            request: ZenzEvaluationRequest,
            personalization: ZenzPersonalizationHandle?
        ) async -> ZenzCandidateEvaluationResult {
            guard let zenz = await self.getOrLoadModel(modelURL: modelURL) else {
                return .error
            }
            return await zenz.candidateEvaluate(
                request,
                personalizationMode: personalization?.tuple
            )
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
