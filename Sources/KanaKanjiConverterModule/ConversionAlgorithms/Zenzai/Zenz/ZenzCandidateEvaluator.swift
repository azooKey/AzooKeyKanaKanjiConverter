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

struct ZenzEvaluationCacheKey: Sendable, Equatable, Hashable {
    struct CandidateSegment: Sendable, Equatable, Hashable {
        var word: String
        var ruby: String
        var isLearned: Bool
    }

    var prompt: String
    var candidateTextForEvaluation: String
    var originalCandidateText: String
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var requestRichCandidates: Bool
    var reusesAddressedPrefix: Bool
    var candidateSegments: [CandidateSegment]
}

/// モデル評価結果を少量だけ保持する、スレッドセーフなLRUキャッシュ。
final class ZenzEvaluationCache: @unchecked Sendable {
    private struct Entry {
        var result: CandidateEvaluationResult
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(for key: ZenzEvaluationCacheKey) -> CandidateEvaluationResult? {
        self.lock.withLock {
            guard var entry = self.entries[key] else {
                return nil
            }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.result
        }
    }

    func insert(_ result: CandidateEvaluationResult, for key: ZenzEvaluationCacheKey) {
        self.lock.withLock {
            self.accessIndex &+= 1
            if self.entries[key] == nil, self.entries.count >= self.capacity,
               let leastRecentlyUsedKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries[leastRecentlyUsedKey] = nil
            }
            self.entries[key] = Entry(result: result, accessIndex: self.accessIndex)
        }
    }

    private let capacity: Int
    private var entries: [ZenzEvaluationCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

struct ZenzCandidateEvaluator {
    private struct IncrementalEvaluationProjection {
        var stableCandidatePrefix: String
        var input: String
        var candidateText: String
        var remainingConstraint: [UInt8]
        var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    }

    static func evaluate(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        incrementalPrefixConstraint: Kana2Kanji.PrefixConstraint?,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> CandidateEvaluationResult {
        debug("Evaluate", candidate)
        let projection = self.incrementalEvaluationProjection(
            input: input,
            inputCursorPosition: inputCursorPosition,
            candidate: candidate,
            requestRichCandidates: requestRichCandidates,
            prefixConstraint: prefixConstraint,
            incrementalPrefixConstraint: incrementalPrefixConstraint,
            personalizationMode: personalizationMode,
            versionDependentConfig: versionDependentConfig
        )
        var userDictionaryPrompt = ""
        for item in candidate.data where item.metadata.contains(.isFromUserDictionary) {
            userDictionaryPrompt += "\(item.word)(\(item.ruby.toHiragana()))"
        }
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: projection.input,
            inputCursorPosition: inputCursorPosition,
            userDictionaryPrompt: userDictionaryPrompt,
            versionDependentConfig: projection.versionDependentConfig
        )
        let candidateTextForEvaluation = self.candidateTextForEvaluation(
            candidateText: projection.candidateText,
            input: projection.input,
            inputCursorPosition: inputCursorPosition,
            versionDependentConfig: projection.versionDependentConfig
        )
        let normalizedPrompt = context.normalizeForModel(prompt)
        let prevPrompt = context.previousEvaluationPrompt()
        let reusesAddressedPrefix = prevPrompt == normalizedPrompt && !requestRichCandidates
        // A cache hit must produce the same subsequent incremental-evaluation state
        // as a model evaluation.
        defer {
            context.setPreviousEvaluationPrompt(normalizedPrompt)
        }
        let cacheKey: ZenzEvaluationCacheKey? = if personalizationMode == nil {
            ZenzEvaluationCacheKey(
                prompt: prompt,
                candidateTextForEvaluation: candidateTextForEvaluation,
                originalCandidateText: candidate.text,
                prefixConstraint: prefixConstraint,
                requestRichCandidates: requestRichCandidates,
                reusesAddressedPrefix: reusesAddressedPrefix,
                candidateSegments: candidate.data.map {
                    .init(
                        word: $0.word,
                        ruby: $0.ruby,
                        isLearned: $0.metadata.contains(.isLearned)
                    )
                }
            )
        } else {
            nil
        }
        if let cacheKey, let cached = context.cachedEvaluation(for: cacheKey) {
            return cached
        }
        func finish(_ result: CandidateEvaluationResult) -> CandidateEvaluationResult {
            if let cacheKey, result != .error {
                context.cacheEvaluation(result, for: cacheKey)
            }
            return result
        }

        let promptTokens = context.encodeEvaluationPrompt(prompt)
        let candidateTokens = context.encode(candidateTextForEvaluation, addBOS: false, addEOS: false)
        let addressedTokens: [llama_token]
        if reusesAddressedPrefix {
            var prefix = ""
            for character in projection.candidateText {
                let newPrefix = prefix + String(character)
                if projection.remainingConstraint.hasPrefix(newPrefix.utf8) {
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
        let n_vocab = Int(context.vocabSize)
        let learnedTokenPriorities: [Float]?
        if candidate.data.contains(where: { $0.metadata.contains(.isLearned) }) {
            let candidateLearnedTokens = candidate.data.flatMap {
                Array(
                    repeating: $0.metadata.contains(.isLearned) ? logf(self.learningPriority(data: $0)) : 0,
                    count: context.encode($0.word, addBOS: false).count
                )
            }
            if candidateLearnedTokens.count >= candidateTokens.count {
                learnedTokenPriorities = Array(candidateLearnedTokens.prefix(candidateTokens.count))
            } else {
                learnedTokenPriorities = candidateLearnedTokens + Array(
                    repeating: 0,
                    count: candidateTokens.count - candidateLearnedTokens.count
                )
            }
        } else {
            learnedTokenPriorities = nil
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

        struct TokenAndLogit: Comparable {
            static func < (lhs: TokenAndLogit, rhs: TokenAndLogit) -> Bool {
                lhs.logit < rhs.logit
            }
            var token: llama_token
            var logit: Float
        }

        var altTokens = FixedSizeHeap<AlternativeHighProbToken>(size: requestRichCandidates ? 5 : 0)
        func evaluateTokenRange(
            _ range: Range<Int>,
            logits: UnsafeMutablePointer<Float>,
            logitsStartIndex: Int
        ) -> CandidateEvaluationResult? {
            for i in range {
                let tokenID = tokens[i]
                let startIndex = (i - 1 - logitsStartIndex) * n_vocab
                let endIndex = startIndex + n_vocab
                var tokenHeap = FixedSizeHeap<TokenAndLogit>(size: requestRichCandidates ? 3 : 0)
                let maxItem: TokenAndLogit

                if let (mode, baseLM, personalLM) = personalizationMode, mode.alpha > 0 {
                    let prefix = tokens[..<i].dropFirst(promptTokens.count).map(Int.init)
                    let baseProb: [Float]
                    let personalProb: [Float]
                    if !prefix.isEmpty {
                        baseProb = baseLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                        personalProb = personalLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                    } else {
                        baseProb = Array(repeating: 0, count: n_vocab)
                        personalProb = baseProb
                    }
                    if requestRichCandidates {
                        for (vocabIndex, (lpb, lpp)) in zip(
                            0 ..< n_vocab,
                            zip(baseProb, personalProb)
                        ) {
                            let personalizedLogit = logits[startIndex + vocabIndex]
                                + mode.alpha * (lpp - lpb)
                            tokenHeap.insertIfPossible(
                                TokenAndLogit(
                                    token: llama_token(vocabIndex),
                                    logit: personalizedLogit
                                )
                            )
                        }
                        guard let maximum = tokenHeap.max else {
                            debug("Max Item could not be found for unknown reason")
                            return .error
                        }
                        maxItem = maximum
                    } else {
                        var maximum = TokenAndLogit(
                            token: 0,
                            logit: logits[startIndex] + mode.alpha * (personalProb[0] - baseProb[0])
                        )
                        for vocabIndex in 1 ..< n_vocab {
                            let personalizedLogit = logits[startIndex + vocabIndex]
                                + mode.alpha * (personalProb[vocabIndex] - baseProb[vocabIndex])
                            if personalizedLogit > maximum.logit {
                                maximum = TokenAndLogit(
                                    token: llama_token(vocabIndex),
                                    logit: personalizedLogit
                                )
                            }
                        }
                        maxItem = maximum
                    }
                } else if requestRichCandidates {
                    for index in startIndex ..< endIndex {
                        tokenHeap.insertIfPossible(
                            TokenAndLogit(
                                token: llama_token(index - startIndex),
                                logit: logits[index]
                            )
                        )
                    }
                    guard let maximum = tokenHeap.max else {
                        debug("Max Item could not be found for unknown reason")
                        return .error
                    }
                    maxItem = maximum
                } else {
                    var maximumToken = 0
                    var maximumLogit = logits[startIndex]
                    for vocabIndex in 1 ..< n_vocab {
                        let logit = logits[startIndex + vocabIndex]
                        if logit > maximumLogit {
                            maximumToken = vocabIndex
                            maximumLogit = logit
                        }
                    }
                    maxItem = TokenAndLogit(
                        token: llama_token(maximumToken),
                        logit: maximumLogit
                    )
                }

                if maxItem.token != tokenID {
                    if maxItem.token == context.eosToken {
                        let cchars = tokens[..<i].reduce(into: []) {
                            $0.append(contentsOf: context.tokenToPiece(token: $1))
                        }
                        let data = Data(cchars.map { UInt8(bitPattern: $0) })
                        let string = String(data: data, encoding: .utf8) ?? ""
                        let wholeResult = projection.stableCandidatePrefix
                            + String(string.dropFirst(normalizedPrompt.count))
                        return finish(.wholeResult(wholeResult))
                    } else {
                        let candidateTokenIndex = i - promptTokens.count
                        let learnedPriority = learnedTokenPriorities.map {
                            candidateTokenIndex < $0.count ? $0[candidateTokenIndex] : 0
                        } ?? 0
                        // softmaxの正規化項は両辺で相殺されるため、logitのまま比較できる。
                        let preferLearnedToken = learnedPriority > 0
                            && logits[startIndex + Int(tokenID)] + learnedPriority > maxItem.logit
                        if !preferLearnedToken {
                            let cchars = tokens[..<i].reduce(into: []) {
                                $0.append(contentsOf: context.tokenToPiece(token: $1))
                            } + context.tokenToPiece(token: maxItem.token)
                            return finish(
                                .fixRequired(
                                    prefixConstraint: projection.stableCandidatePrefix.utf8
                                        + cchars.dropFirst(normalizedPrompt.utf8.count).map(UInt8.init)
                                )
                            )
                        }
                    }
                } else if requestRichCandidates {
                    tokenHeap.removeMax()
                    let prefix = tokens[..<i].reduce(into: []) {
                        $0.append(contentsOf: context.tokenToPiece(token: $1))
                    }.dropFirst(normalizedPrompt.utf8.count)

                    for item in tokenHeap.unordered {
                        altTokens.insertIfPossible(
                            AlternativeHighProbToken(
                                token: item.token,
                                constraint: projection.stableCandidatePrefix.utf8
                                    + prefix.map(UInt8.init)
                                    + context.tokenToPiece(token: item.token).map(UInt8.init),
                                probabilityRatioToMaxProb: expf(item.logit - maxItem.logit)
                            )
                        )
                    }
                }
                // この値は順位付けには使われない。正規化項の全語彙走査を避けるため、
                // 等価な順位を持つ未正規化logitを蓄積する。
                score += maxItem.logit
            }
            return nil
        }

        let firstTokenIndex = startOffset + 1
        if firstTokenIndex < tokens.endIndex {
            // 修正要求は候補の冒頭で確定することが多い。最初の少数tokenだけを
            // decodeして判定し、必要な場合に限って残りを一括decodeする。
            let firstChunkEndIndex = min(tokens.endIndex, firstTokenIndex + 4)
            let firstChunkTokens = Array(tokens[..<firstChunkEndIndex])
            guard let logits = context.evaluationLogits(
                tokens: firstChunkTokens,
                startOffset: startOffset
            ) else {
                debug("logits unavailable")
                return .error
            }
            if let result = evaluateTokenRange(
                firstTokenIndex ..< firstChunkEndIndex,
                logits: logits,
                logitsStartIndex: startOffset
            ) {
                return result
            }

            if firstChunkEndIndex < tokens.endIndex {
                // 境界直前のtokenをlogits付きで再計算し、続きの最初のtokenを評価する。
                let continuationStartOffset = firstChunkEndIndex - 1
                guard let logits = context.evaluationLogits(
                    tokens: tokens,
                    startOffset: continuationStartOffset
                ) else {
                    debug("logits unavailable")
                    return .error
                }
                if let result = evaluateTokenRange(
                    firstChunkEndIndex ..< tokens.endIndex,
                    logits: logits,
                    logitsStartIndex: continuationStartOffset
                ) {
                    return result
                }
            }
        }
        return finish(
            .pass(
                score: score,
                alternativeConstraints: altTokens.unordered.sorted(by: >).map {
                    .init(probabilityRatio: $0.probabilityRatioToMaxProb, prefixConstraint: $0.constraint)
                }
            )
        )
    }

    /// 直前のリクエストまでにモデルが受理した文節を左文脈へ移し、
    /// 今回追加された範囲だけを評価する。
    ///
    /// 同一リクエスト内で新しく得た制約には適用せず、一括変換の探索は従来どおり。
    /// 学習・ユーザ辞書・リッチ候補・カーソル途中入力でも、評価範囲の変更が
    /// 各機能の意味を変えうるため全文を評価する。
    private static func incrementalEvaluationProjection(
        input: String,
        inputCursorPosition: Int?,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        incrementalPrefixConstraint: Kana2Kanji.PrefixConstraint?,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> IncrementalEvaluationProjection {
        let unchanged = IncrementalEvaluationProjection(
            stableCandidatePrefix: "",
            input: input,
            candidateText: candidate.text,
            remainingConstraint: prefixConstraint.constraint,
            versionDependentConfig: versionDependentConfig
        )
        guard inputCursorPosition == nil,
              !requestRichCandidates,
              personalizationMode == nil,
              let incrementalPrefixConstraint,
              !incrementalPrefixConstraint.constraint.isEmpty,
              candidate.data.allSatisfy({
                  $0.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary])
              }) else {
            return unchanged
        }

        var remainingInput = input[...]
        var remainingConstraint = incrementalPrefixConstraint.constraint[...]
        var matchedSegments: [(word: String, ruby: String)] = []
        for data in candidate.data where !data.word.isEmpty {
            let ruby = data.ruby.toKatakana()
            let wordBytes = Array(data.word.utf8)
            guard remainingInput.hasPrefix(ruby),
                  remainingConstraint.hasPrefix(wordBytes) else {
                break
            }
            matchedSegments.append((data.word, ruby))
            remainingInput = remainingInput.dropFirst(ruby.count)
            remainingConstraint = remainingConstraint.dropFirst(wordBytes.count)
        }

        // 直近の一致文節は、新しい入力によって再解釈できるよう評価対象に残す。
        guard matchedSegments.count >= 2 else {
            return unchanged
        }
        let stableSegments = matchedSegments.dropLast()
        let stableCandidatePrefix = stableSegments.reduce(into: "") { $0 += $1.word }
        let stableRubyPrefix = stableSegments.reduce(into: "") { $0 += $1.ruby }
        guard candidate.text.hasPrefix(stableCandidatePrefix),
              input.hasPrefix(stableRubyPrefix),
              incrementalPrefixConstraint.constraint.hasPrefix(stableCandidatePrefix.utf8),
              prefixConstraint.constraint.hasPrefix(stableCandidatePrefix.utf8) else {
            return unchanged
        }

        let projectedInput = String(input.dropFirst(stableRubyPrefix.count))
        let projectedCandidate = String(candidate.text.dropFirst(stableCandidatePrefix.count))
        let projectedConstraint = Array(
            prefixConstraint.constraint.dropFirst(stableCandidatePrefix.utf8.count)
        )
        let projectedConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
        switch versionDependentConfig {
        case .v2(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + stableCandidatePrefix
            projectedConfig = .v2(mode)
        case .v3(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + stableCandidatePrefix
            projectedConfig = .v3(mode)
        }
        return IncrementalEvaluationProjection(
            stableCandidatePrefix: stableCandidatePrefix,
            input: projectedInput,
            candidateText: projectedCandidate,
            remainingConstraint: projectedConstraint,
            versionDependentConfig: projectedConfig
        )
    }

    static func candidateTextForEvaluation(
        candidateText: String,
        input: String,
        inputCursorPosition: Int?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> String {
        switch versionDependentConfig {
        case .v2:
            return candidateText
        case .v3(let mode):
            if mode.enableAlignmentSeparator,
               ZenzPromptBuilder.shouldInsertAlignmentSeparator(input: input, cursorPosition: inputCursorPosition) {
                return candidateText + ZenzPromptBuilder.alignmentSeparator
            }
            return candidateText
        }
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
