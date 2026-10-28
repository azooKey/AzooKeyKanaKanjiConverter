@testable import KanaKanjiConverterModule
import XCTest

final class ZenzPromptBuilderTests: XCTestCase {
    func testTypoCorrectionPromptPrefixWithoutLeftContextUsesOnlyInputTag() {
        let prompt = ZenzPromptBuilder.typoCorrectionPromptPrefix(leftSideContext: "")
        XCTAssertEqual(prompt, "\u{EE00}")
    }

    func testInputPredictionPromptV3BuildsPromptWithConditionsAndTrimmedContext() {
        let mode = ConvertRequestOptions.ZenzaiV3DependentMode(
            profile: "profile",
            topic: "topic",
            style: "style",
            preference: "preference",
            leftSideContext: nil,
            rightSideContext: "uvwxyz",
            maxLeftSideContextLength: 2,
            maxRightSideContextLength: 3
        )
        let prompt = ZenzPromptBuilder.inputPredictionPrompt(
            leftSideContext: "abcdef",
            composingText: "かんじ",
            versionDependentConfig: .v3(mode)
        )

        XCTAssertEqual(
            prompt,
            "\u{EE03}profile\u{EE04}topic\u{EE05}style\u{EE06}preference\u{EE02}ef\u{EE07}uvw\u{EE00}カンジ"
        )
    }

    func testCandidateEvaluationPromptV3BuildsPromptWithRightContextWithoutLeftContext() {
        let mode = ConvertRequestOptions.ZenzaiV3DependentMode(
            rightSideContext: "abcdef",
            maxRightSideContextLength: 2
        )
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: "ハシ",
            userDictionaryPrompt: "",
            versionDependentConfig: .v3(mode)
        )

        XCTAssertEqual(
            prompt,
            "\u{EE07}ab\u{EE00}ハシ\u{EE01}"
        )
    }

    func testCandidateEvaluationPromptV3DoesNotInsertAlignmentSeparatorByDefault() {
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: "ハシ",
            inputCursorPosition: 1,
            userDictionaryPrompt: "",
            versionDependentConfig: .v3(.init())
        )

        XCTAssertEqual(
            prompt,
            "\u{EE00}ハシ\u{EE01}"
        )
    }

    func testCandidateEvaluationPromptV3InsertsAlignmentSeparatorAtCursorWhenEnabled() {
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: "ハシ",
            inputCursorPosition: 1,
            userDictionaryPrompt: "",
            versionDependentConfig: .v3(.init(enableAlignmentSeparator: true))
        )

        XCTAssertEqual(
            prompt,
            "\u{EE00}ハ\u{EE08}シ\u{EE01}"
        )
    }

    func testCandidateEvaluationPromptV2IgnoresAlignmentCursor() {
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: "ハシ",
            inputCursorPosition: 1,
            userDictionaryPrompt: "",
            versionDependentConfig: .v2(.init())
        )

        XCTAssertEqual(
            prompt,
            "\u{EE00}ハシ\u{EE01}"
        )
    }

    func testCandidateEvaluationPromptV2BuildsPromptWithDictionaryAndProfile() {
        let mode = ConvertRequestOptions.ZenzaiV2DependentMode(
            profile: "profile",
            leftSideContext: "abcdef",
            maxLeftSideContextLength: 3
        )
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: "ヘンカン",
            userDictionaryPrompt: "単語(たんご)",
            versionDependentConfig: .v2(mode)
        )

        XCTAssertEqual(
            prompt,
            "\u{EE00}ヘンカン\u{EE02}辞書:単語(たんご)・プロフィール:profile・発言:def\u{EE01}"
        )
    }

    func testCandidateEvaluationPromptV3OmitsDictionary() {
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: "ヘンカン",
            userDictionaryPrompt: "単語(たんご)",
            versionDependentConfig: .v3(.init(profile: "profile"))
        )

        XCTAssertEqual(
            prompt,
            "\u{EE03}profile\u{EE00}ヘンカン\u{EE01}"
        )
    }

    func testCandidateTextForEvaluationV3DoesNotAppendAlignmentSeparatorByDefault() {
        let text = ZenzCandidateEvaluator.candidateTextForEvaluation(
            candidateText: "葉",
            input: "ハシ",
            inputCursorPosition: 1,
            versionDependentConfig: .v3(.init())
        )

        XCTAssertEqual(text, "葉")
    }

    func testCandidateTextForEvaluationV3AppendsAlignmentSeparatorWhenEnabled() {
        let text = ZenzCandidateEvaluator.candidateTextForEvaluation(
            candidateText: "葉",
            input: "ハシ",
            inputCursorPosition: 1,
            versionDependentConfig: .v3(.init(enableAlignmentSeparator: true))
        )

        XCTAssertEqual(text, "葉\u{EE08}")
    }

    func testDroppingFixedDataKeepsElementCrossingFixedBoundary() {
        let crossingElement = DicdataElement(
            word: "←の",
            ruby: "ヒダリノ",
            cid: CIDData.一般名詞.cid,
            mid: MIDData.一般.mid,
            value: 0,
            metadata: .isFromUserDictionary
        )
        let trailingElement = DicdataElement(
            word: "候補",
            ruby: "コウホ",
            cid: CIDData.一般名詞.cid,
            mid: MIDData.一般.mid,
            value: 0
        )

        let result = ZenzCandidateEvaluator.droppingFixedData(
            [crossingElement, trailingElement],
            byteCount: "←".utf8.count
        )

        XCTAssertEqual(result, [crossingElement, trailingElement])
    }

    func testDroppingFixedDataDropsElementsCoveredByFixedPrefix() {
        let fixedElement = DicdataElement(
            word: "←",
            ruby: "ヒダリ",
            cid: CIDData.一般名詞.cid,
            mid: MIDData.一般.mid,
            value: 0
        )
        let trailingElement = DicdataElement(
            word: "の",
            ruby: "ノ",
            cid: CIDData.一般名詞.cid,
            mid: MIDData.一般.mid,
            value: 0
        )

        let result = ZenzCandidateEvaluator.droppingFixedData(
            [fixedElement, trailingElement],
            byteCount: "←".utf8.count
        )

        XCTAssertEqual(result, [trailingElement])
    }

    func testUserWordContinuationsMarksTokensInsideUserWords() {
        let userWord = DicdataElement(
            word: "桐谷奏",
            ruby: "キリタニカナデ",
            cid: CIDData.固有名詞.cid,
            mid: MIDData.一般.mid,
            value: 0,
            metadata: .isFromUserDictionary
        )
        let learnedWord = DicdataElement(
            word: "莉央",
            ruby: "リオ",
            cid: CIDData.固有名詞.cid,
            mid: MIDData.一般.mid,
            value: 0,
            metadata: .isLearned
        )
        let trailingElement = DicdataElement(
            word: "と",
            ruby: "ト",
            cid: CIDData.一般名詞.cid,
            mid: MIDData.一般.mid,
            value: 0
        )

        // 桐 / 谷奏 / と / 莉 / 央
        let result = ZenzCandidateEvaluator.userWordContinuations(
            data: [userWord, trailingElement, learnedWord],
            text: "桐谷奏と莉央",
            tokenByteCounts: [3, 6, 3, 3, 3],
            normalize: { $0 }
        )
        XCTAssertEqual(result, [false, true, false, false, true])

        // 単語の表記を連結したものが候補の表記と一致しない場合は判定しない
        let mismatched = ZenzCandidateEvaluator.userWordContinuations(
            data: [userWord],
            text: "←桐谷奏",
            tokenByteCounts: [3, 3, 6],
            normalize: { $0 }
        )
        XCTAssertEqual(mismatched, [false, false, false])
    }

    func testZenzaiLatticeInputDataUsesPrefixForNonEndCursor() {
        let input = ComposingText(
            convertTargetCursorPosition: 1,
            input: [
                .init(character: "は", inputStyle: .direct),
                .init(character: "し", inputStyle: .direct)
            ],
            convertTarget: "はし"
        )

        let latticeInput = Kana2Kanji.zenzaiLatticeInputData(for: input)

        XCTAssertEqual(latticeInput.convertTarget, "は")
        XCTAssertEqual(latticeInput.convertTargetCursorPosition, 1)
        XCTAssertEqual(Kana2Kanji.zenzaiInputCursorPosition(for: input), 1)
    }

    func testZenzConstraintWithAlignmentSeparatorBecomesEOSPrefixConstraint() {
        let constraint = Kana2Kanji.normalizedZenzConstraint(
            Array("橋\u{EE08}".utf8),
            defaultHasEOS: false,
            ignoreMemoryAndUserDictionary: true
        )

        XCTAssertEqual(constraint, Kana2Kanji.PrefixConstraint(Array("橋".utf8), hasEOS: true, ignoreMemoryAndUserDictionary: true))
    }

    func testZenzEvaluationCacheEvictsLeastRecentlyUsedEntry() {
        let cache = ZenzEvaluationCache(capacity: 2)
        func key(_ prompt: String) -> ZenzEvaluationCacheKey {
            ZenzEvaluationCacheKey(
                prompt: prompt,
                candidateTextForEvaluation: "候補",
                originalCandidateText: "候補",
                prefixConstraint: .init([]),
                requestRichCandidates: false,
                reusesAddressedPrefix: false,
                candidateSegments: [.init(word: "候補", ruby: "コウホ", isLearned: false)]
            )
        }
        let first = key("first")
        let second = key("second")
        let third = key("third")

        cache.insert(.wholeResult("first"), for: first)
        cache.insert(.wholeResult("second"), for: second)
        XCTAssertEqual(cache.value(for: first), .wholeResult("first"))

        cache.insert(.wholeResult("third"), for: third)

        XCTAssertNil(cache.value(for: second))
        XCTAssertEqual(cache.value(for: first), .wholeResult("first"))
        XCTAssertEqual(cache.value(for: third), .wholeResult("third"))
    }

    func testZenzDraftConversionCacheEvictsLeastRecentlyUsedEntry() {
        let cache = ZenzDraftConversionCache(capacity: 2)
        func key(_ target: String) -> ZenzDraftConversionCacheKey {
            ZenzDraftConversionCacheKey(
                input: [],
                convertTarget: target,
                convertTargetCursorPosition: nil,
                keyboardLanguage: .ja_JP,
                versionDependentConfig: .v3(.init()),
                prefixConstraint: .init([])
            )
        }
        let value = ZenzDraftConversion(
            resultPrevs: [],
            resultLatticeHead: .init(nodes: [])
        )
        let first = key("first")
        let second = key("second")
        let third = key("third")

        cache.insert(value, for: first)
        cache.insert(value, for: second)
        XCTAssertNotNil(cache.value(for: first))

        cache.insert(value, for: third)

        XCTAssertNil(cache.value(for: second))
        XCTAssertNotNil(cache.value(for: first))
        XCTAssertNotNil(cache.value(for: third))
    }

    func testZenzaiMemoizationCachesDoNotShareEntries() {
        let firstCache = ZenzaiMemoizationCache()
        let secondCache = ZenzaiMemoizationCache()
        let evaluationKey = ZenzEvaluationCacheKey(
            prompt: "prompt",
            candidateTextForEvaluation: "候補",
            originalCandidateText: "候補",
            prefixConstraint: .init([]),
            requestRichCandidates: false,
            reusesAddressedPrefix: false,
            candidateSegments: [.init(word: "候補", ruby: "コウホ", isLearned: false)]
        )
        let draftKey = ZenzDraftConversionCacheKey(
            input: [],
            convertTarget: "こうほ",
            convertTargetCursorPosition: nil,
            keyboardLanguage: .ja_JP,
            versionDependentConfig: .v3(.init()),
            prefixConstraint: .init([])
        )
        let resolvedKey = ZenzResolvedConversionCacheKey(
            input: [],
            convertTarget: "こうほ",
            convertTargetCursorPosition: nil,
            keyboardLanguage: .ja_JP,
            versionDependentConfig: .v3(.init()),
            prefixConstraint: .init([]),
            inferenceLimit: 1
        )
        let latticeHead = ZenzResolvedLatticeHead(nodes: [])
        let draft = ZenzDraftConversion(resultPrevs: [], resultLatticeHead: latticeHead)
        let candidate = Candidate(
            text: "候補",
            value: 0,
            composingCount: .inputCount(0),
            lastMid: 0,
            data: []
        )
        let resolved = ZenzResolvedConversion(
            resultPrevs: [],
            resultLatticeHead: latticeHead,
            prefixConstraint: .init([]),
            satisfyingCandidate: candidate
        )

        firstCache.cacheEvaluation(.wholeResult("cached"), for: evaluationKey)
        firstCache.cacheDraftConversion(draft, for: draftKey)
        firstCache.cacheResolvedConversion(resolved, for: resolvedKey)
        firstCache.cacheEvaluationPromptTokens([1, 2, 3], for: "prompt")

        XCTAssertEqual(
            firstCache.cachedEvaluation(for: evaluationKey),
            .wholeResult("cached")
        )
        XCTAssertNotNil(firstCache.cachedDraftConversion(for: draftKey))
        XCTAssertNotNil(firstCache.cachedResolvedConversion(for: resolvedKey))
        XCTAssertEqual(firstCache.cachedEvaluationPromptTokens(for: "prompt"), [1, 2, 3])
        XCTAssertNil(secondCache.cachedEvaluation(for: evaluationKey))
        XCTAssertNil(secondCache.cachedDraftConversion(for: draftKey))
        XCTAssertNil(secondCache.cachedResolvedConversion(for: resolvedKey))
        XCTAssertNil(secondCache.cachedEvaluationPromptTokens(for: "prompt"))
    }

    func testZenzaiMemoizationCacheSurvivesStopComposition() {
        let converter = KanaKanjiConverter.withoutDictionary()
        let cache = converter.zenzaiMemoizationCache

        converter.stopComposition()

        XCTAssertTrue(cache === converter.zenzaiMemoizationCache)
    }

    func testZenzaiMemoizationCacheIsScopedToConverterAndCanBePurged() {
        let firstConverter = KanaKanjiConverter.withoutDictionary()
        let secondConverter = KanaKanjiConverter.withoutDictionary()
        let originalCache = firstConverter.zenzaiMemoizationCache

        XCTAssertFalse(originalCache === secondConverter.zenzaiMemoizationCache)

        firstConverter.purgeZenzaiMemoizationCache()

        XCTAssertFalse(originalCache === firstConverter.zenzaiMemoizationCache)
    }

    func testZenzInferenceThreadCountUsesPerformanceClusterOnDarwin() {
        XCTAssertEqual(
            ZenzContext.selectInferenceThreadCount(
                activeProcessorCount: 10,
                performanceCoreCount: 6
            ),
            6
        )
    }

    func testZenzInferenceThreadCountFallsBackWhenPerformanceClusterIsUnavailable() {
        XCTAssertEqual(
            ZenzContext.selectInferenceThreadCount(
                activeProcessorCount: 8,
                performanceCoreCount: nil
            ),
            6
        )
        XCTAssertEqual(
            ZenzContext.selectInferenceThreadCount(
                activeProcessorCount: 2,
                performanceCoreCount: nil
            ),
            2
        )
    }
}
