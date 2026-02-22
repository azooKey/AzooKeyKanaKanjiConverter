import EfficientNGram
package import Foundation
import SwiftUtils

package final class Zenz {
    package var resourceURL: URL
    private var zenzContext: ZenzContext?
    init(resourceURL: URL) throws {
        self.resourceURL = resourceURL
        do {
            #if canImport(Darwin)
            if #available(iOS 16, macOS 13, *) {
                self.zenzContext = try ZenzContext.createContext(path: resourceURL.path(percentEncoded: false))
            } else {
                // this is not percent-encoded
                self.zenzContext = try ZenzContext.createContext(path: resourceURL.path)
            }
            #else
            // this is not percent-encoded
            self.zenzContext = try ZenzContext.createContext(path: resourceURL.path)
            #endif
            debug("Loaded model \(resourceURL.lastPathComponent)")
        } catch {
            throw error
        }
    }

    package func endSession() {
        try? self.zenzContext?.reset_context()
    }

    func candidateEvaluate(
        convertTarget: String,
        candidates: [Candidate],
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> ZenzContext.CandidateEvaluationResult {
        guard let zenzContext else {
            return .error
        }
        for candidate in candidates {
            return zenzContext.evaluate_candidate(
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

    func predictNextInputText(
        leftSideContext: String,
        composingText: String,
        count: Int,
        minLength: Int = 1,
        maxEntropy: Float?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        possibleNexts: [String] = []
    ) -> String {
        guard let zenzContext else {
            return ""
        }
        return zenzContext.predict_next_input_text(
            leftSideContext: leftSideContext,
            composingText: composingText,
            count: count,
            minLength: minLength,
            maxEntropy: maxEntropy,
            versionDependentConfig: versionDependentConfig,
            possibleNexts: possibleNexts
        )
    }

    package func pureGreedyDecoding(pureInput: String, maxCount: Int = .max) -> String {
        self.zenzContext?.pure_greedy_decoding(leftSideContext: pureInput, maxCount: maxCount) ?? ""
    }
}
