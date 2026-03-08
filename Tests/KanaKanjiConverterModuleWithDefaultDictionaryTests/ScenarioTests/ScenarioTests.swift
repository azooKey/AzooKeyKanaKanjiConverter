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

    func testRoman2KanaPredictionStabilityKeepsKekoThroughUnresolvedSuffix() throws {
        var session = self.makeSession()
        _ = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))

        for input in ["a", "i", "u", "e", "o", "k", "a", "k", "i", "k", "u", "k", "e"] {
            _ = try session.execute(.input(input))
        }

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけ")
        XCTAssertEqual(session.lastCandidates.first?.text, "あいうえおかきくけこ")

        _ = try session.execute(.input("k"))

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけk")
        XCTAssertTrue(
            session.lastCandidates.contains(where: { $0.text == "あいうえおかきくけこ" }),
            "expected stable prediction candidate to survive for unresolved suffix, got: \(session.lastCandidates.map { $0.text })"
        )
    }

    func testPredictionViewKeepsStablePredictionResultsThroughUnresolvedSuffix() throws {
        var session = self.makeSession()
        _ = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))

        for input in ["a", "i", "u", "e", "o", "k", "a", "k", "i", "k", "u", "k", "e"] {
            _ = try session.execute(.input(input))
        }

        _ = try session.execute(.setConfig(key: "view", value: "prediction"))

        XCTAssertTrue(
            session.lastCandidates.contains(where: { $0.text == "あいうえおかきくけこ" }),
            "expected prediction view to include stable prediction candidate, got: \(session.lastCandidates.map { $0.text })"
        )

        _ = try session.execute(.input("k"))

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけk")
        XCTAssertTrue(
            session.lastCandidates.contains(where: { $0.text == "あいうえおかきくけこ" }),
            "expected prediction view to keep stable prediction candidate through unresolved suffix, got: \(session.lastCandidates.map { $0.text })"
        )
    }

    func testManualMixPredictionViewKeepsStablePredictionResultsThroughUnresolvedSuffix() throws {
        var session = self.makeSession()
        _ = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))
        _ = try session.execute(.setConfig(key: "predictionMode", value: "manualmix"))

        for input in ["a", "i", "u", "e", "o", "k", "a", "k", "i", "k", "u", "k", "e"] {
            _ = try session.execute(.input(input))
        }

        _ = try session.execute(.setConfig(key: "view", value: "prediction"))

        XCTAssertTrue(
            session.lastCandidates.contains(where: { $0.text == "あいうえおかきくけこ" }),
            "expected manualmix prediction view to include stable prediction candidate, got: \(session.lastCandidates.map { $0.text })"
        )

        _ = try session.execute(.input("k"))

        XCTAssertEqual(session.composingText.convertTarget, "あいうえおかきくけk")
        XCTAssertTrue(
            session.lastCandidates.contains(where: { $0.text == "あいうえおかきくけこ" }),
            "expected manualmix prediction view to keep stable prediction candidate through unresolved suffix, got: \(session.lastCandidates.map { $0.text })"
        )
    }

}
