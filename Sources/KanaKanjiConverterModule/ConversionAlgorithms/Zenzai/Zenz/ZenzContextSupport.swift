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
    func reset_context() throws
    func evaluate_candidate(
        input: String,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> ZenzCandidateEvaluationResult
    func predict_next_character(leftSideContext: String, count: Int) -> [(character: Character, value: Float)]
    func pure_greedy_decoding(leftSideContext: String, maxCount: Int) -> String
}
