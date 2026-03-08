import KanaKanjiConverterModule
import XCTest

final class LiveConversionStateTests: XCTestCase {
    private func makeCandidate(text: String, data: [DicdataElement], inputCount: Int) -> Candidate {
        Candidate(
            text: text,
            value: 0,
            composingCount: .inputCount(inputCount),
            lastMid: MIDData.一般.mid,
            data: data
        )
    }

    func testDisabledStateReturnsRawConvertTarget() {
        var state = LiveConversionState(config: .init(enabled: false))
        var composingText = ComposingText()
        composingText.insertAtCursorPosition("かな", inputStyle: .direct)

        let snapshot = state.update(
            composingText,
            candidates: [],
            firstClauseResults: [],
            convertTargetCursorPosition: composingText.convertTargetCursorPosition,
            convertTarget: composingText.convertTarget
        )

        XCTAssertEqual(snapshot.displayedText, "かな")
        XCTAssertNil(snapshot.currentCandidate)
        XCTAssertNil(snapshot.autoCommitCandidate)
    }

    func testStableFirstClauseProducesAutoCommitCandidate() {
        var state = LiveConversionState(config: .init(enabled: true, autoCommitThreshold: 3))

        var composingText1 = ComposingText()
        composingText1.insertAtCursorPosition("abc", inputStyle: .direct)
        let candidate1 = self.makeCandidate(
            text: "甲",
            data: [
                .init(word: "甲", ruby: "ABC", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
            ],
            inputCount: 3
        )
        _ = state.update(
            composingText1,
            candidates: [candidate1],
            firstClauseResults: [candidate1],
            convertTargetCursorPosition: composingText1.convertTargetCursorPosition,
            convertTarget: composingText1.convertTarget
        )

        var composingText2 = ComposingText()
        composingText2.insertAtCursorPosition("abcd", inputStyle: .direct)
        let candidate2 = self.makeCandidate(
            text: "甲乙",
            data: [
                .init(word: "甲", ruby: "ABC", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0),
                .init(word: "乙", ruby: "D", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
            ],
            inputCount: 4
        )
        _ = state.update(
            composingText2,
            candidates: [candidate2],
            firstClauseResults: [candidate1],
            convertTargetCursorPosition: composingText2.convertTargetCursorPosition,
            convertTarget: composingText2.convertTarget
        )

        var composingText3 = ComposingText()
        composingText3.insertAtCursorPosition("abcde", inputStyle: .direct)
        let candidate3 = self.makeCandidate(
            text: "甲丙",
            data: [
                .init(word: "甲", ruby: "ABC", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0),
                .init(word: "丙", ruby: "DE", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
            ],
            inputCount: 5
        )
        let snapshot = state.update(
            composingText3,
            candidates: [candidate3],
            firstClauseResults: [candidate1],
            convertTargetCursorPosition: composingText3.convertTargetCursorPosition,
            convertTarget: composingText3.convertTarget
        )

        XCTAssertEqual(snapshot.displayedText, "甲丙")
        XCTAssertEqual(snapshot.autoCommitCandidate?.text, "甲")
        XCTAssertEqual(snapshot.firstClauseHistory.map(\.text), ["甲", "甲", "甲"])
    }

    func testSessionCandidateResultsProjectsConversionResultWithLiveConversionSnapshot() {
        var state = LiveConversionState(config: .init(enabled: true))
        var composingText = ComposingText()
        composingText.insertAtCursorPosition("abc", inputStyle: .direct)
        let candidate = self.makeCandidate(
            text: "甲",
            data: [
                .init(word: "甲", ruby: "ABC", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
            ],
            inputCount: 3
        )

        let sessionCandidates = SessionCandidateResults(
            conversionResult: .init(mainResults: [candidate], predictionResults: [candidate], englishPredictionResults: [], firstClauseResults: [candidate]),
            composingText: composingText,
            liveConversionState: &state
        )

        XCTAssertEqual(sessionCandidates.mainCandidates.map(\.text), ["甲"])
        XCTAssertEqual(sessionCandidates.predictionCandidates.map(\.text), ["甲"])
        XCTAssertEqual(sessionCandidates.firstClauseCandidates.map(\.text), ["甲"])
        XCTAssertEqual(sessionCandidates.liveConversionSnapshot?.displayedText, "甲")
    }
}
