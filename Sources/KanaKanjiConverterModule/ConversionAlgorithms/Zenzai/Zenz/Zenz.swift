import EfficientNGram
package import Foundation
import SwiftUtils

#if ZenzaiCoreML && canImport(CoreML)
@available(iOS 18, macOS 15, *)
#endif
package final class Zenz: @unchecked Sendable {
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
        _ request: ZenzEvaluationRequest,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?
    ) async -> ZenzCandidateEvaluationResult {
        guard let zenzContext else {
            return .error
        }
        var request = request
        request.convertTarget = request.convertTarget.toKatakana()
        return await zenzContext.evaluate_candidate(request: request, personalizationMode: personalizationMode)
    }

    func predictNextCharacter(leftSideContext: String, count: Int) async -> [(character: Character, value: Float)] {
        guard let zenzContext else {
            return []
        }
        return await zenzContext.predict_next_character(leftSideContext: leftSideContext, count: count)
    }

    package func pureGreedyDecoding(pureInput: String, maxCount: Int = .max) async -> String {
        await (self.zenzContext?.pure_greedy_decoding(leftSideContext: pureInput, maxCount: maxCount) ?? "")
    }
}
