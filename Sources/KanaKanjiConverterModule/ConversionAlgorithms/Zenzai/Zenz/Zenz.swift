import EfficientNGram
package import Foundation
import SwiftUtils

#if ZenzaiCoreML && canImport(CoreML)
@available(iOS 18, macOS 15, *)
#endif
package final class Zenz {
    package var resourceURL: URL
    private var zenzContext: (any ZenzContextProtocol)?
    init(resourceURL: URL) async throws {
        self.resourceURL = resourceURL
        do {
            #if canImport(Darwin)
            #if ZenzaiCoreML
            self.zenzContext = try await ZenzContext.createContext(path: resourceURL.path(percentEncoded: false))
            #else
            if #available(iOS 16, macOS 13, *) {
                self.zenzContext = try await ZenzContext.createContext(path: resourceURL.path(percentEncoded: false))
            } else {
                // this is not percent-encoded
                self.zenzContext = try await ZenzContext.createContext(path: resourceURL.path)
            }
            #endif
            #else
            // this is not percent-encoded
            self.zenzContext = try await ZenzContext.createContext(path: resourceURL.path)
            #endif
            debug("Loaded model \(resourceURL.lastPathComponent)")
        } catch {
            throw error
        }
    }

    package func endSession() async {
        try? await self.zenzContext?.reset_context()
    }

    func candidateEvaluate(
        convertTarget: String,
        candidates: [Candidate],
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) async -> ZenzCandidateEvaluationResult {
        guard let zenzContext else {
            return .error
        }
        for candidate in candidates {
            return await zenzContext.evaluate_candidate(
                input: convertTarget.toKatakana(),
                candidate: candidate,
                requestRichCandidates: requestRichCandidates,
                prefixConstraint: prefixConstraint,
                personalizationMode: personalizationMode,
                versionDependentConfig: versionDependentConfig
            )
        }
        return .error
    }

    func predictNextCharacter(leftSideContext: String, count: Int) async -> [(character: Character, value: Float)] {
        guard let zenzContext else {
            return []
        }
        return await zenzContext.predict_next_character(leftSideContext: leftSideContext, count: count)
    }

    func predictNextInputText(
        leftSideContext: String,
        composingText: String,
        count: Int,
        minLength: Int = 1,
        maxEntropy: Float?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        possibleNexts: [String] = []
    ) -> String {
        #if ZenzaiCoreML && canImport(CoreML)
        return ""
        #else
        guard let zenzContext = self.zenzContext as? ZenzContext else {
            return ""
        }
        return ZenzInputTextGenerator.generate(
            context: zenzContext,
            leftSideContext: leftSideContext,
            composingText: composingText,
            count: count,
            minLength: minLength,
            maxEntropy: maxEntropy,
            versionDependentConfig: versionDependentConfig,
            possibleNexts: possibleNexts
        )
        #endif
    }

    func generateTypoCandidates(
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        experimentalConfig: ExperimentalTypoCorrectionConfig,
        cache: ZenzaiTypoGenerationCache
    ) -> [ZenzaiTypoCandidate] {
        #if ZenzaiCoreML && canImport(CoreML)
        return []
        #else
        guard let zenzContext = self.zenzContext as? ZenzContext else {
            return []
        }
        return ZenzaiTypoCandidateGenerator.generate(
            context: zenzContext,
            leftSideContext: leftSideContext,
            composingText: composingText,
            inputStyle: inputStyle,
            experimentalConfig: experimentalConfig,
            cache: cache
        )
        #endif
    }

package func pureGreedyDecoding(pureInput: String, maxCount: Int = .max) async -> String {
    await (self.zenzContext?.pure_greedy_decoding(leftSideContext: pureInput, maxCount: maxCount) ?? "")
}
}

// CoreML pipeline uses Zenz across async boundaries; treat it as unchecked sendable for bridging.
@available(iOS 18, macOS 15, *)
extension Zenz: @unchecked Sendable {}
