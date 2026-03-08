import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class ScenarioTests: XCTestCase {
    private func makeSession() -> AncoSession {
        let requestOptions = ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            metadata: .init(versionString: "scenario test")
        )
        return AncoSession(defaultDictionaryRequestOptions: requestOptions)
    }

    private func prepareSession(
        predictionMode: String = "automix"
    ) throws -> AncoSession {
        let romanSequenceToStablePrediction = ["a", "i", "u", "e", "o", "k", "a", "k", "i", "k", "u", "k", "e"]
        var session = self.makeSession()
        _ = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))
        if predictionMode != "automix" {
            _ = try session.execute(.setConfig(key: "predictionMode", value: predictionMode))
        }
        for input in romanSequenceToStablePrediction {
            _ = try session.execute(.input(input))
        }
        return session
    }

    private func assertStablePredictionPresent(
        _ session: AncoSession,
        source: AncoSessionPresentationContext.CandidateSource,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stablePredictionTarget = "あいうえおかきくけこ"
        let presentation = AncoSessionPresenter.present(session: session, context: .init(candidateSource: source))
        XCTAssertTrue(
            presentation.candidates.contains(where: { $0.text == stablePredictionTarget }),
            "\(message), got: \(presentation.candidates.map { $0.text })",
            file: file,
            line: line
        )
    }

    func testRoman2KanaPredictionStabilityKeepsKekoThroughUnresolvedSuffix() throws {
        let stablePredictionTarget = "あいうえおかきくけこ"
        var session = try self.prepareSession()
        let presentation = AncoSessionPresenter.present(session: session, context: .init())

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけ")
        XCTAssertEqual(presentation.candidates.first?.text, stablePredictionTarget)

        _ = try session.execute(.input("k"))

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけk")
        self.assertStablePredictionPresent(
            session,
            source: .main,
            message: "expected stable prediction candidate to survive for unresolved suffix"
        )
    }

    func testPredictionPresentationKeepsStablePredictionResultsThroughUnresolvedSuffix() throws {
        var session = try self.prepareSession()

        self.assertStablePredictionPresent(
            session,
            source: .prediction,
            message: "expected prediction presentation to include stable prediction candidate"
        )

        _ = try session.execute(.input("k"))

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけk")
        self.assertStablePredictionPresent(
            session,
            source: .prediction,
            message: "expected prediction presentation to keep stable prediction candidate through unresolved suffix"
        )
    }

    func testManualMixPredictionPresentationKeepsStablePredictionResultsThroughUnresolvedSuffix() throws {
        var session = try self.prepareSession(predictionMode: "manualmix")

        self.assertStablePredictionPresent(
            session,
            source: .prediction,
            message: "expected manualmix prediction presentation to include stable prediction candidate"
        )

        _ = try session.execute(.input("k"))

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけk")
        self.assertStablePredictionPresent(
            session,
            source: .prediction,
            message: "expected manualmix prediction presentation to keep stable prediction candidate through unresolved suffix"
        )
    }

}
