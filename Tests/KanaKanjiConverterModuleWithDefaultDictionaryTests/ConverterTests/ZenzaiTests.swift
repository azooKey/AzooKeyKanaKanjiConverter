import Foundation
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

#if Zenzai || ZenzaiCPU
final class ZenzaiTests: XCTestCase {
    func sequentialInput(_ composingText: inout ComposingText, sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) {
        for char in sequence {
            composingText.insertAtCursorPosition(String(char), inputStyle: inputStyle)
        }
    }

    func requestOptions(
        inferenceLimit: Int = Int.max,
        leftSideContext: String? = nil
    ) -> ConvertRequestOptions {
        print("You need to install azooKeyMac.app to run this test.")
        return .init(
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
            zenzaiMode: .on(
                weight: URL(fileURLWithPath: "/Library/Input Methods/azooKeyMac.app/Contents/Resources/ggml-model-Q5_K_M.gguf"),
                inferenceLimit: inferenceLimit,
                personalizationMode: .none,
                versionDependentMode: .v3(.init(leftSideContext: leftSideContext))
            ),
            typoCorrectionConfig: .init(
                mode: .auto,
                languageModel: .zenz
            ),
            metadata: nil
        )
    }

    func testFullConversion() async throws {
        do {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            var c = ComposingText()
            c.insertAtCursorPosition("はがいたいのでしかいにみてもらった", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertEqual(results.mainResults.first?.text, "歯が痛いので歯科医に診てもらった")
        }
        do {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            var c = ComposingText()
            c.insertAtCursorPosition("おんしゃをだいいちにしぼうしています", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertEqual(results.mainResults.first?.text, "御社を第一に志望しています")
        }
        do {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            var c = ComposingText()
            c.insertAtCursorPosition("おんしゃをだいいちにしぼうしています", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertEqual(results.mainResults.first?.text, "御社を第一に志望しています")
        }
        do {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            var c = ComposingText()
            c.insertAtCursorPosition("ふくをきて、きをきって、うみにきた", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertEqual(results.mainResults.first?.text, "服を着て、木を切って、海に来た")
        }
        do {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            var c = ComposingText()
            c.insertAtCursorPosition("このぶんしょうはかんじへんかんがせいかくということでわだいのにほんごにゅうりょくしすてむをつかってうちこんでいます", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
        }
    }

    @MainActor
    func testGradualConversion() throws {
        // 辞書は先に読み込んでおく（純粋な比較のため）
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        for inferenceLimit in [1, 2, 3, 5, .max] {
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            var c = ComposingText()
            let text = "このぶんしょうはかんじへんかんがせいかくということでわだいのにほんごにゅうりょくしすてむをつかってうちこんでいます"
            for char in text {
                c.insertAtCursorPosition(String(char), inputStyle: .direct)
                let results = converter.requestCandidates(c, options: requestOptions(inferenceLimit: inferenceLimit))
                if c.input.count == text.count {
                    XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
                }
            }
        }
    }

    @MainActor
    func testGradualConversion_Roman2Kana() throws {
        // 辞書は先に読み込んでおく（純粋な比較のため）
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        for inferenceLimit in [1, 2, 3, 5, .max] {
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            var c = ComposingText()
            let text = "konobunshouhakanjihenkangaseikakutoiukotodewadainonihongonyuuryokusisutemuwotukatteutikondeimasu"
            for char in text {
                c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
                let results = converter.requestCandidates(c, options: requestOptions(inferenceLimit: inferenceLimit))
                if c.input.count == text.count {
                    XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
                }
            }
        }
    }

    @MainActor
    func testGradualConversion_AZIK() throws {
        // 辞書は先に読み込んでおく（純粋な比較のため）
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        for inferenceLimit in [1, 2, 3, 5, .max] {
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            var c = ComposingText()
            let text = "konobjxphakzzihdkzgasskakutoiuktdewadqnonihlgonyhryokusisutemuwotuka；teutikldwms"
            for char in text {
                c.insertAtCursorPosition(String(char), inputStyle: .mapped(id: .defaultAZIK))
                let results = converter.requestCandidates(c, options: requestOptions(inferenceLimit: inferenceLimit))
                if c.input.count == text.count {
                    XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
                }
            }
        }
    }

    func testTypoCorrection_OneShot_Roman2Kana() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var c = ComposingText()
        self.sequentialInput(&c, sequence: "ojsyougozainasu", inputStyle: .roman2kana)
        let typoCandidates = converter.experimentalRequestTypoCorrectionOnly(
            leftSideContext: "やあ、",
            composingText: c,
            options: self.requestOptions(leftSideContext: "やあ、"),
            inputStyle: .roman2kana,
            searchConfig: .init(beamSize: 10, topK: 100, nBest: 20)
        )
        XCTAssertTrue(
            typoCandidates.contains(where: { $0.correctedInput == "ohayougozaimasu" }),
            "expected ohayougozaimasu in typo candidates, got: \(typoCandidates.map(\.correctedInput))"
        )
    }
}
#endif
