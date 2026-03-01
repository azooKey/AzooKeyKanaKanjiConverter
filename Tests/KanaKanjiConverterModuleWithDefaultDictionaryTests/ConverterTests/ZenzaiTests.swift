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
        leftSideContext: String? = nil,
        incrementalTypoEnabled: Bool = false
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
                languageModel: .zenz,
                experimentalZenzaiIncrementalTypoCorrection: incrementalTypoEnabled
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

    @MainActor
    func testTypoCorrection_AfterGradualRequestCandidates_Roman2Kana() throws {
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
        var c = ComposingText()
        let input = "ojsyougozainasu"
        let options = self.requestOptions(
            inferenceLimit: .max,
            leftSideContext: "やあ、",
            incrementalTypoEnabled: true
        )
        var lastResult: ConversionResult?
        for char in input {
            c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
            lastResult = converter.requestCandidates(c, options: options)
        }
        guard let typoCandidates = lastResult?.typoCorrectionResults else {
            XCTFail("typoCorrectionResults should not be nil when incremental typo correction is enabled")
            return
        }
        XCTAssertTrue(
            typoCandidates.contains(where: { $0.correctedInput == "ohayougozaimasu" }),
            "expected ohayougozaimasu in typo candidates, got: \(typoCandidates.map(\.correctedInput))"
        )
    }

    @MainActor
    func testRequestCandidates_AfterGradual_Roman2Kana_NoIncrementalTypo() throws {
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
        var c = ComposingText()
        let input = "ojsyougozainasu"
        let options = self.requestOptions(
            inferenceLimit: .max,
            leftSideContext: "やあ、",
            incrementalTypoEnabled: false
        )
        var lastResult: ConversionResult?
        for char in input {
            c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
            lastResult = converter.requestCandidates(c, options: options)
        }
        XCTAssertNotNil(lastResult)
        XCTAssertNil(lastResult?.typoCorrectionResults)
    }

    @MainActor
    func testTypoCorrection_AfterGradualRequestCandidates_Roman2Kana_InferenceLimit10() throws {
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
        var c = ComposingText()
        let input = "ojsyougozainasu"
        let options = self.requestOptions(
            inferenceLimit: 10,
            leftSideContext: "やあ、",
            incrementalTypoEnabled: true
        )
        var lastResult: ConversionResult?
        for char in input {
            c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
            lastResult = converter.requestCandidates(c, options: options)
        }
        guard let typoCandidates = lastResult?.typoCorrectionResults else {
            XCTFail("typoCorrectionResults should not be nil when incremental typo correction is enabled")
            return
        }
        print("LIMIT10 typo top5:", typoCandidates.prefix(5).map { $0.correctedInput })
        XCTAssertFalse(typoCandidates.isEmpty)
    }

    @MainActor
    func testKVCacheStats_GradualRequestCandidates_Roman2Kana_InferenceLimit10() throws {
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)
        let input = "ojsyougozainasu"
        let leftSideContext = "やあ、"

        func run(incrementalTypoEnabled: Bool) -> ZenzKVCacheStats? {
            let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
            converter.resetDebugZenzKVCacheStats()
            var c = ComposingText()
            let options = self.requestOptions(
                inferenceLimit: 10,
                leftSideContext: leftSideContext,
                incrementalTypoEnabled: incrementalTypoEnabled
            )
            for char in input {
                c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
                _ = converter.requestCandidates(c, options: options)
            }
            return converter.debugZenzKVCacheStatsSnapshot()
        }

        guard let off = run(incrementalTypoEnabled: false),
              let on = run(incrementalTypoEnabled: true) else {
            XCTFail("failed to fetch zenz KV cache stats")
            return
        }

        func ratio(_ numerator: Int, _ denominator: Int) -> Double {
            guard denominator > 0 else { return 0 }
            return Double(numerator) / Double(denominator)
        }
        print(
            "KV_STATS off calls=\(off.logitsCalls) req=\(off.totalRequestedTokens) decoded=\(off.totalDecodedTokens) reused=\(off.totalPrefixReusedTokens) decoded_ratio=\(ratio(off.totalDecodedTokens, off.totalRequestedTokens)) reuse_ratio=\(ratio(off.totalPrefixReusedTokens, off.totalRequestedTokens)) cross_seq_copy=\(off.crossSeqCopyCalls)"
        )
        print(
            "KV_STATS on calls=\(on.logitsCalls) req=\(on.totalRequestedTokens) decoded=\(on.totalDecodedTokens) reused=\(on.totalPrefixReusedTokens) decoded_ratio=\(ratio(on.totalDecodedTokens, on.totalRequestedTokens)) reuse_ratio=\(ratio(on.totalPrefixReusedTokens, on.totalRequestedTokens)) cross_seq_copy=\(on.crossSeqCopyCalls)"
        )
        XCTAssertGreaterThan(on.logitsCalls, off.logitsCalls)
    }

    @MainActor
    private func measureRequestCandidatesStepTimes(
        input: String,
        leftSideContext: String,
        dicdataStore: DicdataStore,
        incrementalTypoEnabled: Bool,
        inferenceLimit: Int = .max
    ) -> [Double] {
        let converter = KanaKanjiConverter(dicdataStore: dicdataStore)
        var c = ComposingText()
        let options = self.requestOptions(
            inferenceLimit: inferenceLimit,
            leftSideContext: leftSideContext,
            incrementalTypoEnabled: incrementalTypoEnabled
        )
        var times: [Double] = []
        for char in input {
            c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
            let start = Date()
            _ = converter.requestCandidates(c, options: options)
            times.append(-start.timeIntervalSinceNow)
        }
        return times
    }

    @MainActor
    func testRequestCandidatesStepLatencyReport_IncrementalTypoOnOff_Roman2Kana() throws {
        let input = "ojsyougozainasu"
        let leftSideContext = "やあ、"
        let repeats = 10
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)

        var offRuns: [[Double]] = []
        var onRuns: [[Double]] = []

        for run in 1 ... repeats {
            if run.isMultiple(of: 2) {
                let on = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: true,
                    inferenceLimit: .max
                )
                let off = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: false,
                    inferenceLimit: .max
                )
                onRuns.append(on)
                offRuns.append(off)
            } else {
                let off = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: false,
                    inferenceLimit: .max
                )
                let on = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: true,
                    inferenceLimit: .max
                )
                offRuns.append(off)
                onRuns.append(on)
            }
        }

        XCTAssertEqual(offRuns.count, repeats)
        XCTAssertEqual(onRuns.count, repeats)
        XCTAssertTrue(offRuns.allSatisfy { $0.count == input.count })
        XCTAssertTrue(onRuns.allSatisfy { $0.count == input.count })

        var rawLines: [String] = []
        rawLines.reserveCapacity(1 + repeats * input.count * 2)
        rawLines.append("mode\trun\tstep\telapsed")
        for run in 1 ... repeats {
            for step in 1 ... input.count {
                rawLines.append("off\t\(run)\t\(step)\t\(offRuns[run - 1][step - 1])")
                rawLines.append("on\t\(run)\t\(step)\t\(onRuns[run - 1][step - 1])")
            }
        }

        func mean(_ values: [Double]) -> Double {
            values.reduce(0, +) / Double(values.count)
        }
        func sampleStd(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let avg = mean(values)
            let variance = values.reduce(0) { partial, value in
                let diff = value - avg
                return partial + diff * diff
            } / Double(values.count - 1)
            return sqrt(variance)
        }

        var summaryLines: [String] = []
        summaryLines.append("step\toff_mean\ton_mean\tdelta\toff_std\ton_std\tratio")
        var allOff: [Double] = []
        var allOn: [Double] = []
        var warmOff: [Double] = []
        var warmOn: [Double] = []
        allOff.reserveCapacity(repeats * input.count)
        allOn.reserveCapacity(repeats * input.count)
        warmOff.reserveCapacity(repeats * max(input.count - 1, 0))
        warmOn.reserveCapacity(repeats * max(input.count - 1, 0))

        for step in 1 ... input.count {
            let offValues = offRuns.map {$0[step - 1]}
            let onValues = onRuns.map {$0[step - 1]}
            let offMean = mean(offValues)
            let onMean = mean(onValues)
            let delta = onMean - offMean
            let ratio = onMean / offMean
            summaryLines.append(
                "\(step)\t\(offMean)\t\(onMean)\t\(delta)\t\(sampleStd(offValues))\t\(sampleStd(onValues))\t\(ratio)"
            )
            allOff.append(contentsOf: offValues)
            allOn.append(contentsOf: onValues)
            if step >= 2 {
                warmOff.append(contentsOf: offValues)
                warmOn.append(contentsOf: onValues)
            }
        }

        let allOffMean = mean(allOff)
        let allOnMean = mean(allOn)
        summaryLines.append(
            "ALL\t\(allOffMean)\t\(allOnMean)\t\(allOnMean - allOffMean)\t\(sampleStd(allOff))\t\(sampleStd(allOn))\t\(allOnMean / allOffMean)"
        )
        let warmOffMean = mean(warmOff)
        let warmOnMean = mean(warmOn)
        summaryLines.append(
            "WARM(step>=2)\t\(warmOffMean)\t\(warmOnMean)\t\(warmOnMean - warmOffMean)\t\(sampleStd(warmOff))\t\(sampleStd(warmOn))\t\(warmOnMean / warmOffMean)"
        )

        let rawURL = URL(fileURLWithPath: "/tmp/zenzai_step_latency_raw.tsv")
        let summaryURL = URL(fileURLWithPath: "/tmp/zenzai_step_latency_summary.tsv")
        try rawLines.joined(separator: "\n").write(to: rawURL, atomically: true, encoding: .utf8)
        try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
        print("BENCH_OUTPUT raw=\(rawURL.path) summary=\(summaryURL.path)")
    }

    @MainActor
    func testRequestCandidatesStepLatencyReport_IncrementalTypoOnOff_Roman2Kana_InferenceLimit10() throws {
        let input = "ojsyougozainasu"
        let leftSideContext = "やあ、"
        let repeats = 10
        let dicdataStore = DicdataStore.withDefaultDictionary(preloadDictionary: true)

        var offRuns: [[Double]] = []
        var onRuns: [[Double]] = []

        for run in 1 ... repeats {
            if run.isMultiple(of: 2) {
                let on = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: true,
                    inferenceLimit: 10
                )
                let off = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: false,
                    inferenceLimit: 10
                )
                onRuns.append(on)
                offRuns.append(off)
            } else {
                let off = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: false,
                    inferenceLimit: 10
                )
                let on = self.measureRequestCandidatesStepTimes(
                    input: input,
                    leftSideContext: leftSideContext,
                    dicdataStore: dicdataStore,
                    incrementalTypoEnabled: true,
                    inferenceLimit: 10
                )
                offRuns.append(off)
                onRuns.append(on)
            }
        }

        XCTAssertEqual(offRuns.count, repeats)
        XCTAssertEqual(onRuns.count, repeats)
        XCTAssertTrue(offRuns.allSatisfy { $0.count == input.count })
        XCTAssertTrue(onRuns.allSatisfy { $0.count == input.count })

        var rawLines: [String] = []
        rawLines.reserveCapacity(1 + repeats * input.count * 2)
        rawLines.append("mode\trun\tstep\telapsed")
        for run in 1 ... repeats {
            for step in 1 ... input.count {
                rawLines.append("off\t\(run)\t\(step)\t\(offRuns[run - 1][step - 1])")
                rawLines.append("on\t\(run)\t\(step)\t\(onRuns[run - 1][step - 1])")
            }
        }

        func mean(_ values: [Double]) -> Double {
            values.reduce(0, +) / Double(values.count)
        }
        func sampleStd(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let avg = mean(values)
            let variance = values.reduce(0) { partial, value in
                let diff = value - avg
                return partial + diff * diff
            } / Double(values.count - 1)
            return sqrt(variance)
        }

        var summaryLines: [String] = []
        summaryLines.append("step\toff_mean\ton_mean\tdelta\toff_std\ton_std\tratio")
        var allOff: [Double] = []
        var allOn: [Double] = []
        var warmOff: [Double] = []
        var warmOn: [Double] = []
        allOff.reserveCapacity(repeats * input.count)
        allOn.reserveCapacity(repeats * input.count)
        warmOff.reserveCapacity(repeats * max(input.count - 1, 0))
        warmOn.reserveCapacity(repeats * max(input.count - 1, 0))

        for step in 1 ... input.count {
            let offValues = offRuns.map {$0[step - 1]}
            let onValues = onRuns.map {$0[step - 1]}
            let offMean = mean(offValues)
            let onMean = mean(onValues)
            let delta = onMean - offMean
            let ratio = onMean / offMean
            summaryLines.append(
                "\(step)\t\(offMean)\t\(onMean)\t\(delta)\t\(sampleStd(offValues))\t\(sampleStd(onValues))\t\(ratio)"
            )
            allOff.append(contentsOf: offValues)
            allOn.append(contentsOf: onValues)
            if step >= 2 {
                warmOff.append(contentsOf: offValues)
                warmOn.append(contentsOf: onValues)
            }
        }

        let allOffMean = mean(allOff)
        let allOnMean = mean(allOn)
        summaryLines.append(
            "ALL\t\(allOffMean)\t\(allOnMean)\t\(allOnMean - allOffMean)\t\(sampleStd(allOff))\t\(sampleStd(allOn))\t\(allOnMean / allOffMean)"
        )
        let warmOffMean = mean(warmOff)
        let warmOnMean = mean(warmOn)
        summaryLines.append(
            "WARM(step>=2)\t\(warmOffMean)\t\(warmOnMean)\t\(warmOnMean - warmOffMean)\t\(sampleStd(warmOff))\t\(sampleStd(warmOn))\t\(warmOnMean / warmOffMean)"
        )

        let rawURL = URL(fileURLWithPath: "/tmp/zenzai_step_latency_raw_limit10.tsv")
        let summaryURL = URL(fileURLWithPath: "/tmp/zenzai_step_latency_summary_limit10.tsv")
        try rawLines.joined(separator: "\n").write(to: rawURL, atomically: true, encoding: .utf8)
        try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
        print("BENCH_OUTPUT_LIMIT10 raw=\(rawURL.path) summary=\(summaryURL.path)")
    }
}
#endif
