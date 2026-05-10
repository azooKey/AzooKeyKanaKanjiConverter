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
}
