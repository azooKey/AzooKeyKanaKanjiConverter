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
        var isFromUserDictionary: Bool = false
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
    static func evaluate(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        // 固定された部分は、表記を左文脈に移し、読みを入力から除いて、残りだけを評価する。
        // モデルは固定された表記が読みを消費したことを知らないので、残したまま評価すると続きの判断がずれる。
        guard let fixedPrefix = prefixConstraint.fixedPrefix,
              candidate.text.utf8.count >= fixedPrefix.byteCount,
              input.count >= fixedPrefix.rubyCount else {
            return self.evaluateAsIs(
                context: context,
                input: input,
                inputCursorPosition: inputCursorPosition,
                candidate: candidate,
                requestRichCandidates: requestRichCandidates,
                prefixConstraint: prefixConstraint,
                personalizationMode: personalizationMode,
                versionDependentConfig: versionDependentConfig,
                memoizationCache: memoizationCache
            )
        }
        let fixed = Array(prefixConstraint.constraint.prefix(fixedPrefix.byteCount))
        var remainingCandidate = candidate
        remainingCandidate.text = String(decoding: candidate.text.utf8.dropFirst(fixedPrefix.byteCount), as: UTF8.self)
        remainingCandidate.data = self.droppingFixedData(candidate.data, byteCount: fixedPrefix.byteCount)
        var remainingConstraint = prefixConstraint
        remainingConstraint.constraint = Array(prefixConstraint.constraint.dropFirst(fixedPrefix.byteCount))
        remainingConstraint.fixedPrefix = nil
        let result = self.evaluateAsIs(
            context: context,
            input: String(input.dropFirst(fixedPrefix.rubyCount)),
            inputCursorPosition: inputCursorPosition.map { $0 - fixedPrefix.rubyCount },
            candidate: remainingCandidate,
            requestRichCandidates: requestRichCandidates,
            prefixConstraint: remainingConstraint,
            personalizationMode: personalizationMode,
            versionDependentConfig: self.appendingLeftSideContext(String(decoding: fixed, as: UTF8.self), to: versionDependentConfig),
            memoizationCache: memoizationCache
        )
        return self.prepending(fixed, to: result)
    }

    private static func evaluateAsIs(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        debug("Evaluate", candidate)
        var userDictionaryPrompt = ""
        for item in candidate.data where item.metadata.contains(.isFromUserDictionary) {
            userDictionaryPrompt += "\(item.word)(\(item.ruby.toHiragana()))"
        }
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: input,
            inputCursorPosition: inputCursorPosition,
            userDictionaryPrompt: userDictionaryPrompt,
            versionDependentConfig: versionDependentConfig
        )
        let candidateTextForEvaluation = self.candidateTextForEvaluation(
            candidateText: candidate.text,
            input: input,
            inputCursorPosition: inputCursorPosition,
            versionDependentConfig: versionDependentConfig
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
                        isLearned: $0.metadata.contains(.isLearned),
                        isFromUserDictionary: $0.metadata.contains(.isFromUserDictionary)
                    )
                }
            )
        } else {
            nil
        }
        if let cacheKey, let cached = memoizationCache.cachedEvaluation(for: cacheKey) {
            return cached
        }
        func finish(_ result: CandidateEvaluationResult) -> CandidateEvaluationResult {
            if let cacheKey, result != .error {
                memoizationCache.cacheEvaluation(result, for: cacheKey)
            }
            return result
        }

        let promptTokens = context.encodeEvaluationPrompt(
            prompt,
            memoizationCache: memoizationCache
        )
        let candidateTokens = context.encode(candidateTextForEvaluation, addBOS: false, addEOS: false)
        let addressedTokens: [llama_token]
        if reusesAddressedPrefix {
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
        // 学習・ユーザ辞書の単語は先頭のtokenで採否を判断し、以降のtokenは表記のまま残す
        let userWordContinuations: [Bool]? = if candidate.data.contains(where: { !$0.metadata.isDisjoint(with: Self.userWordMetadata) }) {
            self.userWordContinuations(
                data: candidate.data,
                text: candidate.text,
                tokenByteCounts: candidateTokens.map { context.tokenToPiece(token: $0).count },
                normalize: context.normalizeForModel
            )
        } else {
            nil
        }
        let startOffset = promptTokens.count - 1 + addressedTokens.count
        let n_vocab = Int(context.vocabSize)
        let learnedTokenPriorities: [Float]?
        if candidate.data.contains(where: { !$0.metadata.isDisjoint(with: Self.userWordMetadata) }) {
            let candidateLearnedTokens = candidate.data.flatMap {
                Array(
                    repeating: !$0.metadata.isDisjoint(with: Self.userWordMetadata) ? logf(self.learningPriority(data: $0)) : 0,
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

                let candidateTokenIndex = i - promptTokens.count
                let continuesUserWord = userWordContinuations.map {
                    candidateTokenIndex < $0.count && $0[candidateTokenIndex]
                } ?? false
                if maxItem.token != tokenID, !continuesUserWord {
                    if maxItem.token == context.eosToken {
                        let cchars = tokens[..<i].reduce(into: []) {
                            $0.append(contentsOf: context.tokenToPiece(token: $1))
                        }
                        let data = Data(cchars.map { UInt8(bitPattern: $0) })
                        let string = String(data: data, encoding: .utf8) ?? ""
                        let wholeResult = String(string.dropFirst(normalizedPrompt.count))
                        return finish(.wholeResult(wholeResult))
                    } else {
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
                                    prefixConstraint: cchars.dropFirst(normalizedPrompt.utf8.count).map(UInt8.init)
                                )
                            )
                        }
                    }
                } else if !continuesUserWord, requestRichCandidates {
                    tokenHeap.removeMax()
                    let prefix = tokens[..<i].reduce(into: []) {
                        $0.append(contentsOf: context.tokenToPiece(token: $1))
                    }.dropFirst(normalizedPrompt.utf8.count)

                    for item in tokenHeap.unordered {
                        altTokens.insertIfPossible(
                            AlternativeHighProbToken(
                                token: item.token,
                                constraint: prefix.map(UInt8.init)
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
            // token i の判定に必要なのは token i - 1 のlogitsまでなので、
            // 最終候補token自体はdecodeしない。
            let evaluationTokens = Array(tokens.dropLast())
            guard let logits = context.evaluationLogits(
                tokens: evaluationTokens,
                startOffset: startOffset
            ) else {
                debug("logits unavailable")
                return .error
            }
            if let result = evaluateTokenRange(
                firstTokenIndex ..< tokens.endIndex,
                logits: logits,
                logitsStartIndex: startOffset
            ) {
                return result
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

    private static let userWordMetadata: DicdataElementMetadata = [.isLearned, .isFromUserDictionary]

    /// 候補の各tokenが、学習・ユーザ辞書の単語の途中から始まるかどうかを返す
    /// - note: 単語の表記を連結したものが候補の表記と一致しない場合は判定しない
    static func userWordContinuations(
        data: [DicdataElement],
        text: String,
        tokenByteCounts: [Int],
        normalize: (String) -> String
    ) -> [Bool] {
        guard data.map(\.word).joined() == text else {
            return Array(repeating: false, count: tokenByteCounts.count)
        }
        var userWordRanges: [Range<Int>] = []
        var wordOffset = 0
        for element in data {
            let byteCount = normalize(element.word).utf8.count
            if !element.metadata.isDisjoint(with: self.userWordMetadata) {
                userWordRanges.append(wordOffset ..< wordOffset + byteCount)
            }
            wordOffset += byteCount
        }
        var tokenOffset = 0
        return tokenByteCounts.map { byteCount in
            defer {
                tokenOffset += byteCount
            }
            return userWordRanges.contains { $0.lowerBound < tokenOffset && tokenOffset < $0.upperBound }
        }
    }

    /// `data` の先頭から、表記全体が固定部分に収まる要素だけを落とす
    static func droppingFixedData(_ data: [DicdataElement], byteCount: Int) -> [DicdataElement] {
        var coveredByteCount = 0
        return Array(
            data.drop { element in
                let nextCoveredByteCount = coveredByteCount + element.word.utf8.count
                guard nextCoveredByteCount <= byteCount else {
                    return false
                }
                coveredByteCount = nextCoveredByteCount
                return true
            }
        )
    }

    private static func appendingLeftSideContext(_ text: String, to config: ConvertRequestOptions.ZenzaiVersionDependentMode) -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        switch config {
        case .v2(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + text
            return .v2(mode)
        case .v3(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + text
            return .v3(mode)
        }
    }

    /// 固定された表記を除いて評価した結果の制約に、その表記を戻す
    private static func prepending(_ fixed: [UInt8], to result: CandidateEvaluationResult) -> CandidateEvaluationResult {
        switch result {
        case .error:
            return .error
        case .pass(let score, let alternativeConstraints):
            return .pass(
                score: score,
                alternativeConstraints: alternativeConstraints.map {
                    .init(probabilityRatio: $0.probabilityRatio, prefixConstraint: fixed + $0.prefixConstraint)
                }
            )
        case .fixRequired(let prefixConstraint):
            return .fixRequired(prefixConstraint: fixed + prefixConstraint)
        case .wholeResult(let wholeResult):
            return .wholeResult(String(decoding: fixed, as: UTF8.self) + wholeResult)
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
