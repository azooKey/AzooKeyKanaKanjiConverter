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
}
