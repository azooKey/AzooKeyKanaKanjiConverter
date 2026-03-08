import Foundation
@testable import KanaKanjiConverterModule
import XCTest

final class SessionCandidateSelectionTests: XCTestCase {
    func testCompletePrefixCandidateEndsCompositionWhenWholeInputIsCommitted() {
        let converter = KanaKanjiConverter.withoutDictionary()
        var composingText = ComposingText()
        composingText.insertAtCursorPosition("かな", inputStyle: .direct)
        let candidate = Candidate(
            text: "仮名",
            value: 0,
            composingCount: .surfaceCount(2),
            lastMid: MIDData.一般.mid,
            data: [],
            isLearningTarget: false
        )

        let result = converter.completePrefixCandidate(candidate, composingText: &composingText)

        XCTAssertEqual(result, .compositionEnded)
        XCTAssertTrue(composingText.isEmpty)
    }

    func testCompletePrefixCandidateKeepsRemainingCompositionWhenPrefixIsCommitted() {
        let converter = KanaKanjiConverter.withoutDictionary()
        var composingText = ComposingText()
        composingText.insertAtCursorPosition("かな", inputStyle: .direct)
        let candidate = Candidate(
            text: "か",
            value: 0,
            composingCount: .surfaceCount(1),
            lastMid: MIDData.一般.mid,
            data: [],
            isLearningTarget: false
        )

        let result = converter.completePrefixCandidate(candidate, composingText: &composingText)

        XCTAssertEqual(result, .compositionContinues)
        XCTAssertEqual(composingText.convertTarget, "な")
    }
}
