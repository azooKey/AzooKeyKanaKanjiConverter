#if ZenzaiCoreML && canImport(CoreML)

import Algorithms
import EfficientNGram
import Foundation
import HeapModule
import SwiftUtils
import ZenzCoreMLBackend
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@available(iOS 18.0, macOS 15.0, *)
final class ZenzContext: ZenzContextProtocol {
    private let generator: ZenzStateful8BitGenerator
    private let tokenizer = ZenzTokenizer()
    private var prevInput: [Int] = []
    private var prevPrompt: [Int] = []
    private let n_len: Int32 = 512

    private init(generator: ZenzStateful8BitGenerator) {
        self.generator = generator
    }

    static func createContext(path _: String) async throws -> ZenzContext {
        let generator = try await ZenzStateful8BitGenerator()
        return ZenzContext(generator: generator)
    }

    deinit {
        Task {
            await self.generator.resetState()
        }
    }

    func reset_context() async throws {
        try await self.generator.resetState()
        self.prevInput = []
        self.prevPrompt = []
    }

    func evaluate_candidate(
        input: String,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) async -> ZenzCandidateEvaluationResult {
        debug("Evaluate", candidate)
        let prompt = ZenzPromptBuilder.buildPrompt(
            convertTarget: input,
            candidate: candidate,
            versionDependentConfig: versionDependentConfig
        )
        let prompt_tokens = self.tokenize(text: prompt, add_bos: true, add_eos: false)
        defer {
            self.prevPrompt = prompt_tokens
        }

        let candidate_tokens = self.tokenize(text: ZenzPromptBuilder.preprocess(candidate.text), add_bos: false, add_eos: false)
        let addressed_tokens: [Int]
        if self.prevPrompt == prompt_tokens, !requestRichCandidates {
            var string = ""
            for character in candidate.text {
                let newString = string + String(character)
                if prefixConstraint.constraint.hasPrefix(newString.utf8) {
                    string = newString
                } else {
                    break
                }
            }
            addressed_tokens = self.tokenize(text: ZenzPromptBuilder.preprocess(string), add_bos: false, add_eos: false)
        } else {
            addressed_tokens = []
        }

        let tokens = prompt_tokens + candidate_tokens
        let startOffset = prompt_tokens.count - 1 + addressed_tokens.count
        guard let logitsResult = await self.get_logits(tokens: tokens) else {
            debug("logits unavailable")
            return .error
        }
        let logits = logitsResult.values
        let n_vocab = logitsResult.vocabSize

        let is_learned_token: [(isLearned: Bool, priority: Float)] = Array(repeating: (false, 0), count: prompt_tokens.count) + candidate.data.flatMap {
            Array(repeating: ($0.metadata.contains(.isLearned), logf(getLearningPriority(data: $0))), count: self.tokenize(text: $0.word, add_bos: false).count)
        }

        var score: Float = 0

        struct AlternativeHighProbToken: Comparable {
            static func < (lhs: AlternativeHighProbToken, rhs: AlternativeHighProbToken) -> Bool {
                lhs.probabilityRatioToMaxProb < rhs.probabilityRatioToMaxProb
            }

            var token: Int
            var constraint: [UInt8]
            var probabilityRatioToMaxProb: Float
        }

        var altTokens = FixedSizeHeap<AlternativeHighProbToken>(size: requestRichCandidates ? 5 : 0)
        for (i, token_id) in tokens.indexed().dropFirst(startOffset + 1) {
            struct TokenAndLogprob: Comparable {
                static func < (lhs: TokenAndLogprob, rhs: TokenAndLogprob) -> Bool {
                    lhs.logprob < rhs.logprob
                }
                var token: Int
                var logprob: Float
            }
            var sumexp: Float = 0
            let startIndex = (i - 1 - startOffset) * n_vocab
            let endIndex = (i - startOffset) * n_vocab
            var tokenHeap = FixedSizeHeap<TokenAndLogprob>(size: requestRichCandidates ? 3 : 1)
            for index in startIndex..<endIndex {
                sumexp += expf(logits[index])
            }
            let logsumexp = logf(sumexp)

            if let personalization = personalizationMode, personalization.mode.alpha > 0 {
                let prefix = Array(tokens[..<i].dropFirst(prompt_tokens.count))
                let baseProb: [Float]
                let personalProb: [Float]
                if !prefix.isEmpty {
                    baseProb = personalization.base.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                    personalProb = personalization.personal.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                } else {
                    baseProb = Array(repeating: 0, count: n_vocab)
                    personalProb = baseProb
                }
                for offset in 0..<n_vocab {
                    let logp = logits[startIndex + offset] - logsumexp
                    let logp_ = logp + personalization.mode.alpha * (personalProb[offset] - baseProb[offset])
                    tokenHeap.insertIfPossible(TokenAndLogprob(token: offset, logprob: logp_))
                }
            } else {
                for offset in 0..<n_vocab {
                    let logp = logits[startIndex + offset] - logsumexp
                    tokenHeap.insertIfPossible(TokenAndLogprob(token: offset, logprob: logp))
                }
            }

            guard let maxItem = tokenHeap.max else {
                debug("Max Item could not be found for unknown reason")
                return .error
            }

            if maxItem.token != token_id {
                if maxItem.token == tokenizer.endTokenID {
                    let cchars: [CChar] = tokens[..<i].reduce(into: []) {
                        $0.append(contentsOf: token_to_cchars(token: $1))
                    }
                    let data = Data(cchars.map { UInt8(bitPattern: $0) })
                    let string: String = String(data: data, encoding: .utf8) ?? ""
                    let wholeResult = String(string.dropFirst(prompt.count))
                    return .wholeResult(wholeResult)
                } else {
                    let actual_logp: Float = logits[startIndex + token_id] - logsumexp
                    let candidateIndex = i - prompt_tokens.count
                    let preferLearnedToken = is_learned_token.indices.contains(candidateIndex) &&
                        is_learned_token[candidateIndex].isLearned &&
                        actual_logp + is_learned_token[candidateIndex].priority > maxItem.logprob
                    if !preferLearnedToken {
                        let cchars = tokens[..<i].reduce(into: []) {
                            $0.append(contentsOf: token_to_cchars(token: $1))
                        } + token_to_cchars(token: maxItem.token)
                        let constraint = cchars.dropFirst(prompt.utf8.count).map { UInt8(bitPattern: $0) }
                        return .fixRequired(prefixConstraint: constraint)
                    }
                }
            } else if !tokenHeap.isEmpty {
                tokenHeap.removeMax()
                let prefixBytes = tokens[..<i].reduce(into: [UInt8]()) {
                    $0.append(contentsOf: token_to_piece(token: $1))
                }.dropFirst(prompt.utf8.count)

                for item in tokenHeap.unordered {
                    altTokens.insertIfPossible(
                        AlternativeHighProbToken(
                            token: item.token,
                            constraint: Array(prefixBytes) + token_to_piece(token: item.token),
                            probabilityRatioToMaxProb: expf(item.logprob - maxItem.logprob)
                        )
                    )
                }
            }
            score += maxItem.logprob
        }
        return .pass(score: score, alternativeConstraints: altTokens.unordered.sorted(by: >).map {
            ZenzCandidateEvaluationResult.AlternativeConstraint(
                probabilityRatio: $0.probabilityRatioToMaxProb,
                prefixConstraint: $0.constraint
            )
        })
    }

    func predict_next_character(leftSideContext: String, count: Int) async -> [(character: Character, value: Float)] {
        struct NextCharacterCandidate: Comparable {
            static func < (lhs: NextCharacterCandidate, rhs: NextCharacterCandidate) -> Bool {
                lhs.value < rhs.value
            }
            var character: Character
            var value: Float
        }

        let prompt_tokens = self.tokenize(text: "\u{EE00}。\u{EE02}\(leftSideContext)", add_bos: false)
        let startOffset = prompt_tokens.count - 1

        guard let logitsResult = await self.get_logits(tokens: prompt_tokens) else {
            debug("logits unavailable")
            return []
        }
        let logits = logitsResult.values
        let n_vocab = logitsResult.vocabSize

        var exp_sum: Float = 0
        let startIndex = (prompt_tokens.count - 1 - startOffset) * n_vocab
        let endIndex = (prompt_tokens.count - startOffset) * n_vocab

        var minHeap: FixedSizeHeap<NextCharacterCandidate> = .init(size: count)
        let token_to_penalty_weight: [Int: Float] = prompt_tokens.indexed().reduce(into: [:]) { dict, item in
            let (index, token) = item
            dict[token, default: 0] += 2 / Float(prompt_tokens.count - index)
        }

        for index in startIndex..<endIndex {
            let token = index - startIndex
            let repeat_penalty = Float(1.0 + token_to_penalty_weight[token, default: 0])
            let v = expf(logits[index] / repeat_penalty)
            exp_sum += v

            let tokenPieceData = Data(token_to_piece(token: token))
            guard let validCharacter = String(data: tokenPieceData, encoding: .utf8), let c = validCharacter.first else {
                continue
            }
            minHeap.insertIfPossible(NextCharacterCandidate(character: c, value: v))
        }

        return minHeap.unordered.sorted { $0.value > $1.value }.map { ($0.character, $0.value / exp_sum) }
    }

    func pure_greedy_decoding(leftSideContext: String, maxCount: Int = .max) async -> String {
        var prompt_tokens = self.tokenize(text: leftSideContext, add_bos: false)
        let initial_count = prompt_tokens.count
        let eos_token = tokenizer.endTokenID
        while prompt_tokens.count - initial_count < maxCount {
            let startOffset = prompt_tokens.count - 1
            guard let logitsResult = await self.get_logits(tokens: prompt_tokens) else {
                debug("logits unavailable")
                return ""
            }
            let logits = logitsResult.values
            let n_vocab = logitsResult.vocabSize
            let startIndex = (prompt_tokens.count - 1 - startOffset) * n_vocab
            let endIndex = (prompt_tokens.count - startOffset) * n_vocab
            var max_token: Int = -1
            var max_value: Float = -.infinity
            for index in startIndex..<endIndex {
                let token = index - startIndex
                if max_value < logits[index] {
                    max_token = token
                    max_value = logits[index]
                }
            }
            if max_token == eos_token {
                break
            } else {
                prompt_tokens.append(max_token)
            }
        }

        let cchars: [CChar] = prompt_tokens.dropFirst(initial_count).flatMap(self.token_to_cchars)
        let data = Data(cchars.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func get_logits(tokens: [Int]) async -> ZenzCoreMLLogits? {
        do {
            let result = try await self.generator.logits(for: tokens)
            self.prevInput = tokens
            return result
        } catch {
            debug("logits unavailable", error)
            return nil
        }
    }

    private func tokenize(text: String, add_bos: Bool, add_eos: Bool = false) -> [Int] {
        var tokens: [Int] = []
        if add_bos {
            tokens.append(tokenizer.startTokenID)
        }
        tokens += tokenizer.encode(text: text, addSpecialTokens: false)
        if add_eos {
            tokens.append(tokenizer.endTokenID)
        }
        return tokens
    }

    private func tokenScalars(token: Int) -> [CChar] {
        var scalars = tokenizer.decode(tokens: [token]).utf8CString
        scalars.removeLast()
        return Array(scalars)
    }

    private func token_to_piece(token: Int) -> [UInt8] {
        tokenScalars(token: token).map { UInt8(bitPattern: $0) }
    }

    private func token_to_cchars(token: Int) -> [CChar] {
        tokenScalars(token: token)
    }

    func getLearningPriority(data: DicdataElement) -> Float {
        if 1 <= data.ruby.count && data.ruby.count <= 4 {
            Float(data.ruby.count + 2)
        } else if 5 <= data.ruby.count && data.ruby.count <= 15 {
            Float(data.ruby.count * 2)
        } else {
            30
        }
    }
}

#endif
