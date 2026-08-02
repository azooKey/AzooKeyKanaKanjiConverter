import Foundation
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class ConverterSessionTests: XCTestCase {
    func testStopCompositionOnlyResetsActiveSession() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let firstSession = converter.createSession()
        let secondSession = converter.createSession()

        try converter.withSession(firstSession) {
            converter.stopComposition()
        }

        XCTAssertNoThrow(
            try converter.withSession(secondSession) {
                var composingText = ComposingText()
                composingText.insertAtCursorPosition("あずーきー", inputStyle: .direct)
                _ = converter.requestCandidates(composingText, options: requestOptions())
            }
        )
    }

    func testRemovedSessionCannotBeSelected() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let removedSession = converter.createSession()
        let remainingSession = converter.createSession()

        converter.removeSession(removedSession)

        XCTAssertThrowsError(try converter.withSession(removedSession) {}) { error in
            XCTAssertEqual(
                error as? KanaKanjiConverter.ConversionSessionError,
                .unknownSession(removedSession)
            )
        }
        XCTAssertNoThrow(try converter.withSession(remainingSession) {})
    }

    func testNestedSessionSelectionRestoresOuterSession() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let outerSession = converter.createSession()
        let innerSession = converter.createSession()

        try converter.withSession(outerSession) {
            try converter.withSession(innerSession) {
                converter.stopComposition()
            }
            converter.stopComposition()
        }

        XCTAssertNoThrow(try converter.withSession(outerSession) {})
        XCTAssertNoThrow(try converter.withSession(innerSession) {})
    }

    private func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }
}
