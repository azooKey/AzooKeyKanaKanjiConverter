import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class AncoSessionTests: XCTestCase {
    private func makeSession(
        requestOptions: ConvertRequestOptions = .init(
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
            metadata: .init(versionString: "anco test")
        )
    ) -> AncoSession {
        AncoSession(defaultDictionaryRequestOptions: requestOptions)
    }

    func testExecuteDirectInputUpdatesComposition() throws {
        var session = self.makeSession()

        let result = try session.execute(.input("あずーきー"))

        XCTAssertEqual(result.action, .candidatesUpdated)
        XCTAssertEqual(result.executedCommand, .input("あずーきー"))
        XCTAssertEqual(result.composingText.convertTarget, "あずーきー")
        XCTAssertEqual(session.composingText.convertTarget, "あずーきー")
        XCTAssertEqual(result.candidates.first?.text, "azooKey")
        XCTAssertEqual(session.page, 0)
    }

    func testContextAndClearCommandsUpdateState() throws {
        var session = self.makeSession()

        _ = try session.execute(.setContext("左"))
        let result = try session.execute(.clearComposition)

        XCTAssertEqual(session.leftSideContext, "")
        XCTAssertTrue(session.composingText.isEmpty)
        XCTAssertEqual(result.action, .stateCleared)
        XCTAssertEqual(result.message, "composition is stopped")
    }

    func testDumpCommandWritesHistory() throws {
        var session = self.makeSession()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let historyURL = directory.appendingPathComponent("history.txt")

        _ = try session.execute(.setConfig(key: "displayTopN", value: "3"))
        _ = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))
        session.recordHistory(.typoCorrection(.init(
            rawCommand: ":tc 3 beam=8",
            nBest: 3,
            beamSize: 8,
            topK: 100,
            maxSteps: nil,
            alpha: 2.0,
            beta: 3.0,
            gamma: 2.0
        )))
        _ = try session.execute(.input("あずーきー"))
        _ = try session.execute(.dumpHistory(historyURL.path))

        let content = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertEqual(
            content,
            [
                ":cfg displayTopN=1",
                ":cfg view=main",
                ":cfg inputStyle=direct",
                ":cfg onlyWholeConversion=false",
                ":cfg predictionMode=automix",
                ":cfg zenzai.inferenceLimit=10",
                ":cfg zenzai.requestRichCandidates=false",
                ":cfg zenzai.experimentalPredictiveInput=false",
                ":cfg liveConversion.enabled=true",
                ":cfg zenzai.profile=",
                ":cfg zenzai.topic=",
                ":cfg displayTopN=3",
                ":cfg inputStyle=roman2kana",
                ":tc 3 beam=8",
                "あずーきー"
            ].joined(separator: "\n")
        )
    }

    func testInputAndOutputLearningCreatesTemporaryMemoryDirectory() throws {
        let requestOptions = ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .inputAndOutput,
            memoryDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            metadata: .init(versionString: "anco test")
        )
        try FileManager.default.createDirectory(at: requestOptions.memoryDirectoryURL, withIntermediateDirectories: true)
        let session = self.makeSession(requestOptions: requestOptions)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.memoryDirectoryURL.path))
    }

    func testCfgUpdatesSessionState() throws {
        var session = self.makeSession()

        let topNResult = try session.execute(.setConfig(key: "displayTopN", value: "3"))
        let styleResult = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))
        let wholeResult = try session.execute(.setConfig(key: "onlyWholeConversion", value: "true"))
        let predictResult = try session.execute(.setConfig(key: "predictionMode", value: "manualmix"))

        XCTAssertEqual(topNResult.action, .configUpdated)
        XCTAssertEqual(topNResult.message, "displayTopN=3")
        XCTAssertEqual(styleResult.action, .configUpdated)
        XCTAssertEqual(styleResult.message, "inputStyle=roman2kana")
        XCTAssertEqual(wholeResult.action, .configUpdated)
        XCTAssertEqual(wholeResult.message, "onlyWholeConversion=true")
        XCTAssertEqual(predictResult.action, .configUpdated)
        XCTAssertEqual(predictResult.message, "predictionMode=manualmix")
    }

    func testCfgUpdatesZenzaiConfig() throws {
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
            zenzaiMode: .on(
                weight: URL(fileURLWithPath: "/tmp/zenz.gguf"),
                inferenceLimit: 12,
                requestRichCandidates: false,
                personalizationMode: nil,
                versionDependentMode: .v3(.init())
            ),
            metadata: .init(versionString: "anco test")
        )
        var session = self.makeSession(requestOptions: requestOptions)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let historyURL = directory.appendingPathComponent("history.txt")

        _ = try session.execute(.setConfig(key: "zenzai.inferenceLimit", value: "24"))
        _ = try session.execute(.setConfig(key: "zenzai.requestRichCandidates", value: "true"))
        _ = try session.execute(.setConfig(key: "zenzai.experimentalPredictiveInput", value: "true"))
        _ = try session.execute(.setConfig(key: "zenzai.profile", value: "developer"))
        _ = try session.execute(.setConfig(key: "zenzai.topic", value: "swift"))
        _ = try session.execute(.dumpHistory(historyURL.path))
        let content = try String(contentsOf: historyURL, encoding: .utf8)

        XCTAssertTrue(content.contains(":cfg zenzai.inferenceLimit=24"))
        XCTAssertTrue(content.contains(":cfg zenzai.requestRichCandidates=true"))
        XCTAssertTrue(content.contains(":cfg zenzai.experimentalPredictiveInput=true"))
        XCTAssertTrue(content.contains(":cfg zenzai.profile=developer"))
        XCTAssertTrue(content.contains(":cfg zenzai.topic=swift"))
    }

    func testSwitchingToPredictionViewImmediatelyReturnsPredictionCandidates() throws {
        var session = self.makeSession()
        _ = try session.execute(.setConfig(key: "inputStyle", value: "roman2kana"))

        for input in ["a", "i", "u", "e", "o", "k", "a", "k", "i", "k", "u", "k", "e"] {
            _ = try session.execute(.input(input))
        }

        let result = try session.execute(.setConfig(key: "view", value: "prediction"))

        XCTAssertEqual(result.action, .configUpdated)
        XCTAssertTrue(
            result.displayedCandidates.contains(where: { $0.text == "あいうえおかきくけこ" }),
            "expected view switch to immediately expose prediction candidates, got: \(result.displayedCandidates.map { $0.text })"
        )
    }

    func testSwitchingToLiveConversionViewImmediatelyReturnsLiveCandidate() throws {
        var session = self.makeSession()
        _ = try session.execute(.input("あずーきー"))

        let result = try session.execute(.setConfig(key: "view", value: "liveConversion"))

        XCTAssertEqual(result.action, .configUpdated)
        XCTAssertEqual(result.displayedCandidates.count, 1)
        XCTAssertEqual(result.displayedCandidates.first?.text, "azooKey")
    }

    func testExecuteSessionEventUpdatesSnapshot() throws {
        var session = self.makeSession()

        let result = try session.execute(event: .insert("あずーきー"))

        XCTAssertEqual(result.executedCommand, .input("あずーきー"))
        XCTAssertEqual(result.snapshot.composingText.convertTarget, "あずーきー")
        XCTAssertEqual(result.snapshot.selectedView, .main)
        switch result.snapshot.presentedContent {
        case let .candidates(candidates):
            XCTAssertEqual(candidates.first?.text, "azooKey")
        case .liveConversion:
            XCTFail("expected main candidate presentation")
        }
    }

    func testSnapshotTracksOutputsAcrossViews() throws {
        var session = self.makeSession()
        _ = try session.execute(.input("あずーきー"))
        _ = try session.execute(.setConfig(key: "view", value: "liveConversion"))

        let snapshot = session.snapshot()

        XCTAssertEqual(snapshot.outputs.mainCandidates.first?.text, "azooKey")
        XCTAssertNotNil(snapshot.outputs.liveConversion)
        XCTAssertTrue(snapshot.config.liveConversion.enabled)
        XCTAssertEqual(snapshot.selectedView, .liveConversion)
        switch snapshot.presentedContent {
        case let .liveConversion(liveConversion):
            XCTAssertEqual(liveConversion.displayedText, "azooKey")
        case .candidates:
            XCTFail("expected live conversion presentation")
        }
    }

    func testPresetAppliesBuiltInConfiguration() throws {
        var session = AncoSession(
            defaultDictionaryRequestOptions: .init(
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
                metadata: .init(versionString: "anco test")
            ),
            preset: "ios-default"
        )

        let result = try session.execute(event: .insert("あずーきー"))

        XCTAssertEqual(result.snapshot.presetID, "ios-default")
        XCTAssertEqual(result.snapshot.config.view, .liveConversion)
        XCTAssertEqual(result.snapshot.config.displayTopN, 1)
        XCTAssertTrue(result.snapshot.config.liveConversion.enabled)
        switch result.snapshot.presentedContent {
        case let .liveConversion(snapshot):
            XCTAssertEqual(snapshot.displayedText, "azooKey")
        case .candidates:
            XCTFail("expected live conversion presentation for ios-default preset")
        }
    }

    func testDisablingLiveConversionClearsPresentedLiveView() throws {
        var session = self.makeSession()
        _ = try session.execute(.input("あずーきー"))
        _ = try session.execute(.setConfig(key: "view", value: "liveConversion"))

        let result = try session.execute(.setConfig(key: "liveConversion.enabled", value: "false"))

        XCTAssertEqual(result.snapshot.config.liveConversion.enabled, false)
        switch result.snapshot.presentedContent {
        case let .candidates(candidates):
            XCTAssertTrue(candidates.isEmpty)
        case .liveConversion:
            XCTFail("expected live conversion view to fall back when disabled")
        }
    }
}
