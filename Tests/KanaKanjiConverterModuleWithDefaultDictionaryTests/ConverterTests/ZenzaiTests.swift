import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

#if Zenzai || ZenzaiCPU
final class ZenzaiTests: XCTestCase {
    private func measuredRequestCandidates(
        _ converter: KanaKanjiConverter,
        composingText: ComposingText,
        options: ConvertRequestOptions,
        latencies: inout [Double]?
    ) -> ConversionResult {
        guard latencies != nil else {
            return converter.requestCandidates(composingText, options: options)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let result = converter.requestCandidates(composingText, options: options)
        latencies?.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        return result
    }

    private func reportLatencies(_ latencies: [Double]?, label: String) {
        guard let latencies, !latencies.isEmpty else {
            return
        }
        let sorted = latencies.sorted()
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let p90Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.9)) - 1)
        print(
            "[ZenzaiLatency] \(label)"
                + " count=\(sorted.count)"
                + " averageMs=\(average)"
                + " p90Ms=\(sorted[p90Index])"
                + " maxMs=\(sorted[sorted.count - 1])"
        )
    }

    private func inferenceLimitLabel(_ inferenceLimit: Int) -> String {
        inferenceLimit == .max ? "max" : String(inferenceLimit)
    }

    func sequentialInput(_ composingText: inout ComposingText, sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) {
        for char in sequence {
            composingText.insertAtCursorPosition(String(char), inputStyle: inputStyle)
        }
    }

    func requestOptions(
        inferenceLimit: Int = Int.max,
        leftSideContext: String? = nil
    ) -> ConvertRequestOptions {
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
            typoCorrectionMode: .automatic,
            metadata: nil
        )
    }

    func testIncrementalLatticeMatchesFullRebuildForRomanAndAZIKTailRewrites() {
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let kanaKanji = Kana2Kanji(dicdataStore: dicdataStore)
        let state = dicdataStore.prepareState()

        func firstTailRewrite(
            in sequence: String,
            inputStyle: InputStyle
        ) -> (old: ComposingText, new: ComposingText)? {
            var current = ComposingText()
            for character in sequence {
                let old = current
                current.insertAtCursorPosition(String(character), inputStyle: inputStyle)
                if !old.convertTarget.isEmpty,
                   !current.convertTarget.hasPrefix(old.convertTarget) {
                    return (old, current)
                }
            }
            return nil
        }

        func assertIncrementalMatchesFull(
            _ pair: (old: ComposingText, new: ComposingText),
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let oldResult = kanaKanji.kana2lattice_all(
                pair.old,
                N_best: 2,
                needTypoCorrection: false,
                dicdataStoreState: state
            )
            let incrementalLattice = kanaKanji.buildLatticeWithIncrementalCache(
                inputData: pair.new,
                inputCount: pair.new.input.count,
                surfaceCount: pair.new.convertTarget.count,
                incrementalCacheInfo: (pair.old, oldResult.lattice),
                dicdataStoreState: state
            )
            let incremental = kanaKanji.kana2lattice_all(
                pair.new,
                N_best: 2,
                needTypoCorrection: false,
                preprocessedLattice: incrementalLattice,
                dicdataStoreState: state
            )
            let full = kanaKanji.kana2lattice_all(
                pair.new,
                N_best: 2,
                needTypoCorrection: false,
                dicdataStoreState: state
            )
            let incrementalCandidates = incremental.result.getCandidateData().map(kanaKanji.processClauseCandidate)
            let fullCandidates = full.result.getCandidateData().map(kanaKanji.processClauseCandidate)
            XCTAssertEqual(incrementalCandidates.map(\.text), fullCandidates.map(\.text), file: file, line: line)
            XCTAssertEqual(incrementalCandidates.map(\.value), fullCandidates.map(\.value), file: file, line: line)
        }

        let roman = firstTailRewrite(in: "konobunshou", inputStyle: .roman2kana)
        let azik = firstTailRewrite(in: "konobjxp", inputStyle: .mapped(id: .defaultAZIK))
        XCTAssertNotNil(roman)
        XCTAssertNotNil(azik)
        if let roman { assertIncrementalMatchesFull(roman) }
        if let azik { assertIncrementalMatchesFull(azik) }
    }

    func testFullConversion() async throws {
        // 各doブロックは独立した変換セッションである。同じ入力を繰り返すケースも、
        // 以前のConverterの変換結果キャッシュに依存せず再評価される必要がある。
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
        let profilesLatency = ProcessInfo.processInfo.environment["ZENZAI_PROFILE_LATENCY"] == "1"
        // inferenceLimitごとに独立したシナリオとして測る。Converterは必ずループ内で
        // 生成し、別limitで得た変換結果LRUのwarm hitを性能値へ混入させないこと。
        // モデル重みとnative contextの共有は、製品のメモリ設計どおり許容する。
        for inferenceLimit in [1, 2, 3, 5, .max] {
            var latencies: [Double]? = profilesLatency ? [] : nil
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            var c = ComposingText()
            let text = "このぶんしょうはかんじへんかんがせいかくということでわだいのにほんごにゅうりょくしすてむをつかってうちこんでいます"
            for char in text {
                c.insertAtCursorPosition(String(char), inputStyle: .direct)
                let results = self.measuredRequestCandidates(
                    converter,
                    composingText: c,
                    options: requestOptions(inferenceLimit: inferenceLimit),
                    latencies: &latencies
                )
                if c.input.count == text.count {
                    XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
                }
            }
            self.reportLatencies(
                latencies,
                label: "Direct inferenceLimit=\(self.inferenceLimitLabel(inferenceLimit))"
            )
        }
    }

    @MainActor
    func testGradualConversion_Roman2Kana() throws {
        // 辞書は先に読み込んでおく（純粋な比較のため）
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let profilesLatency = ProcessInfo.processInfo.environment["ZENZAI_PROFILE_LATENCY"] == "1"
        // inferenceLimitごとに独立したシナリオとして測る。Converterは必ずループ内で
        // 生成し、別limitで得た変換結果LRUのwarm hitを性能値へ混入させないこと。
        // モデル重みとnative contextの共有は、製品のメモリ設計どおり許容する。
        for inferenceLimit in [1, 2, 3, 5, .max] {
            var latencies: [Double]? = profilesLatency ? [] : nil
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            var c = ComposingText()
            let text = "konobunshouhakanjihenkangaseikakutoiukotodewadainonihongonyuuryokusisutemuwotukatteutikondeimasu"
            for char in text {
                c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
                let results = self.measuredRequestCandidates(
                    converter,
                    composingText: c,
                    options: requestOptions(inferenceLimit: inferenceLimit),
                    latencies: &latencies
                )
                if c.input.count == text.count {
                    XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
                }
            }
            self.reportLatencies(
                latencies,
                label: "Roman2Kana inferenceLimit=\(self.inferenceLimitLabel(inferenceLimit))"
            )
        }
    }

    @MainActor
    func testGradualConversion_AZIK() throws {
        // 辞書は先に読み込んでおく（純粋な比較のため）
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let profilesLatency = ProcessInfo.processInfo.environment["ZENZAI_PROFILE_LATENCY"] == "1"
        // inferenceLimitごとに独立したシナリオとして測る。Converterは必ずループ内で
        // 生成し、別limitで得た変換結果LRUのwarm hitを性能値へ混入させないこと。
        // モデル重みとnative contextの共有は、製品のメモリ設計どおり許容する。
        for inferenceLimit in [1, 2, 3, 5, .max] {
            var latencies: [Double]? = profilesLatency ? [] : nil
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            var c = ComposingText()
            let text = "konobjxphakzzihdkzgasskakutoiuktdewadqnonihlgonyhryokusisutemuwotuka；teutikldwms"
            for char in text {
                c.insertAtCursorPosition(String(char), inputStyle: .mapped(id: .defaultAZIK))
                let results = self.measuredRequestCandidates(
                    converter,
                    composingText: c,
                    options: requestOptions(inferenceLimit: inferenceLimit),
                    latencies: &latencies
                )
                if c.input.count == text.count {
                    XCTAssertEqual(results.mainResults.first?.text, "この文章は漢字変換が正確ということで話題の日本語入力システムを使って打ち込んでいます")
                }
            }
            self.reportLatencies(
                latencies,
                label: "AZIK inferenceLimit=\(self.inferenceLimitLabel(inferenceLimit))"
            )
        }
    }

    func testTypoCorrection_OneShot_Roman2Kana() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var c = ComposingText()
        self.sequentialInput(&c, sequence: "ojsyougozainasu", inputStyle: .roman2kana)
        let typoCandidates = converter.experimentalRequestTypoCorrection(
            leftSideContext: "やあ、",
            composingText: c,
            options: self.requestOptions(leftSideContext: "やあ、"),
            inputStyle: .roman2kana,
            config: .init(languageModel: .zenz, beamSize: 10, topK: 100, nBest: 20)
        )
        XCTAssertTrue(
            typoCandidates.contains(where: { $0.correctedInput == "ohayougozaimasu" }),
            "expected ohayougozaimasu in typo candidates, got: \(typoCandidates.map(\.correctedInput))"
        )
    }
}
#endif
