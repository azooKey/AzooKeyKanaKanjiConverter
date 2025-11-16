import Foundation

struct ZenzPrefixConstraintSnapshot: Sendable {
    var bytes: [UInt8]
    var hasEOS: Bool
    var ignoreMemoryAndUserDictionary: Bool

    init(bytes: [UInt8], hasEOS: Bool, ignoreMemoryAndUserDictionary: Bool) {
        self.bytes = bytes
        self.hasEOS = hasEOS
        self.ignoreMemoryAndUserDictionary = ignoreMemoryAndUserDictionary
    }

    init(_ constraint: Kana2Kanji.PrefixConstraint) {
        self.init(
            bytes: constraint.constraint,
            hasEOS: constraint.hasEOS,
            ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary
        )
    }

    func hasPrefix(_ utf8: ArraySlice<UInt8>) -> Bool {
        self.bytes.starts(with: utf8)
    }

    func hasPrefix(_ string: String) -> Bool {
        self.bytes.starts(with: string.utf8)
    }
}

struct ZenzCandidateSnapshot: Sendable {
    var text: String
    var value: PValue
    var isLearningTarget: Bool
    var elements: [Element]

    struct Element: Sendable {
        var word: String
        var ruby: String
        var isLearned: Bool
        var isFromUserDictionary: Bool
    }

    init(candidate: Candidate) {
        self.text = candidate.text
        self.value = candidate.value
        self.isLearningTarget = candidate.isLearningTarget
        self.elements = candidate.data.map {
            Element(
                word: $0.word,
                ruby: $0.ruby,
                isLearned: $0.metadata.contains(.isLearned),
                isFromUserDictionary: $0.metadata.contains(.isFromUserDictionary)
            )
        }
    }
}

struct ZenzPersonalizationVector: Sendable {
    var alpha: Float
    var baseLogProb: [Float]
    var personalLogProb: [Float]
}

struct ZenzEvaluationRequest: Sendable {
    var convertTarget: String
    var candidate: ZenzCandidateSnapshot
    var requestRichCandidates: Bool
    var prefixConstraint: ZenzPrefixConstraintSnapshot
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
}

extension Candidate {
    func zenzSnapshot() -> ZenzCandidateSnapshot {
        ZenzCandidateSnapshot(candidate: self)
    }
}

extension Kana2Kanji.PrefixConstraint {
    init(snapshot: ZenzPrefixConstraintSnapshot) {
        self.init(
            snapshot.bytes,
            hasEOS: snapshot.hasEOS,
            ignoreMemoryAndUserDictionary: snapshot.ignoreMemoryAndUserDictionary
        )
    }
}
