import Foundation
@testable import KanaKanjiConverterModule
import SwiftUtils
import XCTest

final class PredictiveInputCacheTests: XCTestCase {
    private func makeCandidate(text: String) -> Candidate {
        Candidate(
            text: text,
            value: 0,
            composingCount: .surfaceCount(text.count),
            lastMid: MIDData.一般.mid,
            data: [.init(word: text, ruby: text.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)]
        )
    }

    func testRemainingPredictionReturnsUnconsumedSuffix() {
        let entry = PredictiveInputCacheEntry(
            context: .init(
                leftSideContext: "左文脈",
                inputStyle: .direct,
                weightURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                versionDependentConfig: .v3(.init(topic: "swift"))
            ),
            originalConvertTarget: "あ",
            suffixCount: 0,
            predictedText: "いうえお"
        )

        XCTAssertEqual(entry.remainingPrediction(currentConvertTarget: "あい", count: 10), "うえお")
        XCTAssertEqual(entry.remainingPrediction(currentConvertTarget: "あいう", count: 1), "え")
    }

    func testRemainingPredictionHandlesRoman2KanaInsertion() {
        let entry = PredictiveInputCacheEntry(
            context: .init(
                leftSideContext: "",
                inputStyle: .roman2kana,
                weightURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                versionDependentConfig: .v3(.init())
            ),
            originalConvertTarget: "k",
            suffixCount: 1,
            predictedText: "カナ"
        )

        XCTAssertEqual(entry.remainingPrediction(currentConvertTarget: "か", count: 10), "ナ")
        XCTAssertEqual(entry.remainingPrediction(currentConvertTarget: "かな", count: 10), nil)
    }

    func testRemainingPredictionReturnsNilWhenCurrentInputDiverges() {
        let entry = PredictiveInputCacheEntry(
            context: .init(
                leftSideContext: "",
                inputStyle: .direct,
                weightURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                versionDependentConfig: .v3(.init(profile: "dev"))
            ),
            originalConvertTarget: "あ",
            suffixCount: 0,
            predictedText: "いう"
        )

        XCTAssertNil(entry.remainingPrediction(currentConvertTarget: "あか", count: 10))
        XCTAssertNil(entry.remainingPrediction(currentConvertTarget: "い", count: 10))
    }

    func testStablePredictionCandidateCacheKeepsPrefixCompatibleCandidates() {
        let entry = StablePredictionCandidateCacheEntry(
            originalConvertTarget: "あいうえおかきくk",
            suffixCount: 1,
            candidates: [
                self.makeCandidate(text: "あいうえおかきくけこ"),
                self.makeCandidate(text: "あいうえおかきくけど"),
                self.makeCandidate(text: "別候補")
            ]
        )

        XCTAssertEqual(
            entry.compatibleCandidates(
                currentConvertTarget: "あいうえおかきくけ",
                baseConvertTarget: "あいうえおかきくけ",
                possibleNexts: []
            ).map(\.text),
            ["あいうえおかきくけこ", "あいうえおかきくけど"]
        )
    }

    func testStablePredictionCandidateCacheUsesPossibleNextsForRomanSuffix() {
        let entry = StablePredictionCandidateCacheEntry(
            originalConvertTarget: "あいうえおかきくけ",
            suffixCount: 0,
            candidates: [
                self.makeCandidate(text: "あいうえおかきくけこ"),
                self.makeCandidate(text: "あいうえおかきくけど")
            ]
        )

        XCTAssertEqual(
            entry.compatibleCandidates(
                currentConvertTarget: "あいうえおかきくけk",
                baseConvertTarget: "あいうえおかきくけ",
                possibleNexts: ["こ", "か"]
            ).map(\.text),
            ["あいうえおかきくけこ"]
        )
    }

    func testStablePredictionCandidateCacheUpdatesComposingCountForGrownDirectInput() {
        let entry = StablePredictionCandidateCacheEntry(
            originalConvertTarget: "おはよ",
            suffixCount: 0,
            candidates: [
                Candidate(
                    text: "おはようございます",
                    value: 0,
                    composingCount: .surfaceCount(3),
                    lastMid: MIDData.一般.mid,
                    data: [.init(word: "おはようございます", ruby: "オハヨウゴザイマス", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: 0)]
                )
            ]
        )

        let candidates = entry.compatibleCandidates(
            currentConvertTarget: "おはよう",
            baseConvertTarget: "おはよう",
            possibleNexts: []
        )

        XCTAssertEqual(candidates.map(\.text), ["おはようございます"])
        XCTAssertEqual(candidates.first?.composingCount, .surfaceCount(4))
    }
}
