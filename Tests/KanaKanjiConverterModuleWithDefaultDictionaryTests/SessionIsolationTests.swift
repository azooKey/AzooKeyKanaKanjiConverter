@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@MainActor
final class SessionIsolationTests: XCTestCase {
    private func options() -> ConvertRequestOptions {
        // Stable, minimal options for deterministic behavior
        .withDefaultDictionary(
            N_best: 10,
            needTypoCorrection: nil,
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            typographyLetterCandidate: false,
            unicodeCandidate: true,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            zenzaiMode: .off,
            metadata: .init(versionString: "tests")
        )
    }

    private func makeComposingText(_ s: String) -> ComposingText {
        var text = ComposingText()
        text.insertAtCursorPosition(s, inputStyle: .direct)
        return text
    }

    func testTwoSessionsDoNotInterfere() {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let sessionA = converter.makeSession()
        let sessionB = converter.makeSession()
        let opts = options()

        // Prepare two different inputs
        let inputA = makeComposingText("かな")
        let inputB = makeComposingText("かに")

        // First round
        let resultA1 = sessionA.requestCandidates(inputA, options: opts)
        let resultB1 = sessionB.requestCandidates(inputB, options: opts)

        // Second round: call again in reverse order to try to trigger any shared-state bugs
        let resultB2 = sessionB.requestCandidates(inputB, options: opts)
        let resultA2 = sessionA.requestCandidates(inputA, options: opts)

        // Validate: each session produces stable results for its own input
        XCTAssertEqual(resultA1.mainResults.map { $0.text }, resultA2.mainResults.map { $0.text })
        XCTAssertEqual(resultB1.mainResults.map { $0.text }, resultB2.mainResults.map { $0.text })

        // And inputs are distinct across sessions (should generally differ)
        XCTAssertNotEqual(resultA1.mainResults.map { $0.text }, resultB1.mainResults.map { $0.text })
    }
}
