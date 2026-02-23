#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import Foundation
import SwiftUtils

struct ZenzInputTextGenerator {
    static func generate(
        context: ZenzContext,
        leftSideContext: String,
        composingText: String,
        count: Int,
        minLength: Int = 1,
        maxEntropy: Float?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        possibleNexts: [String] = []
    ) -> String {
        guard count > 0 else {
            return ""
        }
        guard let prompt = ZenzPromptBuilder.inputPredictionPrompt(
            leftSideContext: leftSideContext,
            composingText: composingText,
            versionDependentConfig: versionDependentConfig
        ) else {
            return ""
        }
        let allowedPrefixes: [String] = possibleNexts.filter { !$0.isEmpty }

        @inline(__always)
        func isAllowedPrefix(_ candidate: String) -> Bool {
            guard !allowedPrefixes.isEmpty else {
                return true
            }
            let normalized = candidate.toKatakana()
            return allowedPrefixes.contains(where: {
                $0.hasPrefix(normalized)
            })
        }

        var promptTokens = context.encode(prompt, addBOS: true, addEOS: false)
        let minLength = max(1, min(minLength, count))
        let vocabSize = Int(context.vocabSize)
        let stopCharacters: Set<Character> = ["、", "。", "！", "？"]
        var predictedCharacters: [Character] = []
        predictedCharacters.reserveCapacity(count)
        var predictedText = ""

        for _ in 0..<count {
            let startOffset = promptTokens.count - 1
            guard let logits = context.inputPredictionLogits(tokens: promptTokens, startOffset: startOffset) else {
                debug("logits unavailable")
                break
            }
            let startIndex = (promptTokens.count - 1 - startOffset) * vocabSize
            let endIndex = (promptTokens.count - startOffset) * vocabSize
            let tokenToPenaltyWeight: [llama_token: Float] = promptTokens.indexed().reduce(into: [:]) { dict, item in
                let (index, token) = item
                // 現在位置から遠いほど減衰させる
                dict[token, default: 0] += 2 / Float(promptTokens.count - index)
            }

            var sumexp: Float = 0
            var sumexpX: Float = 0
            var bestValue: Float = -Float.infinity
            var bestCharacter: Character?
            var bestNextText = ""
            for index in startIndex..<endIndex {
                let token = llama_token(index - startIndex)
                let repeatPenalty = Float(1.0 + tokenToPenaltyWeight[token, default: 0])
                let value = logits[index] / repeatPenalty
                let expValue = expf(value)
                sumexp += expValue
                sumexpX += expValue * value
                if value <= bestValue {
                    continue
                }

                let pieceData = Data((context.tokenToPiece(token: token)).map(UInt8.init))
                guard let validCharacter = String(data: pieceData, encoding: .utf8), let c = validCharacter.first else {
                    continue
                }

                let nextText = predictedText + String(c)
                guard isAllowedPrefix(nextText) else {
                    continue
                }

                bestValue = value
                bestCharacter = c
                bestNextText = nextText
            }

            if let maxEntropy, predictedCharacters.count >= minLength, sumexp > 0 {
                let entropy = logf(sumexp) - (sumexpX / sumexp)
                if entropy >= maxEntropy {
                    break
                }
            }

            guard let bestCharacter else {
                break
            }

            if stopCharacters.contains(bestCharacter), predictedCharacters.count >= minLength {
                break
            }

            if !isAllowedPrefix(bestNextText) {
                break
            }

            predictedCharacters.append(bestCharacter)
            predictedText = bestNextText
            let appendedTokens = context.encode(String(bestCharacter), addBOS: false, addEOS: false)
            if appendedTokens.isEmpty {
                break
            }
            promptTokens.append(contentsOf: appendedTokens)
        }

        return String(predictedCharacters)
    }
}
