#if ZenzaiCoreML && canImport(CoreML)

import EfficientNGram
import Foundation

@usableFromInline
struct ZenzPrefixConstraintSnapshot: Sendable {
    @usableFromInline var bytes: [UInt8]
    @usableFromInline var hasEOS: Bool
    @usableFromInline var ignoreMemoryAndUserDictionary: Bool

    @inlinable
    init(_ constraint: Kana2Kanji.PrefixConstraint) {
        self.bytes = constraint.constraint
        self.hasEOS = constraint.hasEOS
        self.ignoreMemoryAndUserDictionary = constraint.ignoreMemoryAndUserDictionary
    }
}

@usableFromInline
struct ZenzCandidateSnapshot: Sendable {
    @usableFromInline var text: String
    @usableFromInline var value: PValue
    @usableFromInline var metadataFlags: UInt8
    @usableFromInline var clauses: [ClauseSnapshot]

    @inlinable
    init(candidate: Candidate) {
        self.text = candidate.text
        self.value = candidate.value
        var flags: UInt8 = 0
        if candidate.type == .learning {
            flags |= 0b0000_0001
        }
        self.metadataFlags = flags
        self.clauses = candidate.data.map { ClauseSnapshot(element: $0) }
    }

    @usableFromInline
    struct ClauseSnapshot: Sendable {
        @usableFromInline var ruby: String
        @usableFromInline var word: String
        @usableFromInline var isLearned: Bool

        @inlinable
        init(element: DicdataElement) {
            self.ruby = element.ruby
            self.word = element.word
            self.isLearned = element.metadata.contains(.isLearned)
        }
    }
}

@usableFromInline
struct ZenzCoreMLExecutionConfig: Sendable {
    @usableFromInline var inferenceLimit: Int
    @usableFromInline var requestRichCandidates: Bool
    @usableFromInline var versionConfig: ConvertRequestOptions.ZenzaiVersionDependentMode

    @inlinable
    init(mode: ConvertRequestOptions.ZenzaiMode) {
        self.inferenceLimit = mode.inferenceLimit
        self.requestRichCandidates = mode.requestRichCandidates
        self.versionConfig = mode.versionDependentMode
    }
}

@usableFromInline
struct ZenzPersonalizationVector: Sendable {
    @usableFromInline var alpha: Float
    @usableFromInline var baseLogProb: [Float]
    @usableFromInline var personalLogProb: [Float]
}

@usableFromInline
struct ZenzPersonalizationHandle: @unchecked Sendable {
    @usableFromInline
    let mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode
    @usableFromInline
    let base: EfficientNGram
    @usableFromInline
    let personal: EfficientNGram

    @inlinable
    var tuple: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram) {
        (self.mode, self.base, self.personal)
    }
}

#endif
