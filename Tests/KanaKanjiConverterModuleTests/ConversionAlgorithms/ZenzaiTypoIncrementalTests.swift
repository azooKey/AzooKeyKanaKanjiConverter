@testable import KanaKanjiConverterModule
import XCTest

final class ZenzaiTypoIncrementalTests: XCTestCase {
    private func assertEquivalentCandidateRanking(
        _ incremental: [ZenzaiTypoCandidate],
        _ full: [ZenzaiTypoCandidate],
        message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let message = message()
        XCTAssertEqual(
            incremental.map(\.score),
            full.map(\.score),
            "\(message): score ranking differs",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Dictionary(grouping: incremental, by: \.self).mapValues(\.count),
            Dictionary(grouping: full, by: \.self).mapValues(\.count),
            "\(message): candidate contents differ",
            file: file,
            line: line
        )
    }

    private struct DeterministicCharacterContext: ZenzCompatibleInputLanguageModelContext {
        init() {
            var characters: [Character] = []
            var seen: Set<Character> = []
            for character in "?abcdefghijklmnopqrstuvwxyzアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンッャュョー；"
                where seen.insert(character).inserted {
                characters.append(character)
            }
            self.characters = characters
            self.tokenIDs = Dictionary(uniqueKeysWithValues: characters.enumerated().map { ($0.element, $0.offset) })
        }

        let characters: [Character]
        let tokenIDs: [Character: Int]

        var vocabSize: Int { self.characters.count }

        func encodeRaw(_ text: String) -> [Int] {
            text.map { self.tokenIDs[$0, default: 0] }
        }

        func tokenToSingleCharacter(tokenID: Int) -> Character? {
            self.characters.indices.contains(tokenID) ? self.characters[tokenID] : nil
        }

        func nextLogProbs(promptTokenIDs: [Int], emittedTokenIDs: [Int]) -> [Float]? {
            let previous = emittedTokenIDs.last ?? promptTokenIDs.last ?? 0
            return self.characters.indices.map { tokenID in
                -Float((tokenID * 17 + previous * 7 + emittedTokenIDs.count * 13) % 101) / 10
            }
        }
    }

    func testIncrementalCheckpointMatchesFullSearchExactly() {
        let scenarios: [(String, InputStyle)] = [
            ("かなかんじへんかん", .direct),
            ("konobunshou", .roman2kana),
            ("konobjxp", .mapped(id: .defaultAZIK))
        ]
        let context = DeterministicCharacterContext()
        let config = ExperimentalTypoCorrectionConfig(
            languageModel: .zenz,
            beamSize: 8,
            topK: 16,
            nBest: 5
        )

        for (input, inputStyle) in scenarios {
            let incrementalCache = ZenzaiTypoGenerationCache()
            let fullCache = ZenzaiTypoGenerationCache()
            var fullConfig = config
            fullConfig.usesIncrementalCheckpoint = false
            var composingText = ComposingText()
            for character in input {
                composingText.insertAtCursorPosition(String(character), inputStyle: inputStyle)
                let incremental = ZenzaiTypoCandidateGenerator.generate(
                    context: context,
                    leftSideContext: "一致検証",
                    composingText: composingText,
                    inputStyle: inputStyle,
                    experimentalConfig: config,
                    cache: incrementalCache
                )
                let full = ZenzaiTypoCandidateGenerator.generate(
                    context: context,
                    leftSideContext: "一致検証",
                    composingText: composingText,
                    inputStyle: inputStyle,
                    experimentalConfig: fullConfig,
                    cache: fullCache
                )
                // Candidate generation ranks only by score. Candidates with exactly equal scores
                // may therefore exchange positions when Dictionary's randomized iteration order
                // differs between the incremental and full-search caches. Preserve the meaningful
                // contract here: identical score ranks and identical candidate contents, including
                // multiplicity, while allowing permutations only within equal-score ranks.
                self.assertEquivalentCandidateRanking(
                    incremental,
                    full,
                    message: "incremental search diverged for style=\(inputStyle), input=\(String(input.prefix(composingText.input.count)))"
                )
            }
        }
    }
}
