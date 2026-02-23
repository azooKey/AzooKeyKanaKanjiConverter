#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

enum CandidateEvaluationResult: Sendable, Equatable, Hashable {
    case error
    case pass(score: Float, alternativeConstraints: [AlternativeConstraint])
    case fixRequired(prefixConstraint: [UInt8])
    case wholeResult(String)

    struct AlternativeConstraint: Sendable, Equatable, Hashable {
        var probabilityRatio: Float
        var prefixConstraint: [UInt8]
    }
}

struct ZenzCandidateEvaluator {
    static func evaluate(
        context: ZenzContext,
        input: String,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> CandidateEvaluationResult {
        debug("Evaluate", candidate)
        var userDictionaryPrompt = ""
        for item in candidate.data where item.metadata.contains(.isFromUserDictionary) {
            userDictionaryPrompt += "\(item.word)(\(item.ruby.toHiragana()))"
        }
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: input,
            userDictionaryPrompt: userDictionaryPrompt,
            versionDependentConfig: versionDependentConfig
        )
        let normalizedPrompt = context.normalizeForModel(prompt)
        let promptTokens = context.encode(prompt, addBOS: true, addEOS: false)
        defer {
            context.setPreviousEvaluationPromptTokens(promptTokens)
        }
        let prevPrompt = context.previousEvaluationPromptTokens()

        let candidateTokens = context.encode(candidate.text, addBOS: false, addEOS: false)
        let addressedTokens: [llama_token]
        if prevPrompt == promptTokens, !requestRichCandidates {
            var prefix = ""
            for character in candidate.text {
                let newPrefix = prefix + String(character)
                if prefixConstraint.constraint.hasPrefix(newPrefix.utf8) {
                    prefix = newPrefix
                } else {
                    break
                }
            }
            addressedTokens = context.encode(prefix, addBOS: false, addEOS: false)
        } else {
            addressedTokens = []
        }

        let tokens = promptTokens + candidateTokens
        let startOffset = promptTokens.count - 1 + addressedTokens.count
        guard let logits = context.evaluationLogits(tokens: tokens, startOffset: startOffset) else {
            debug("logits unavailable")
            return .error
        }
        let n_vocab = Int(context.vocabSize)
        let isLearnedToken: [(isLearned: Bool, priority: Float)] = Array(repeating: (false, 0), count: promptTokens.count) + candidate.data.flatMap {
            Array(repeating: ($0.metadata.contains(.isLearned), logf(self.learningPriority(data: $0))), count: context.encode($0.word, addBOS: false).count)
        }

        var score: Float = 0

        struct AlternativeHighProbToken: Comparable {
            static func < (lhs: AlternativeHighProbToken, rhs: AlternativeHighProbToken) -> Bool {
                lhs.probabilityRatioToMaxProb < rhs.probabilityRatioToMaxProb
            }

            var token: llama_token
            var constraint: [UInt8]
            var probabilityRatioToMaxProb: Float
        }

        struct TokenAndLogprob: Comparable {
            static func < (lhs: TokenAndLogprob, rhs: TokenAndLogprob) -> Bool {
                lhs.logprob < rhs.logprob
            }
            var token: llama_token
            var logprob: Float
        }

        var altTokens = FixedSizeHeap<AlternativeHighProbToken>(size: requestRichCandidates ? 5 : 0)
        for (i, tokenID) in tokens.indexed().dropFirst(startOffset + 1) {
            var sumexp: Float = 0
            let startIndex = (i - 1 - startOffset) * Int(n_vocab)
            let endIndex = (i - startOffset) * Int(n_vocab)
            var tokenHeap = FixedSizeHeap<TokenAndLogprob>(size: requestRichCandidates ? 3 : 1)
            for index in startIndex ..< endIndex {
                sumexp += expf(logits[index])
            }
            let logsumexp = logf(sumexp)

            if let (mode, baseLM, personalLM) = personalizationMode, mode.alpha > 0 {
                let prefix = tokens[..<i].dropFirst(promptTokens.count).map(Int.init)
                let baseProb: [Float]
                let personalProb: [Float]
                if !prefix.isEmpty {
                    baseProb = baseLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                    personalProb = personalLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                } else {
                    baseProb = Array(repeating: 0, count: Int(n_vocab))
                    personalProb = baseProb
                }
                for (vocabIndex, (lpb, lpp)) in zip(0 ..< Int(n_vocab), zip(baseProb, personalProb)) {
                    let logp = logits[startIndex + vocabIndex] - logsumexp
                    let personalizedLogp = logp + mode.alpha * (lpp - lpb)
                    tokenHeap.insertIfPossible(TokenAndLogprob(token: llama_token(vocabIndex), logprob: personalizedLogp))
                }
            } else {
                for index in startIndex ..< endIndex {
                    let logp = logits[index] - logsumexp
                    tokenHeap.insertIfPossible(TokenAndLogprob(token: llama_token(index - startIndex), logprob: logp))
                }
            }

            guard let maxItem = tokenHeap.max else {
                debug("Max Item could not be found for unknown reason")
                return .error
            }
            if maxItem.token != tokenID {
                if maxItem.token == context.eosToken {
                    let cchars: [CChar] = tokens[..<i].reduce(into: []) {
                        $0.append(contentsOf: context.tokenToPiece(token: $1))
                    }
                    let data = Data(cchars.map { UInt8(bitPattern: $0) })
                    let string = String(data: data, encoding: .utf8) ?? ""
                    let wholeResult = String(string.dropFirst(normalizedPrompt.count))
                    return .wholeResult(wholeResult)
                } else {
                    let actualLogp = logits[startIndex + Int(tokenID)] - logsumexp
                    let preferLearnedToken = isLearnedToken[i].isLearned && actualLogp + isLearnedToken[i].priority > maxItem.logprob
                    if !preferLearnedToken {
                        let cchars = tokens[..<i].reduce(into: []) {
                            $0.append(contentsOf: context.tokenToPiece(token: $1))
                        } + context.tokenToPiece(token: maxItem.token)
                        return .fixRequired(prefixConstraint: cchars.dropFirst(normalizedPrompt.utf8.count).map(UInt8.init))
                    }
                }
            } else if !tokenHeap.isEmpty {
                tokenHeap.removeMax()
                let prefix = tokens[..<i].reduce(into: []) {
                    $0.append(contentsOf: context.tokenToPiece(token: $1))
                }.dropFirst(normalizedPrompt.utf8.count)

                for item in tokenHeap.unordered {
                    altTokens.insertIfPossible(
                        AlternativeHighProbToken(
                            token: item.token,
                            constraint: prefix.map(UInt8.init) + context.tokenToPiece(token: item.token).map(UInt8.init),
                            probabilityRatioToMaxProb: expf(item.logprob - maxItem.logprob)
                        )
                    )
                }
            }
            score += maxItem.logprob
        }
        return .pass(
            score: score,
            alternativeConstraints: altTokens.unordered.sorted(by: >).map {
                .init(probabilityRatio: $0.probabilityRatioToMaxProb, prefixConstraint: $0.constraint)
            }
        )
    }

    private static func learningPriority(data: DicdataElement) -> Float {
        // 文字数の長い候補ほど優先的に適用されるようにする
        // 積極的な複合語化の効果を期待
        if 1 <= data.ruby.count && data.ruby.count <= 4 {
            Float(data.ruby.count + 2)
        } else if 5 <= data.ruby.count && data.ruby.count <= 15 {
            Float(data.ruby.count * 2)
        } else {
            30
        }
    }
}
