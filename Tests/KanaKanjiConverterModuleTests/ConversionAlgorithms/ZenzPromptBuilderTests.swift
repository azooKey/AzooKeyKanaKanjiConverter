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
        let dictionary = NSObject()
        func key(_ target: String) -> ZenzDraftConversionCacheKey {
            ZenzDraftConversionCacheKey(
                dictionaryIdentifier: ObjectIdentifier(dictionary),
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
