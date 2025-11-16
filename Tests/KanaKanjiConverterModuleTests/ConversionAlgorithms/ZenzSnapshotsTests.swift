@testable import KanaKanjiConverterModule
import XCTest

final class ZenzSnapshotsTests: XCTestCase {
    func testCandidateSnapshotCarriesMetadata() {
        var metadata: DicdataElementMetadata = []
        metadata.insert(.isLearned)
        metadata.insert(.isFromUserDictionary)
        let element = DicdataElement(
            word: "雨",
            ruby: "あめ",
            lcid: CIDData.BOS.cid,
            rcid: CIDData.BOS.cid,
            mid: MIDData.BOS.mid,
            value: .zero,
            metadata: metadata
        )
        let candidate = Candidate(
            text: "雨",
            value: .zero,
            composingCount: .surfaceCount(2),
            lastMid: MIDData.BOS.mid,
            data: [element]
        )
        let snapshot = candidate.zenzSnapshot()
        XCTAssertEqual(snapshot.elements.count, 1)
        XCTAssertTrue(snapshot.elements[0].isLearned)
        XCTAssertTrue(snapshot.elements[0].isFromUserDictionary)
    }

    func testPrefixConstraintSnapshotRoundTrip() {
        let original = Kana2Kanji.PrefixConstraint([UInt8]("abc".utf8), hasEOS: true, ignoreMemoryAndUserDictionary: true)
        let snapshot = ZenzPrefixConstraintSnapshot(original)
        XCTAssertTrue(snapshot.hasPrefix("ab"))
        let roundTrip = Kana2Kanji.PrefixConstraint(snapshot: snapshot)
        XCTAssertEqual(roundTrip.constraint, original.constraint)
        XCTAssertEqual(roundTrip.hasEOS, original.hasEOS)
        XCTAssertEqual(roundTrip.ignoreMemoryAndUserDictionary, original.ignoreMemoryAndUserDictionary)
    }

    func testCoreMLResultSnapshotCapturesCacheAndConstraints() {
        let metadata: DicdataElementMetadata = [.isLearned]
        let element = DicdataElement(
            word: "雨",
            ruby: "あめ",
            lcid: CIDData.BOS.cid,
            rcid: CIDData.BOS.cid,
            mid: MIDData.BOS.mid,
            value: .zero,
            metadata: metadata
        )
        let candidate = Candidate(
            text: "雨",
            value: .zero,
            composingCount: .surfaceCount(2),
            lastMid: MIDData.BOS.mid,
            data: [element]
        )
        let inputData = ComposingText(convertTargetCursorPosition: 2, input: [], convertTarget: "あめ")
        let constraintBytes = Array("ア".utf8)
        let cache = Kana2Kanji.ZenzaiCache(
            inputData,
            constraint: Kana2Kanji.PrefixConstraint(constraintBytes),
            satisfyingCandidate: candidate,
            lattice: nil
        )
        let alternatives = [
            ZenzCandidateEvaluationResult.AlternativeConstraint(probabilityRatio: 0.5, prefixConstraint: Array("代替".utf8))
        ]
        let snapshot = ZenzCoreMLResultSnapshot(
            bestCandidate: candidate,
            alternativeConstraints: alternatives,
            lattice: Lattice(),
            cache: cache
        )
        XCTAssertEqual(snapshot.bestCandidate?.text, candidate.text)
        XCTAssertEqual(snapshot.alternativeConstraints, alternatives)
        XCTAssertEqual(snapshot.cacheSnapshot.inputData.convertTarget, inputData.convertTarget)
        XCTAssertEqual(snapshot.cacheSnapshot.constraint.bytes, constraintBytes)
    }

    func testCandidateSnapshotCreatesPlaceholderCandidate() {
        let metadata: DicdataElementMetadata = [.isLearned]
        let element = DicdataElement(
            word: "語",
            ruby: "ご",
            lcid: CIDData.BOS.cid,
            rcid: CIDData.BOS.cid,
            mid: MIDData.BOS.mid,
            value: .zero,
            metadata: metadata
        )
        let original = Candidate(
            text: "語",
            value: .zero,
            composingCount: .surfaceCount(1),
            lastMid: MIDData.BOS.mid,
            data: [element]
        )
        let snapshot = original.zenzSnapshot()
        let candidate = snapshot.makeCandidatePlaceholder()
        XCTAssertEqual(candidate.text, original.text)
        XCTAssertEqual(candidate.data.first?.word, element.word)
        XCTAssertTrue(candidate.data.first?.metadata.contains(.isLearned) ?? false)
    }

    func testZenzaiCacheRestoresFromSnapshot() {
        let element = DicdataElement(
            word: "雨",
            ruby: "あめ",
            lcid: CIDData.BOS.cid,
            rcid: CIDData.BOS.cid,
            mid: MIDData.BOS.mid,
            value: .zero
        )
        let candidate = Candidate(
            text: "雨",
            value: .zero,
            composingCount: .surfaceCount(2),
            lastMid: MIDData.BOS.mid,
            data: [element]
        )
        let inputData = ComposingText(convertTargetCursorPosition: 2, input: [], convertTarget: "あめ")
        let cache = Kana2Kanji.ZenzaiCache(
            inputData,
            constraint: Kana2Kanji.PrefixConstraint(Array("ア".utf8)),
            satisfyingCandidate: candidate,
            lattice: nil
        )
        let snapshot = cache.snapshot()
        let restored = Kana2Kanji.ZenzaiCache(snapshot: snapshot)
        let restoredSnapshot = restored.snapshot()
        XCTAssertEqual(restoredSnapshot.inputData.convertTarget, snapshot.inputData.convertTarget)
        XCTAssertEqual(restoredSnapshot.constraint.bytes, snapshot.constraint.bytes)
        XCTAssertEqual(restoredSnapshot.satisfyingCandidate?.text, snapshot.satisfyingCandidate?.text)
    }

    func testLatticeSnapshotRoundTrip() {
        let nodeSnapshots = [
            LatticeNodeSnapshot(
                range: .input(from: 0, to: 1),
                text: "雨",
                value: -1,
                metadataFlags: 0b0000_0011
            ),
            LatticeNodeSnapshot(
                range: .surface(from: 0, to: 1),
                text: "あめ",
                value: -0.5,
                metadataFlags: 0
            )
        ]
        let snapshot = LatticeSnapshot(inputCount: 2, surfaceCount: 2, nodes: nodeSnapshots)
        let lattice = Lattice(snapshot: snapshot)
        let roundTrip = lattice.snapshot()
        XCTAssertEqual(roundTrip.inputCount, snapshot.inputCount)
        XCTAssertEqual(roundTrip.surfaceCount, snapshot.surfaceCount)
        XCTAssertEqual(roundTrip.nodes.count, snapshot.nodes.count)
        XCTAssertEqual(roundTrip.nodes.first?.text, nodeSnapshots.first?.text)
        XCTAssertEqual(roundTrip.nodes.first?.metadataFlags, nodeSnapshots.first?.metadataFlags)
    }
}
