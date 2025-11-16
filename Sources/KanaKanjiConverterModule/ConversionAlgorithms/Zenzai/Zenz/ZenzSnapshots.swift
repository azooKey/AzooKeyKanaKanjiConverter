import Foundation
import SwiftUtils

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

struct ZenzCoreMLResultSnapshot: Sendable {
    var bestCandidate: ZenzCandidateSnapshot?
    var alternativeConstraints: [ZenzCandidateEvaluationResult.AlternativeConstraint]
    var latticeSnapshot: LatticeSnapshot
    var cacheSnapshot: ZenzaiCacheSnapshot
}

struct ZenzCoreMLExecutionRequest: Sendable {
    var inputData: ComposingText
    var previousInputData: ComposingText?
    var cacheSnapshot: ZenzaiCacheSnapshot?
    var dicdataSnapshot: DicdataStoreStateSnapshot
    var inferenceLimit: Int
    var requestRichCandidates: Bool
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var personalizationConfig: ZenzPersonalizationVectorConfig?
}

struct LatticeSnapshot: Sendable {
    var inputCount: Int
    var surfaceCount: Int
    var nodes: [LatticeNodeSnapshot]
}

struct LatticeNodeSnapshot: Sendable {
    var range: Lattice.LatticeRange
    var text: String
    var value: PValue
    var metadataFlags: UInt8
}

struct ZenzaiCacheSnapshot: Sendable {
    var inputData: ComposingText
    var constraint: ZenzPrefixConstraintSnapshot
    var satisfyingCandidate: ZenzCandidateSnapshot?
}

extension Kana2Kanji.ZenzaiCache {
    init(snapshot: ZenzaiCacheSnapshot) {
        self.init(
            snapshot.inputData,
            constraint: Kana2Kanji.PrefixConstraint(snapshot: snapshot.constraint),
            satisfyingCandidate: snapshot.satisfyingCandidate?.makeCandidatePlaceholder(),
            lattice: nil
        )
    }
}

extension ZenzCoreMLResultSnapshot {
    init(
        bestCandidate: Candidate?,
        alternativeConstraints: [ZenzCandidateEvaluationResult.AlternativeConstraint],
        lattice: Lattice,
        cache: Kana2Kanji.ZenzaiCache
    ) {
        self.bestCandidate = bestCandidate?.zenzSnapshot()
        self.alternativeConstraints = alternativeConstraints
        self.latticeSnapshot = lattice.snapshot()
        self.cacheSnapshot = cache.snapshot()
    }
}

struct ZenzPersonalizationVector: Sendable {
    var alpha: Float
    var baseLogProb: [Float]
    var personalLogProb: [Float]
}

struct ZenzPersonalizationVectorConfig: Sendable {
    var alpha: Float
    var baseModelName: String
    var personalModelName: String
    var n: Int
    var d: Double

    init(mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode) {
        self.alpha = mode.alpha
        self.baseModelName = mode.baseNgramLanguageModel
        self.personalModelName = mode.personalNgramLanguageModel
        self.n = mode.n
        self.d = mode.d
    }
}

struct ZenzTokenizerMetadata: Sendable {
    var version: ConvertRequestOptions.ZenzVersion
}

struct ZenzEvaluationRequest: Sendable {
    var convertTarget: String
    var candidate: ZenzCandidateSnapshot
    var requestRichCandidates: Bool
    var prefixConstraint: ZenzPrefixConstraintSnapshot
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var tokenizerMetadata: ZenzTokenizerMetadata
    var personalizationConfig: ZenzPersonalizationVectorConfig?
}

extension Candidate {
    func zenzSnapshot() -> ZenzCandidateSnapshot {
        ZenzCandidateSnapshot(candidate: self)
    }
}

extension ZenzCandidateSnapshot {
    func makeCandidatePlaceholder() -> Candidate {
        let elements: [DicdataElement] = self.elements.map { element in
            var metadata: DicdataElementMetadata = []
            if element.isLearned {
                metadata.insert(.isLearned)
            }
            if element.isFromUserDictionary {
                metadata.insert(.isFromUserDictionary)
            }
            return DicdataElement(
                word: element.word,
                ruby: element.ruby,
                lcid: CIDData.BOS.cid,
                rcid: CIDData.BOS.cid,
                mid: MIDData.BOS.mid,
                value: .zero,
                metadata: metadata
            )
        }
        let rubyCount = elements.reduce(0) { $0 + $1.ruby.count }
        return Candidate(
            text: self.text,
            value: self.value,
            composingCount: .surfaceCount(rubyCount),
            lastMid: MIDData.BOS.mid,
            data: elements,
            actions: [],
            inputable: true,
            isLearningTarget: self.isLearningTarget
        )
    }
}

extension Lattice {
    func snapshot() -> LatticeSnapshot {
        var nodes: [LatticeNodeSnapshot] = []
        nodes.reserveCapacity(self.totalNodeCount)
        self.forEachNode { node in
            nodes.append(node.snapshot())
        }
        return LatticeSnapshot(
            inputCount: self.inputNodeColumnsCount,
            surfaceCount: self.surfaceNodeColumnsCount,
            nodes: nodes
        )
    }
}

extension LatticeNode {
    func snapshot() -> LatticeNodeSnapshot {
        var flags: UInt8 = 0
        if self.data.metadata.contains(.isLearned) {
            flags |= 0b0000_0001
        }
        if self.data.metadata.contains(.isFromUserDictionary) {
            flags |= 0b0000_0010
        }
        return LatticeNodeSnapshot(
            range: self.range,
            text: self.data.word,
            value: self.data.value(),
            metadataFlags: flags
        )
    }
}

extension LatticeNodeSnapshot {
    func makeNode() -> LatticeNode {
        var metadata: DicdataElementMetadata = []
        if (self.metadataFlags & 0b0000_0001) != 0 {
            metadata.insert(.isLearned)
        }
        if (self.metadataFlags & 0b0000_0010) != 0 {
            metadata.insert(.isFromUserDictionary)
        }
        let element = DicdataElement(
            word: self.text,
            ruby: self.text,
            lcid: CIDData.BOS.cid,
            rcid: CIDData.BOS.cid,
            mid: MIDData.BOS.mid,
            value: self.value,
            metadata: metadata
        )
        return LatticeNode(data: element, range: self.range)
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
