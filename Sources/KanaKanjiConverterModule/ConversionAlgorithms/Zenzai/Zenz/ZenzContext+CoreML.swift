#if ZenzaiCoreML

import Algorithms
import Dispatch
import EfficientNGram
import Foundation
import HeapModule
import SwiftUtils
import ZenzCoreMLBackend

final class ZenzContext {
    private let generator: ZenzStateful8BitGenerator
    private let tokenizer = ZenzTokenizer()
    private var prevInput: [Int] = []
    private var prevPrompt: [Int] = []
    private let n_len: Int32 = 512

    private init(generator: ZenzStateful8BitGenerator) {
        self.generator = generator
    }

    static func createContext(path _: String) throws -> ZenzContext {
        let generator = try Self.runBlocking {
            try await ZenzStateful8BitGenerator()
        }
        return ZenzContext(generator: generator)
    }

    deinit {
        try? Self.runBlocking {
            await generator.resetState()
        }
    }

    func reset_context() throws {
        try Self.runBlocking {
            await generator.resetState()
        }
        self.prevInput = []
        self.prevPrompt = []
    }

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

    func evaluate_candidate(
        input: String,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> CandidateEvaluationResult {
        let promptString = ZenzPromptBuilder.buildPrompt(
            convertTarget: input,
            candidate: candidate,
            versionDependentConfig: versionDependentConfig
        )
        let prompt_tokens = self.tokenize(text: promptString, add_bos: true, add_eos: false)
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
        guard let logitsResult = self.get_logits(tokens: tokens) else {
            debug("logits unavailable")
            return .error
        }
        var logits = logitsResult.values
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
            for index in startIndex ..< endIndex {
                sumexp += expf(logits[index])
            }
            let logsumexp = logf(sumexp)

            if let (mode, baseLM, personalLM) = personalizationMode, mode.alpha > 0 {
                let prefix = tokens[..<i].dropFirst(prompt_tokens.count).map(Int.init)
                let baseProb: [Float]
                let personalProb: [Float]
                switch requestRichCandidates {
                case true:
                    baseProb = baseLM.getProbabilityMass(on: prefix, candidateCount: 1_000)
                    personalProb = personalLM.getProbabilityMass(on: prefix, candidateCount: 1_000)
                case false:
                    baseProb = baseLM.getProbabilityMass(at: prefix, stateful: true)
                    personalProb = personalLM.getProbabilityMass(at: prefix, stateful: true)
                }
                let alpha = max(0, min(1, Double(mode.alpha)))
                zip(baseProb, personalProb).enumerated().forEach { offset, value in
                    let (bp, pp) = value
                    let mix = Float(alpha * Double(pp) + (1 - alpha) * Double(bp))
                    let idx = startIndex + offset
                    logits[idx] = logf(expf(logits[idx]) * mix)
                }
            }

            for index in startIndex..<endIndex {
                let logp = logits[index] - logsumexp
                tokenHeap.insertIfPossible(TokenAndLogprob(token: index - startIndex, logprob: logp))
            }

            guard let maxItem = tokenHeap.max else {
                continue
            }

            if requestRichCandidates {
                for item in tokenHeap.unordered {
                    guard !is_learned_token.indices.contains(i - prompt_tokens.count) || !is_learned_token[i - prompt_tokens.count].isLearned else {
                        continue
                    }
                    altTokens.insertIfPossible(
                        AlternativeHighProbToken(
                            token: item.token,
                            constraint: tokens[..<i].reduce(into: []) { partialResult, token in
                                partialResult.append(contentsOf: token_to_piece(token: token))
                            } + token_to_piece(token: item.token),
                            probabilityRatioToMaxProb: expf(item.logprob - maxItem.logprob)
                        )
                    )
                }
            }
            score += maxItem.logprob
        }
        return .pass(score: score, alternativeConstraints: altTokens.unordered.sorted(by: >).map {
            AlternativeConstraint(probabilityRatio: $0.probabilityRatioToMaxProb, prefixConstraint: $0.constraint)
        })
    }

    func predict_next_character(leftSideContext: String, count: Int) -> [(character: Character, value: Float)] {
        struct NextCharacterCandidate: Comparable {
            static func < (lhs: NextCharacterCandidate, rhs: NextCharacterCandidate) -> Bool {
                lhs.value < rhs.value
            }
            var character: Character
            var value: Float
        }

        let prompt_tokens = self.tokenize(text: "\u{EE00}。\u{EE02}\(leftSideContext)", add_bos: false)
        let startOffset = prompt_tokens.count - 1

        guard let logitsResult = self.get_logits(tokens: prompt_tokens) else {
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

            let tokenPieceData = Data(token_to_piece(token: token).map(UInt8.init))
            guard let validCharacter = String(data: tokenPieceData, encoding: .utf8), let c = validCharacter.first else {
                continue
            }
            minHeap.insertIfPossible(NextCharacterCandidate(character: c, value: v))
        }

        return minHeap.unordered.sorted { $0.value > $1.value }.map { ($0.character, $0.value / exp_sum) }
    }

    func pure_greedy_decoding(leftSideContext: String, maxCount: Int = .max) -> String {
        var prompt_tokens = self.tokenize(text: leftSideContext, add_bos: false)
        let initial_count = prompt_tokens.count
        let eos_token = tokenizer.endTokenID
        while prompt_tokens.count - initial_count < maxCount {
            let startOffset = prompt_tokens.count - 1
        guard let logitsResult = self.get_logits(tokens: prompt_tokens) else {
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

        let cchars: [CChar] = prompt_tokens.dropFirst(initial_count).flatMap(self.token_to_piece)
        let data = Data(cchars.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func get_logits(tokens: [Int]) -> ZenzCoreMLLogits? {
        do {
            let result = try Self.runBlocking {
                try await generator.logits(for: tokens)
            }
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

    private func token_to_piece(token: Int) -> [CChar] {
        var scalars = tokenizer.decode(tokens: [token]).utf8CString
        scalars.removeLast()
        return scalars
    }

    private static func runBlocking<T>(_ operation: @escaping () async throws -> T) rethrows -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached(priority: nil) {
            do {
                let value = try await operation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
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
