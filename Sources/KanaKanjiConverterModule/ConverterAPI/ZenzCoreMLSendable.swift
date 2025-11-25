#if ZenzaiCoreML && canImport(CoreML)

import EfficientNGram
import Foundation

struct ZenzPrefixConstraintSnapshot: Sendable {
    var bytes: [UInt8]
    var hasEOS: Bool
    var ignoreMemoryAndUserDictionary: Bool

    init(_ constraint: Kana2Kanji.PrefixConstraint) {
        self.bytes = constraint.constraint
        self.hasEOS = constraint.hasEOS
        self.ignoreMemoryAndUserDictionary = constraint.ignoreMemoryAndUserDictionary
    }
}

struct ZenzCandidateSnapshot: Sendable {
    var text: String
    var value: PValue
    var isLearningTarget: Bool
    var clauses: [ClauseSnapshot]

    init(candidate: Candidate) {
        self.text = candidate.text
        self.value = candidate.value
        self.isLearningTarget = candidate.isLearningTarget
        self.clauses = candidate.data.map { ClauseSnapshot(element: $0) }
    }

    struct ClauseSnapshot: Sendable {
        var ruby: String
        var word: String
        var isLearned: Bool

        init(element: DicdataElement) {
            self.ruby = element.ruby
            self.word = element.word
            self.isLearned = element.metadata.contains(.isLearned)
        }
    }
}

struct ZenzCoreMLExecutionConfig: Sendable {
    var inferenceLimit: Int
    var requestRichCandidates: Bool
    var versionConfig: ConvertRequestOptions.ZenzaiVersionDependentMode

    init(mode: ConvertRequestOptions.ZenzaiMode) {
        self.inferenceLimit = mode.inferenceLimit
        self.requestRichCandidates = mode.requestRichCandidates
        self.versionConfig = mode.versionDependentMode
    }
}

struct ZenzPersonalizationVector: Sendable {
    var alpha: Float
    var baseLogProb: [Float]
    var personalLogProb: [Float]
}

struct ZenzPersonalizationHandle: @unchecked Sendable {
    let mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode
    let base: EfficientNGram
    let personal: EfficientNGram
}

#endif
