import EfficientNGram
import Foundation

enum ZenzCandidateEvaluationResult: Sendable, Equatable, Hashable {
    case error
    case pass(score: Float, alternativeConstraints: [AlternativeConstraint])
    case fixRequired(prefixConstraint: [UInt8])
    case wholeResult(String)

    struct AlternativeConstraint: Sendable, Equatable, Hashable {
        var probabilityRatio: Float
        var prefixConstraint: [UInt8]
    }
}

protocol ZenzContextProtocol: AnyObject {
    func reset_context() async throws
    func evaluate_candidate(
        request: ZenzEvaluationRequest,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?
    ) async -> ZenzCandidateEvaluationResult
    func predict_next_character(leftSideContext: String, count: Int) async -> [(character: Character, value: Float)]
    func pure_greedy_decoding(leftSideContext: String, maxCount: Int) async -> String
}
