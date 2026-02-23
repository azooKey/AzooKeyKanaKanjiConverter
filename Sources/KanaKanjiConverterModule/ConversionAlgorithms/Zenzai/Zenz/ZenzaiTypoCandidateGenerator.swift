#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import Foundation
import SwiftUtils

package struct ZenzaiTypoSearchConfig: Sendable, Equatable, Hashable {
    package init(
        beamSize: Int = 32,
        topK: Int = 64,
        nBest: Int = 5,
        maxSteps: Int? = nil,
        alpha: Float = 1.0,
        beta: Float = 1.2,
        gamma: Float = 1.0
    ) {
        self.beamSize = max(1, beamSize)
        self.topK = max(1, topK)
        self.nBest = max(1, nBest)
        self.maxSteps = maxSteps
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
    }

    package var beamSize: Int
    package var topK: Int
    package var nBest: Int
    package var maxSteps: Int?
    package var alpha: Float
    package var beta: Float
    package var gamma: Float
}

package struct ZenzaiTypoCandidate: Sendable, Equatable, Hashable {
    package init(
        correctedInput: String,
        convertedText: String,
        score: Float,
        lmScore: Float,
        channelCost: Float,
        prominence: Float
    ) {
        self.correctedInput = correctedInput
        self.convertedText = convertedText
        self.score = score
        self.lmScore = lmScore
        self.channelCost = channelCost
        self.prominence = prominence
    }

    package var correctedInput: String
    package var convertedText: String
    package var score: Float
    package var lmScore: Float
    package var channelCost: Float
    package var prominence: Float
}

enum ZenzaiTypoCandidateGenerator {
    private static let boi: Character = "\u{EE00}"
    private static let boc: Character = "\u{EE02}"

    private enum InputMode {
        case flick
        case roman2kana
    }

    private struct RomanGeneratorState: Sendable, Equatable, Hashable {
        var pending: String
        var prevInputChar: Character?
        var proxyLogp: Float
    }

    private struct Hypothesis: Sendable {
        var correctedInput: String
        var emittedText: String
        var emittedTokenIDs: [llama_token]
        var j: Int
        var prevEmittedChar: Character?
        var score: Float
        var lmScore: Float
        var channelCost: Float
        var romanState: RomanGeneratorState?
    }

    private struct ScoredHypothesis: Comparable {
        static func == (lhs: ScoredHypothesis, rhs: ScoredHypothesis) -> Bool {
            lhs.score == rhs.score
        }

        static func < (lhs: ScoredHypothesis, rhs: ScoredHypothesis) -> Bool {
            lhs.score < rhs.score
        }

        init(_ hypothesis: Hypothesis) {
            self.hypothesis = hypothesis
            self.score = hypothesis.score
        }

        var hypothesis: Hypothesis
        var score: Float
    }

    private struct RomanDeferredRequest {
        var parent: Hypothesis
        var baseState: RomanGeneratorState
        var correctedAppend: String
        var observedCount: Int
        var channelAdd: Float
        var emitted: String
        var pending: String
        var lastInputChar: Character
        var upperBoundScore: Float
    }

    private struct LMScorer {
        private let context: ZenzContext
        private let promptTokenIDs: [llama_token]
        private let vocabSize: Int
        private var nextLogProbCache: [[llama_token]: [Float]] = [:]
        private var encodeCache: [String: [llama_token]] = [:]
        private var tokenCharCache: [llama_token: Character?] = [:]

        init(context: ZenzContext, leftSideContext: String) {
            self.context = context
            let prompt = String(ZenzaiTypoCandidateGenerator.boc) + leftSideContext + String(ZenzaiTypoCandidateGenerator.boi)
            self.promptTokenIDs = context.encodeRaw(prompt, addBOS: false, addEOS: false)
            self.vocabSize = Int(context.vocabSize)
        }

        mutating func encodeRaw(_ text: String) -> [llama_token] {
            if let cached = self.encodeCache[text] {
                return cached
            }
            let tokenIDs = self.context.encodeRaw(text, addBOS: false, addEOS: false)
            self.encodeCache[text] = tokenIDs
            return tokenIDs
        }

        mutating func topKCharacters(emittedTokenIDs: [llama_token], k: Int) -> [Character] {
            guard let nextLogProbs = self.nextLogProbs(emittedTokenIDs: emittedTokenIDs) else {
                return []
            }
            struct TokenLogProb: Comparable {
                static func < (lhs: TokenLogProb, rhs: TokenLogProb) -> Bool {
                    lhs.logProb < rhs.logProb
                }
                var token: llama_token
                var logProb: Float
            }
            var heap = FixedSizeHeap<TokenLogProb>(size: max(1, k * 4))
            for (tokenID, logProb) in nextLogProbs.indexed() {
                heap.insertIfPossible(TokenLogProb(token: llama_token(tokenID), logProb: logProb))
            }
            var chars: [Character] = []
            chars.reserveCapacity(k)
            var seen: Set<Character> = []
            for item in heap.unordered.sorted(by: >) {
                guard let char = self.tokenToSingleCharacter(item.token), !seen.contains(char) else {
                    continue
                }
                chars.append(char)
                seen.insert(char)
                if chars.count >= k {
                    break
                }
            }
            return chars
        }

        mutating func nextLogProbsForPrefix(emittedTokenIDs: [llama_token]) -> [Float]? {
            self.nextLogProbs(emittedTokenIDs: emittedTokenIDs)
        }

        mutating func appendAndScore(
            emittedTokenIDs: [llama_token],
            lmScore: Float,
            appendText: String
        ) -> (emittedTokenIDs: [llama_token], lmScore: Float)? {
            let appendTokenIDs = self.encodeRaw(appendText)
            return self.appendAndScore(
                emittedTokenIDs: emittedTokenIDs,
                lmScore: lmScore,
                appendTokenIDs: appendTokenIDs
            )
        }

        private mutating func appendAndScore(
            emittedTokenIDs: [llama_token],
            lmScore: Float,
            appendTokenIDs: [llama_token]
        ) -> (emittedTokenIDs: [llama_token], lmScore: Float)? {
            guard !appendTokenIDs.isEmpty else {
                return (emittedTokenIDs, lmScore)
            }
            var currentTokenIDs = emittedTokenIDs
            var currentScore = lmScore
            for tokenID in appendTokenIDs {
                guard let logProbs = self.nextLogProbs(emittedTokenIDs: currentTokenIDs) else {
                    return nil
                }
                let index = Int(tokenID)
                guard logProbs.indices.contains(index) else {
                    return nil
                }
                currentScore += logProbs[index]
                currentTokenIDs.append(tokenID)
            }
            return (currentTokenIDs, currentScore)
        }

        private mutating func tokenToSingleCharacter(_ token: llama_token) -> Character? {
            if let cached = self.tokenCharCache[token] {
                return cached
            }
            let piece = self.context.tokenToPiece(token: token)
            let data = Data(piece.map { UInt8(bitPattern: $0) })
            let char: Character?
            if let text = String(data: data, encoding: .utf8), text.count == 1 {
                char = text.first
            } else {
                char = nil
            }
            self.tokenCharCache[token] = char
            return char
        }

        private mutating func nextLogProbs(emittedTokenIDs: [llama_token]) -> [Float]? {
            if let cached = self.nextLogProbCache[emittedTokenIDs] {
                return cached
            }
            let fullTokenIDs = self.promptTokenIDs + emittedTokenIDs
            guard !fullTokenIDs.isEmpty else {
                return nil
            }
            let startOffset = fullTokenIDs.count - 1
            guard let logits = self.context.evaluationLogits(tokens: fullTokenIDs, startOffset: startOffset) else {
                return nil
            }
            var values: [Float] = Array(repeating: 0, count: self.vocabSize)
            var maxLogit: Float = -.infinity
            for i in values.indices {
                let value = logits[i]
                values[i] = value
                if value > maxLogit {
                    maxLogit = value
                }
            }
            var sumExp: Float = 0
            for i in values.indices {
                sumExp += expf(values[i] - maxLogit)
            }
            let logSumExp = maxLogit + logf(sumExp)
            for i in values.indices {
                values[i] -= logSumExp
            }
            self.nextLogProbCache[emittedTokenIDs] = values
            return values
        }
    }

    private static let flickGroups: [String] = [
        "アイウエオ",
        "カキクケコ",
        "ガギグゲゴ",
        "サシスセソ",
        "ザジズゼゾ",
        "タチツテト",
        "ダヂヅデド",
        "ナニヌネノ",
        "ハヒフヘホ",
        "バビブベボ",
        "パピプペポ",
        "マミムメモ",
        "ヤユヨ",
        "ャュョ",
        "ラリルレロ",
        "ワヲンー"
    ]

    private static let qwertyNeighbors: [Character: Set<Character>] = [
        "a": ["q", "s", "w", "x", "z"],
        "b": ["f", "g", "h", "n", "v"],
        "c": ["d", "f", "s", "v", "x"],
        "d": ["c", "e", "f", "r", "s", "v", "w", "x"],
        "e": ["d", "f", "r", "s", "w"],
        "f": ["b", "c", "d", "e", "g", "r", "t", "v"],
        "g": ["b", "f", "h", "n", "r", "t", "v", "y"],
        "h": ["b", "g", "j", "m", "n", "t", "u", "y"],
        "i": ["j", "k", "l", "o", "u"],
        "j": ["h", "i", "k", "m", "n", "u", "y"],
        "k": ["i", "j", "l", "m", "o", "u"],
        "l": ["i", "k", "o", "p"],
        "m": ["h", "j", "k", "n"],
        "n": ["b", "g", "h", "j", "m"],
        "o": ["i", "k", "l", "p"],
        "p": ["l", "o"],
        "q": ["a", "s", "w"],
        "r": ["d", "e", "f", "g", "t"],
        "s": ["a", "c", "d", "e", "q", "w", "x", "z"],
        "t": ["f", "g", "h", "r", "y"],
        "u": ["h", "i", "j", "k", "y"],
        "v": ["b", "c", "d", "f", "g"],
        "w": ["a", "d", "e", "q", "s"],
        "x": ["a", "c", "d", "s", "z"],
        "y": ["g", "h", "j", "t", "u"],
        "z": ["a", "s", "x"]
    ]

    private static let romanVowels: Set<Character> = ["a", "e", "i", "o", "u"]
    private static let romanChars: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz")
    private static let romanConsonants: Set<Character> = Self.romanChars.subtracting(Self.romanVowels)
    private static let romanPunctMap: [Character: String] = [
        "-": "ー",
        ",": "、",
        ".": "。"
    ]
    private static let romanProbeChars: [Character] = Array(Self.romanChars).sorted() + Array(Self.romanPunctMap.keys).sorted()
    private static let romanToKana: [String: String] = {
        Dictionary(uniqueKeysWithValues: InputTables.defaultRomanToKanaPieceMap.compactMap { key, value -> (String, String)? in
            let keyChars = key.compactMap { element -> Character? in
                if case let .piece(piece) = element, case let .character(c) = piece {
                    return c
                }
                return nil
            }
            let valueChars = value.compactMap { element -> Character? in
                if case let .character(c) = element {
                    return c
                }
                return nil
            }
            guard keyChars.count == key.count, valueChars.count == value.count else {
                return nil
            }
            return (String(keyChars), String(valueChars).toKatakana())
        })
    }()
    private static let romanPrefixes: Set<String> = {
        var prefixes: Set<String> = []
        for key in Self.romanToKana.keys {
            for i in 1 ... key.count {
                prefixes.insert(String(key.prefix(i)))
            }
        }
        return prefixes
    }()
    private static let flickNeighbors: [Character: Set<Character>] = {
        var result: [Character: Set<Character>] = [:]
        for group in Self.flickGroups {
            let chars = Array(group)
            for c in chars {
                result[c] = Set(chars.filter { $0 != c })
            }
        }
        return result
    }()

    static func generate(
        context: ZenzContext,
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        searchConfig: ZenzaiTypoSearchConfig
    ) -> [ZenzaiTypoCandidate] {
        let mode = Self.resolveInputMode(inputStyle: inputStyle)
        let observedInput = Self.observedInput(composingText: composingText, mode: mode)
        guard !observedInput.isEmpty else {
            return []
        }
        let observedChars = Array(observedInput)
        let maxSteps = searchConfig.maxSteps ?? (observedChars.count * 2 + 8)

        var scorer = LMScorer(context: context, leftSideContext: leftSideContext)
        var beam: [Hypothesis] = [
            Hypothesis(
                correctedInput: "",
                emittedText: "",
                emittedTokenIDs: [],
                j: 0,
                prevEmittedChar: nil,
                score: 0,
                lmScore: 0,
                channelCost: 0,
                romanState: mode == .roman2kana ? .init(pending: "", prevInputChar: nil, proxyLogp: 0) : nil
            )
        ]

        for _ in 0..<maxSteps {
            let expanded: [Hypothesis]
            let allConsumed: Bool
            switch mode {
            case .flick:
                var flickExpanded: [Hypothesis] = []
                flickExpanded.reserveCapacity(searchConfig.beamSize * 6)
                var flickAllConsumed = true
                for hypothesis in beam {
                    if hypothesis.j >= observedChars.count {
                        flickExpanded.append(hypothesis)
                        continue
                    }
                    flickAllConsumed = false
                    flickExpanded.append(contentsOf: Self.expandFlick(
                        hypothesis: hypothesis,
                        observedChars: observedChars,
                        scorer: &scorer,
                        config: searchConfig
                    ))
                }
                expanded = flickExpanded
                allConsumed = flickAllConsumed
            case .roman2kana:
                let result = Self.expandRoman2KanaWithDeferred(
                    beam: beam,
                    observedChars: observedChars,
                    scorer: &scorer,
                    config: searchConfig
                )
                expanded = result.expanded
                allConsumed = result.allConsumed
            }
            guard !expanded.isEmpty else {
                break
            }
            beam = expanded.sorted(by: { $0.score > $1.score }).prefix(searchConfig.beamSize).map { $0 }
            if allConsumed {
                break
            }
        }

        let finals: [Hypothesis] = {
            let consumed = beam.filter { $0.j == observedChars.count }
            if !consumed.isEmpty {
                return consumed
            }
            return beam.compactMap { hypothesis in
                Self.completeHypothesis(
                    hypothesis: hypothesis,
                    observedChars: observedChars,
                    mode: mode,
                    scorer: &scorer
                )
            }
        }()

        guard !finals.isEmpty else {
            return []
        }
        let sorted = finals.sorted(by: { $0.score > $1.score })
        let bestScore = sorted[0].score

        var unique: [String: ZenzaiTypoCandidate] = [:]
        for hypothesis in sorted {
            let convertedText: String = switch mode {
            case .flick:
                hypothesis.emittedText
            case .roman2kana:
                hypothesis.emittedText + Self.romanPendingToMixedDisplay(hypothesis.romanState?.pending ?? "")
            }
            let candidate = ZenzaiTypoCandidate(
                correctedInput: hypothesis.correctedInput,
                convertedText: convertedText,
                score: hypothesis.score,
                lmScore: hypothesis.lmScore,
                channelCost: hypothesis.channelCost,
                prominence: expf(hypothesis.score - bestScore)
            )
            if let existing = unique[candidate.correctedInput], existing.score >= candidate.score {
                continue
            }
            unique[candidate.correctedInput] = candidate
            if unique.count >= searchConfig.nBest * 3 {
                break
            }
        }

        return unique.values.sorted(by: { $0.score > $1.score }).prefix(searchConfig.nBest).map { $0 }
    }

    private static func resolveInputMode(inputStyle: InputStyle) -> InputMode {
        switch inputStyle {
        case .roman2kana, .mapped(id: .defaultRomanToKana):
            .roman2kana
        default:
            .flick
        }
    }

    private static func observedInput(composingText: ComposingText, mode: InputMode) -> String {
        switch mode {
        case .flick:
            return composingText.convertTarget.toKatakana()
        case .roman2kana:
            var chars: [Character] = []
            chars.reserveCapacity(composingText.input.count)
            for element in composingText.input {
                let raw: Character?
                switch element.piece {
                case let .character(c):
                    raw = c
                case let .key(intention: intention, input: input, modifiers: _):
                    raw = intention ?? input
                case .compositionSeparator:
                    raw = nil
                }
                guard let raw else {
                    continue
                }
                let lowered = Character(String(raw).lowercased())
                if Self.romanChars.contains(lowered) || Self.romanPunctMap[lowered] != nil {
                    chars.append(lowered)
                }
            }
            return String(chars)
        }
    }

    private static func expandFlick(
        hypothesis: Hypothesis,
        observedChars: [Character],
        scorer: inout LMScorer,
        config: ZenzaiTypoSearchConfig
    ) -> [Hypothesis] {
        guard observedChars.indices.contains(hypothesis.j) else {
            return [hypothesis]
        }
        let observed = observedChars[hypothesis.j]
        var outputs: [Hypothesis] = []
        outputs.reserveCapacity(16)

        if let prev = hypothesis.prevEmittedChar, Self.flickNeighbors[prev, default: []].contains(observed) {
            var inserted = hypothesis
            inserted.j += 1
            inserted.channelCost += config.beta
            inserted.score = inserted.lmScore - inserted.channelCost
            outputs.append(inserted)
        }

        var allowed = Set([observed])
        allowed.formUnion(Self.flickNeighbors[observed, default: []])
        let lmTopChars = Set(scorer.topKCharacters(emittedTokenIDs: hypothesis.emittedTokenIDs, k: config.topK))
        let candidates = allowed.intersection(lmTopChars.union([observed]))
        let targetChars = candidates.isEmpty ? [observed] : candidates.sorted(by: { $0 < $1 })

        for yChar in targetChars {
            guard let appended = scorer.appendAndScore(
                emittedTokenIDs: hypothesis.emittedTokenIDs,
                lmScore: hypothesis.lmScore,
                appendText: String(yChar)
            ) else {
                continue
            }
            let addCost: Float = yChar == observed ? 0 : config.alpha
            var next = hypothesis
            next.correctedInput += String(yChar)
            next.emittedText += String(yChar)
            next.emittedTokenIDs = appended.emittedTokenIDs
            next.lmScore = appended.lmScore
            next.channelCost += addCost
            next.score = next.lmScore - next.channelCost
            next.j += 1
            next.prevEmittedChar = yChar
            outputs.append(next)
        }

        if observedChars.indices.contains(hypothesis.j + 1) {
            let nextObserved = observedChars[hypothesis.j + 1]
            if observed != nextObserved {
                let swapString = String([nextObserved, observed])
                guard let appended = scorer.appendAndScore(
                    emittedTokenIDs: hypothesis.emittedTokenIDs,
                    lmScore: hypothesis.lmScore,
                    appendText: swapString
                ) else {
                    return outputs
                }
                var swapped = hypothesis
                swapped.correctedInput += swapString
                swapped.emittedText += swapString
                swapped.emittedTokenIDs = appended.emittedTokenIDs
                swapped.lmScore = appended.lmScore
                swapped.channelCost += config.gamma
                swapped.score = swapped.lmScore - swapped.channelCost
                swapped.j += 2
                swapped.prevEmittedChar = observed
                outputs.append(swapped)
            }
        }

        return outputs
    }

    private static func expandRoman2KanaCandidates(
        hypothesis: Hypothesis,
        observedChars: [Character],
        scorer: inout LMScorer,
        config: ZenzaiTypoSearchConfig
    ) -> (immediate: [Hypothesis], deferred: [RomanDeferredRequest]) {
        guard observedChars.indices.contains(hypothesis.j), let baseState = hypothesis.romanState else {
            return ([hypothesis], [])
        }
        let observed = observedChars[hypothesis.j]
        let isInputTail = hypothesis.j == observedChars.count - 1
        var immediate: [Hypothesis] = []
        immediate.reserveCapacity(20)
        var deferred: [RomanDeferredRequest] = []
        deferred.reserveCapacity(8)

        func addAdvance(trueSeq: [Character], observedCount: Int, channelAdd: Float) {
            guard let last = trueSeq.last else {
                return
            }
            var pending = baseState.pending
            var emitted = ""
            for char in trueSeq {
                let consumed = Self.romanConsumeWithEmission(pending: pending, newChar: char)
                emitted += consumed.emitted
                pending = consumed.pending
            }
            let reachesTail = hypothesis.j + observedCount - 1 == observedChars.count - 1
            if reachesTail, !pending.isEmpty {
                let observedLast = observedChars[hypothesis.j + observedCount - 1]
                if last != observedLast || channelAdd > 0 {
                    return
                }
            }
            if emitted.isEmpty {
                if let evaluated = Self.evaluateRomanAdvance(
                    parent: hypothesis,
                    baseState: baseState,
                    correctedAppend: String(trueSeq),
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputChar: last,
                    scorer: &scorer
                ) {
                    immediate.append(evaluated)
                }
                return
            }
            let oldProxyLogp = baseState.proxyLogp
            guard oldProxyLogp.isFinite else {
                return
            }
            let baseLMScore = hypothesis.lmScore - oldProxyLogp
            guard let firstChar = emitted.first else {
                return
            }
            let firstTokens = scorer.encodeRaw(String(firstChar))
            guard firstTokens.count == 1,
                  let firstToken = firstTokens.first,
                  let nextLogProbs = scorer.nextLogProbsForPrefix(emittedTokenIDs: hypothesis.emittedTokenIDs)
            else {
                if let evaluated = Self.evaluateRomanAdvance(
                    parent: hypothesis,
                    baseState: baseState,
                    correctedAppend: String(trueSeq),
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputChar: last,
                    scorer: &scorer
                ) {
                    immediate.append(evaluated)
                }
                return
            }
            let index = Int(firstToken)
            guard nextLogProbs.indices.contains(index) else {
                return
            }
            let upperBoundLM = baseLMScore + nextLogProbs[index]
            let upperBoundScore = upperBoundLM - (hypothesis.channelCost + channelAdd)
            deferred.append(
                RomanDeferredRequest(
                    parent: hypothesis,
                    baseState: baseState,
                    correctedAppend: String(trueSeq),
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputChar: last,
                    upperBoundScore: upperBoundScore
                )
            )
        }

        addAdvance(trueSeq: [observed], observedCount: 1, channelAdd: 0)
        if Self.romanChars.contains(observed) {
            for neighbor in Self.qwertyNeighbors[observed, default: []].sorted(by: { $0 < $1 }) {
                addAdvance(trueSeq: [neighbor], observedCount: 1, channelAdd: config.alpha)
            }
        }

        if !isInputTail,
           let prevInput = baseState.prevInputChar,
           Self.qwertyNeighbors[prevInput, default: []].contains(observed) {
            let newProxyLogp = Self.romanProxyLogProb(
                pending: baseState.pending,
                emittedTokenIDs: hypothesis.emittedTokenIDs,
                scorer: &scorer
            )
            if newProxyLogp.isFinite {
                var inserted = hypothesis
                inserted.j += 1
                inserted.channelCost += config.beta
                inserted.lmScore = hypothesis.lmScore - baseState.proxyLogp + newProxyLogp
                inserted.score = inserted.lmScore - inserted.channelCost
                var insertedState = baseState
                insertedState.proxyLogp = newProxyLogp
                inserted.romanState = insertedState
                immediate.append(inserted)
            }
        }

        if observedChars.indices.contains(hypothesis.j + 1) {
            let observed2 = observedChars[hypothesis.j + 1]
            if observed != observed2 {
                addAdvance(trueSeq: [observed2, observed], observedCount: 2, channelAdd: config.gamma)
            }
        }

        return (immediate, deferred)
    }

    private static func expandRoman2KanaWithDeferred(
        beam: [Hypothesis],
        observedChars: [Character],
        scorer: inout LMScorer,
        config: ZenzaiTypoSearchConfig
    ) -> (expanded: [Hypothesis], allConsumed: Bool) {
        var heap = FixedSizeHeap<ScoredHypothesis>(size: max(1, config.beamSize))
        var deferredRequests: [RomanDeferredRequest] = []
        var allConsumed = true

        for hypothesis in beam {
            if hypothesis.j >= observedChars.count {
                _ = heap.insertIfPossible(ScoredHypothesis(hypothesis))
                continue
            }
            allConsumed = false
            let (immediate, deferred) = Self.expandRoman2KanaCandidates(
                hypothesis: hypothesis,
                observedChars: observedChars,
                scorer: &scorer,
                config: config
            )
            for candidate in immediate {
                _ = heap.insertIfPossible(ScoredHypothesis(candidate))
            }
            deferredRequests.append(contentsOf: deferred)
        }

        if !deferredRequests.isEmpty {
            deferredRequests.sort(by: { $0.upperBoundScore > $1.upperBoundScore })
            for request in deferredRequests {
                if heap.unordered.count >= max(1, config.beamSize),
                   let cutoff = heap.min?.score,
                   request.upperBoundScore < cutoff {
                    break
                }
                guard let evaluated = Self.evaluateRomanAdvance(
                    parent: request.parent,
                    baseState: request.baseState,
                    correctedAppend: request.correctedAppend,
                    observedCount: request.observedCount,
                    channelAdd: request.channelAdd,
                    emitted: request.emitted,
                    pending: request.pending,
                    lastInputChar: request.lastInputChar,
                    scorer: &scorer
                ) else {
                    continue
                }
                _ = heap.insertIfPossible(ScoredHypothesis(evaluated))
            }
        }

        let expanded = heap.unordered.sorted(by: { $0.score > $1.score }).map(\.hypothesis)
        return (expanded, allConsumed)
    }

    private static func evaluateRomanAdvance(
        parent: Hypothesis,
        baseState: RomanGeneratorState,
        correctedAppend: String,
        observedCount: Int,
        channelAdd: Float,
        emitted: String,
        pending: String,
        lastInputChar: Character,
        scorer: inout LMScorer
    ) -> Hypothesis? {
        let oldProxyLogp = baseState.proxyLogp
        guard oldProxyLogp.isFinite else {
            return nil
        }
        let baseLMScore = parent.lmScore - oldProxyLogp
        var emittedTokenIDs = parent.emittedTokenIDs
        var emittedLogp: Float = 0
        var prevEmittedChar = parent.prevEmittedChar
        if !emitted.isEmpty {
            guard let appended = scorer.appendAndScore(
                emittedTokenIDs: emittedTokenIDs,
                lmScore: 0,
                appendText: emitted
            ) else {
                return nil
            }
            emittedTokenIDs = appended.emittedTokenIDs
            emittedLogp = appended.lmScore
            prevEmittedChar = emitted.last
        }
        let newProxyLogp = Self.romanProxyLogProb(
            pending: pending,
            emittedTokenIDs: emittedTokenIDs,
            scorer: &scorer
        )
        guard newProxyLogp.isFinite else {
            return nil
        }

        var nextState = baseState
        nextState.pending = pending
        nextState.prevInputChar = lastInputChar
        nextState.proxyLogp = newProxyLogp

        var next = parent
        next.correctedInput += correctedAppend
        next.emittedText += emitted
        next.emittedTokenIDs = emittedTokenIDs
        next.lmScore = baseLMScore + emittedLogp + newProxyLogp
        next.channelCost += channelAdd
        next.score = next.lmScore - next.channelCost
        next.j += observedCount
        next.prevEmittedChar = prevEmittedChar
        next.romanState = nextState
        return next
    }

    private static func completeHypothesis(
        hypothesis: Hypothesis,
        observedChars: [Character],
        mode: InputMode,
        scorer: inout LMScorer
    ) -> Hypothesis? {
        if hypothesis.j >= observedChars.count {
            return hypothesis
        }
        var completed = hypothesis
        while completed.j < observedChars.count {
            let observed = observedChars[completed.j]
            switch mode {
            case .flick:
                guard let appended = scorer.appendAndScore(
                    emittedTokenIDs: completed.emittedTokenIDs,
                    lmScore: completed.lmScore,
                    appendText: String(observed)
                ) else {
                    return nil
                }
                completed.correctedInput += String(observed)
                completed.emittedText += String(observed)
                completed.emittedTokenIDs = appended.emittedTokenIDs
                completed.lmScore = appended.lmScore
                completed.score = completed.lmScore - completed.channelCost
                completed.prevEmittedChar = observed
                completed.j += 1
            case .roman2kana:
                guard var state = completed.romanState else {
                    return nil
                }
                let oldProxyLogp = state.proxyLogp
                guard oldProxyLogp.isFinite else {
                    return nil
                }
                let baseLMScore = completed.lmScore - oldProxyLogp
                let consumed = Self.romanConsumeWithEmission(pending: state.pending, newChar: observed)
                var emittedTokenIDs = completed.emittedTokenIDs
                var emittedLogp: Float = 0
                if !consumed.emitted.isEmpty {
                    guard let appended = scorer.appendAndScore(
                        emittedTokenIDs: emittedTokenIDs,
                        lmScore: 0,
                        appendText: consumed.emitted
                    ) else {
                        return nil
                    }
                    emittedTokenIDs = appended.emittedTokenIDs
                    emittedLogp = appended.lmScore
                    completed.prevEmittedChar = consumed.emitted.last
                    completed.emittedText += consumed.emitted
                }
                let newProxyLogp = Self.romanProxyLogProb(
                    pending: consumed.pending,
                    emittedTokenIDs: emittedTokenIDs,
                    scorer: &scorer
                )
                guard newProxyLogp.isFinite else {
                    return nil
                }
                state.pending = consumed.pending
                state.prevInputChar = observed
                state.proxyLogp = newProxyLogp
                completed.romanState = state
                completed.correctedInput += String(observed)
                completed.emittedTokenIDs = emittedTokenIDs
                completed.lmScore = baseLMScore + emittedLogp + newProxyLogp
                completed.score = completed.lmScore - completed.channelCost
                completed.j += 1
            }
        }
        return completed
    }

    private static func romanConsumeWithEmission(pending: String, newChar: Character) -> (emitted: String, pending: String) {
        if let punct = Self.romanPunctMap[newChar] {
            var emitted: [String] = []
            if pending == "n" {
                emitted.append("ン")
            } else if !pending.isEmpty {
                return ("", pending)
            }
            emitted.append(punct)
            return (emitted.joined(), "")
        }

        var buffer = pending + String(newChar)
        var emitted: [String] = []
        while !buffer.isEmpty {
            let chars = Array(buffer)
            if chars.count >= 2, chars[0] == chars[1], Self.romanConsonants.contains(chars[0]), chars[0] != "n" {
                emitted.append("ッ")
                buffer.removeFirst()
                continue
            }
            if chars.count >= 2, chars[0] == "n", chars[1] == "n" {
                emitted.append("ン")
                buffer.removeFirst()
                continue
            }
            if chars.count >= 2, chars[0] == "n", !Self.romanVowels.contains(chars[1]), !["y", "n"].contains(chars[1]) {
                emitted.append("ン")
                buffer.removeFirst()
                continue
            }

            var matched = false
            let maxSize = min(3, buffer.count)
            for size in stride(from: maxSize, through: 1, by: -1) {
                let key = String(buffer.prefix(size))
                if key == "n" {
                    if buffer.count == 1 {
                        continue
                    }
                    let nextChar = Array(buffer)[1]
                    if Self.romanVowels.contains(nextChar) || nextChar == "y" {
                        continue
                    }
                }
                guard let output = Self.romanToKana[key] else {
                    continue
                }
                emitted.append(output)
                buffer.removeFirst(size)
                matched = true
                break
            }
            if matched {
                continue
            }
            break
        }
        return (emitted.joined(), buffer)
    }

    private static func romanPendingToMixedDisplay(_ pending: String) -> String {
        guard !pending.isEmpty else {
            return ""
        }
        var buffer = ""
        var output: [String] = []
        for char in pending {
            let consumed = Self.romanConsumeWithEmission(pending: buffer, newChar: char)
            if !consumed.emitted.isEmpty {
                output.append(consumed.emitted)
            }
            buffer = consumed.pending
            while !buffer.isEmpty, !Self.romanPrefixes.contains(buffer) {
                output.append(String(buffer.removeFirst()))
            }
        }
        if buffer == "n" {
            output.append("n")
        } else if !buffer.isEmpty {
            output.append(buffer)
        }
        return output.joined()
    }

    private static func romanProxyLogProb(
        pending: String,
        emittedTokenIDs: [llama_token],
        scorer: inout LMScorer
    ) -> Float {
        guard !pending.isEmpty else {
            return 0
        }
        let firstTokenIDs = Self.romanPendingFirstTokenIDs(pending: pending, scorer: &scorer)
        guard !firstTokenIDs.isEmpty,
              let nextLogProbs = scorer.nextLogProbsForPrefix(emittedTokenIDs: emittedTokenIDs) else {
            return -.infinity
        }
        var maxLogProb: Float = -.infinity
        for tokenID in firstTokenIDs {
            let index = Int(tokenID)
            guard nextLogProbs.indices.contains(index) else {
                continue
            }
            let value = nextLogProbs[index]
            if value > maxLogProb {
                maxLogProb = value
            }
        }
        guard maxLogProb.isFinite else {
            return -.infinity
        }
        var sumExp: Float = 0
        for tokenID in firstTokenIDs {
            let index = Int(tokenID)
            guard nextLogProbs.indices.contains(index) else {
                continue
            }
            sumExp += expf(nextLogProbs[index] - maxLogProb)
        }
        guard sumExp > 0 else {
            return -.infinity
        }
        return maxLogProb + logf(sumExp)
    }

    private static func romanPendingFirstTokenIDs(
        pending: String,
        scorer: inout LMScorer
    ) -> [llama_token] {
        var tokenIDs: Set<llama_token> = []
        for probe in Self.romanProbeChars {
            let consumed = Self.romanConsumeWithEmission(pending: pending, newChar: probe)
            guard let firstChar = consumed.emitted.first else {
                continue
            }
            let firstToken = scorer.encodeRaw(String(firstChar))
            if firstToken.count == 1, let tokenID = firstToken.first {
                tokenIDs.insert(tokenID)
            }
        }
        return tokenIDs.sorted()
    }

}
