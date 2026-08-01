import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

#if Zenzai || ZenzaiCPU
final class ZenzaiTests: XCTestCase {
    private struct DesktopPredictionScenario {
        var label: String
        var leftSideContext: String
        var input: String
    }

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

    /// azooKeyDesktopの`SegmentsManager.options`が予測入力を有効にしたときの設定を再現する。
    ///
    /// Desktopでは各キー入力のたびにJapanese/English predictionを`.manualMix`で要求し、
    /// Zenzaiの予測フォールバックも常時有効にする。既定の推論上限は5である。
    /// 学習とpersonalizationだけはbenchmark結果を端末固有データから分離するため無効化する。
    private func desktopPredictiveInputOptions(
        leftSideContext: String?,
        rightSideContext: String? = nil
    ) -> ConvertRequestOptions {
        .init(
            N_best: 10,
            requireJapanesePrediction: .manualMix,
            requireEnglishPrediction: .manualMix,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: .on(
                weight: URL(fileURLWithPath: "/Library/Input Methods/azooKeyMac.app/Contents/Resources/ggml-model-Q5_K_M.gguf"),
                inferenceLimit: 5,
                requestRichCandidates: false,
                personalizationMode: .none,
                versionDependentMode: .v3(
                    .init(
                        profile: "",
                        leftSideContext: leftSideContext,
                        rightSideContext: rightSideContext,
                        enableAlignmentSeparator: true
                    )
                )
            ),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: .init(versionString: "azooKey on macOS (benchmark)")
        )
    }

    /// azooKey for iOSのDirect入力で使われる主要設定を再現する。
    ///
    /// 辞書・Zenzaiの候補評価だけを測る簡略設定では、llama.cpp更新による実端末上の
    /// 逐次入力regressionを捕捉できなかった。prediction、learning、left contextを
    /// 有効にした状態で、文字数の増加に伴う各requestのlatencyを観測する。
    private func iOSDirectInputOptions() -> ConvertRequestOptions {
        .init(
            N_best: 10,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .autoMix,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: true,
            halfWidthKanaCandidate: true,
            learningType: .inputAndOutput,
            maxMemoryCount: 65_536,
            shouldResetMemory: false,
            memoryDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("azookey-ios-direct-benchmark-memory"),
            sharedContainerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("azookey-ios-direct-benchmark-shared"),
            textReplacer: .empty,
            specialCandidateProviders: [],
            zenzaiMode: .on(
                weight: URL(
                    fileURLWithPath: "/Library/Input Methods/azooKeyMac.app/Contents/Resources/ggml-model-Q5_K_M.gguf"
                ),
                inferenceLimit: 1,
                personalizationMode: nil,
                versionDependentMode: .v3(
                    .init(leftSideContext: "今日は", maxLeftSideContextLength: 20)
                )
            ),
            typoCorrectionMode: .automatic,
            metadata: .init(versionString: "azooKey iOS benchmark")
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

    @MainActor
    func testDesktopPredictiveInput_Roman2Kana() throws {
        // azooKeyDesktopの既定入力方式（Roman2Kana）で、予測入力を有効にしたまま
        // 1キーずつrequestCandidatesを呼ぶ実利用経路を測る。
        // 通常の辞書予測が効きやすい入力と、Zenzai fallbackへ進みやすい入力を分けて
        // reportし、片方だけの最適化でbenchmarkを通すことを防ぐ。
        let scenarios: [DesktopPredictionScenario] = [
            .init(
                label: "dictionary-friendly",
                leftSideContext: "今日はかな漢字変換について説明します。",
                input: "kanakanjihenkannoseinouwokakuninsuru"
            ),
            .init(
                label: "fallback-heavy",
                leftSideContext: "予測変換、個人的には使う機能になってきたけど、",
                input: "aiueokakikukeko"
            )
        ]
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let profilesLatency = ProcessInfo.processInfo.environment["ZENZAI_PROFILE_LATENCY"] == "1"

        for scenario in scenarios {
            // 各scenarioは独立したDesktop変換セッションとして扱う。結果LRUや
            // predictive input cacheを別scenarioから持ち越さない。
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            let options = self.desktopPredictiveInputOptions(leftSideContext: scenario.leftSideContext)
            var composingText = ComposingText()
            var latencies: [Double]? = profilesLatency ? [] : nil
            var predictionHitCount = 0
            var finalResult: ConversionResult?

            for character in scenario.input {
                composingText.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
                let result = self.measuredRequestCandidates(
                    converter,
                    composingText: composingText,
                    options: options,
                    latencies: &latencies
                )
                if !result.predictionResults.isEmpty {
                    predictionHitCount += 1
                }
                finalResult = result
            }

            XCTAssertFalse(finalResult?.mainResults.isEmpty ?? true)
            XCTAssertGreaterThan(
                predictionHitCount,
                0,
                "Desktop prediction path was not exercised for \(scenario.label)"
            )
            self.reportLatencies(
                latencies,
                label: "DesktopPrediction Roman2Kana \(scenario.label) inferenceLimit=5"
            )
            if profilesLatency {
                print(
                    "[ZenzaiPrediction] Roman2Kana \(scenario.label)"
                        + " requests=\(scenario.input.count)"
                        + " predictionHits=\(predictionHitCount)"
                )
            }
        }
    }

    @MainActor
    func testIOSDirectIncrementalInput() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let options = self.iOSDirectInputOptions()
        let profilesLatency = ProcessInfo.processInfo.environment["ZENZAI_PROFILE_LATENCY"] == "1"
        var latencies: [Double]? = profilesLatency ? [] : nil
        var composingText = ComposingText()
        var finalResult: ConversionResult?

        for character in "かなかんじへんかんをためしています" {
            composingText.insertAtCursorPosition(String(character), inputStyle: .direct)
            finalResult = self.measuredRequestCandidates(
                converter,
                composingText: composingText,
                options: options,
                latencies: &latencies
            )
        }

        XCTAssertFalse(finalResult?.mainResults.isEmpty ?? true)
        self.reportLatencies(latencies, label: "iOS Direct incremental inferenceLimit=1")
        if let latencies {
            print("[ZenzaiIOSDirect] samplesMs=\(latencies)")
        }
    }

    @MainActor
    func testRepeatedCompositionMemoization() throws {
        // 実アプリでは同じKanaKanjiConverterを保持したまま、変換確定ごとに
        // stopComposition()を呼ぶ。純粋なメモ化結果はこの境界を跨いで再利用する
        // 設計なので、iterationごとにconverterを作り直してはいけない。
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let profilesLatency = ProcessInfo.processInfo.environment["ZENZAI_PROFILE_LATENCY"] == "1"
        var latencies: [Double]? = profilesLatency ? [] : nil

        for _ in 1 ... 5 {
            var composingText = ComposingText()
            composingText.insertAtCursorPosition("かなかんじへんかん", inputStyle: .direct)
            let result = self.measuredRequestCandidates(
                converter,
                composingText: composingText,
                options: self.requestOptions(inferenceLimit: 1, leftSideContext: ""),
                latencies: &latencies
            )
            XCTAssertFalse(result.mainResults.isEmpty)
            converter.stopComposition()
        }

        self.reportLatencies(latencies, label: "RepeatedComposition Direct inferenceLimit=1")
        if let latencies {
            print("[ZenzaiMemoization] repeatedComposition samplesMs=\(latencies)")
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
