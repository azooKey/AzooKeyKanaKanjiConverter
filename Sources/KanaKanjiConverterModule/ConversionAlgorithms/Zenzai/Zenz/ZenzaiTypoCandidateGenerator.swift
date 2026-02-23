#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import Foundation
import OrderedCollections
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

    private enum TypoChannel {
        case qwerty
        case tenkey
    }

    private enum ObservedSource {
        case convertTarget
        case composingInput
    }

    private struct InputMode {
        var table: InputTable
        var channel: TypoChannel
        var observedSource: ObservedSource
        var usesInputCharacterLMFilter: Bool {
            self.observedSource == .convertTarget
        }
    }

    private struct ObservedElement: Sendable {
        var inputPiece: InputPiece
        var character: Character
    }

    private struct GeneratorState: Sendable, Equatable, Hashable {
        var pending: String
        var prevInputPiece: InputPiece?
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
        var generatorState: GeneratorState?
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

    private struct DeferredRequest {
        var parent: Hypothesis
        var baseState: GeneratorState
        var correctedAppend: String
        var observedCount: Int
        var channelAdd: Float
        var emitted: String
        var pending: String
        var lastInputPiece: InputPiece
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

    private static let tenkeyGroups: [String] = [
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
        "m": ["j", "k", "n"],
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

    private static let tenkeyNeighbors: [Character: Set<Character>] = {
        var result: [Character: Set<Character>] = [:]
        for group in Self.tenkeyGroups {
            let chars = Array(group)
            for c in chars {
                result[c] = Set(chars.filter { $0 != c })
            }
        }
        return result
    }()

    private static func substitutionNeighbors(observed: Character, channel: TypoChannel) -> Set<Character> {
        switch channel {
        case .qwerty:
            Self.qwertyNeighbors[observed, default: []]
        case .tenkey:
            Self.tenkeyNeighbors[observed, default: []]
        }
    }

    private static func canonicalCharacter(for piece: InputPiece) -> Character? {
        let raw: Character?
        switch piece {
        case let .character(c):
            raw = c
        case let .key(intention: intention, input: input, modifiers: _):
            raw = intention ?? input
        case .compositionSeparator:
            raw = nil
        }
        guard let raw else {
            return nil
        }
        let lowered = String(raw).lowercased()
        return lowered.first ?? raw
    }

    private static func substitutionNeighbors(observed piece: InputPiece, channel: TypoChannel) -> Set<Character> {
        guard let observed = Self.canonicalCharacter(for: piece) else {
            return []
        }
        return Self.substitutionNeighbors(observed: observed, channel: channel)
    }

    private static func insertionNeighbors(prev: Character, channel: TypoChannel) -> Set<Character> {
        switch channel {
        case .qwerty:
            Self.qwertyNeighbors[prev, default: []]
        case .tenkey:
            Self.tenkeyNeighbors[prev, default: []]
        }
    }

    private static func insertionNeighbors(prev piece: InputPiece, channel: TypoChannel) -> Set<Character> {
        guard let prev = Self.canonicalCharacter(for: piece) else {
            return []
        }
        return Self.insertionNeighbors(prev: prev, channel: channel)
    }

    static func generate(
        context: ZenzContext,
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        searchConfig: ZenzaiTypoSearchConfig
    ) -> [ZenzaiTypoCandidate] {
        let mode = Self.resolveInputMode(inputStyle: inputStyle)
        let observedElements = Self.observedElements(composingText: composingText, source: mode.observedSource)
        let observedChars = observedElements.map(\.character)
        guard !observedChars.isEmpty else {
            return []
        }
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
                generatorState: .init(pending: "", prevInputPiece: nil, proxyLogp: 0)
            )
        ]

        for _ in 0..<maxSteps {
            let result = Self.expandWithDeferred(
                beam: beam,
                observedElements: observedElements,
                table: mode.table,
                channel: mode.channel,
                useInputCharacterLMFilter: mode.usesInputCharacterLMFilter,
                scorer: &scorer,
                config: searchConfig
            )
            let expanded = result.expanded
            let allConsumed = result.allConsumed
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
                    observedElements: observedElements,
                    table: mode.table,
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
            let convertedText = hypothesis.emittedText + Self.pendingToDisplayText(hypothesis.generatorState?.pending ?? "", table: mode.table)
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
        case .roman2kana:
            return .init(
                table: InputStyleManager.shared.table(for: .defaultRomanToKana),
                channel: .qwerty,
                observedSource: .composingInput
            )
        case .mapped(let id):
            let table = InputStyleManager.shared.table(for: id)
            if !table.possibleNexts.isEmpty {
                return .init(table: table, channel: .qwerty, observedSource: .composingInput)
            } else {
                return .init(table: .empty, channel: .tenkey, observedSource: .convertTarget)
            }
        default:
            return .init(table: .empty, channel: .tenkey, observedSource: .convertTarget)
        }
    }

    private static func observedElements(composingText: ComposingText, source: ObservedSource) -> [ObservedElement] {
        if source == .convertTarget {
            return composingText.convertTarget.toKatakana().map {
                ObservedElement(inputPiece: .character($0), character: $0)
            }
        }
        var result: [ObservedElement] = []
        result.reserveCapacity(composingText.input.count)
        for element in composingText.input {
            guard let normalized = Self.canonicalCharacter(for: element.piece) else {
                continue
            }
            result.append(.init(inputPiece: element.piece, character: normalized))
        }
        return result
    }

    private static func expandCandidates(
        hypothesis: Hypothesis,
        observedElements: [ObservedElement],
        table: InputTable,
        channel: TypoChannel,
        useInputCharacterLMFilter: Bool,
        scorer: inout LMScorer,
        config: ZenzaiTypoSearchConfig
    ) -> (immediate: [Hypothesis], deferred: [DeferredRequest]) {
        guard observedElements.indices.contains(hypothesis.j), let baseState = hypothesis.generatorState else {
            return ([hypothesis], [])
        }
        let observedElement = observedElements[hypothesis.j]
        let observed = observedElement.character
        let isInputTail = hypothesis.j == observedElements.count - 1
        var allowed = Set([observed])
        allowed.formUnion(Self.substitutionNeighbors(observed: observedElement.inputPiece, channel: channel))
        let targetChars: [Character]
        if useInputCharacterLMFilter {
            let lmTopChars = Set(scorer.topKCharacters(emittedTokenIDs: hypothesis.emittedTokenIDs, k: config.topK))
            let scoredTargets = allowed.intersection(lmTopChars.union([observed]))
            targetChars = scoredTargets.isEmpty ? [observed] : scoredTargets.sorted(by: { $0 < $1 })
        } else {
            targetChars = allowed.sorted(by: { $0 < $1 })
        }
        var immediate: [Hypothesis] = []
        immediate.reserveCapacity(20)
        var deferred: [DeferredRequest] = []
        deferred.reserveCapacity(8)

        func addAdvance(trueSeq: [Character], observedCount: Int, channelAdd: Float, lastInputPiece: InputPiece) {
            guard let last = trueSeq.last else {
                return
            }
            var pending = baseState.pending
            var emitted = ""
            for char in trueSeq {
                let consumed = Self.consumeWithEmission(pending: pending, newChar: char, table: table)
                emitted += consumed.emitted
                pending = consumed.pending
            }
            let reachesTail = hypothesis.j + observedCount - 1 == observedElements.count - 1
            if reachesTail, !pending.isEmpty {
                let observedLast = observedElements[hypothesis.j + observedCount - 1].character
                if last != observedLast || channelAdd > 0 {
                    return
                }
            }
            if emitted.isEmpty {
                if let evaluated = Self.evaluateAdvance(
                    parent: hypothesis,
                    baseState: baseState,
                    correctedAppend: String(trueSeq),
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece,
                    table: table,
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
                if let evaluated = Self.evaluateAdvance(
                    parent: hypothesis,
                    baseState: baseState,
                    correctedAppend: String(trueSeq),
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece,
                    table: table,
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
                DeferredRequest(
                    parent: hypothesis,
                    baseState: baseState,
                    correctedAppend: String(trueSeq),
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece,
                    upperBoundScore: upperBoundScore
                )
            )
        }

        for target in targetChars {
            let isIdentity = target == observed
            addAdvance(
                trueSeq: [target],
                observedCount: 1,
                channelAdd: isIdentity ? 0 : config.alpha,
                lastInputPiece: isIdentity ? observedElement.inputPiece : .character(target)
            )
        }

        if !isInputTail,
           let prevInput = baseState.prevInputPiece,
           Self.insertionNeighbors(prev: prevInput, channel: channel).contains(observed) {
            let newProxyLogp = Self.pendingProxyLogProb(
                pending: baseState.pending,
                emittedTokenIDs: hypothesis.emittedTokenIDs,
                table: table,
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
                inserted.generatorState = insertedState
                immediate.append(inserted)
            }
        }

        if observedElements.indices.contains(hypothesis.j + 1) {
            let observed2 = observedElements[hypothesis.j + 1].character
            if observed != observed2 {
                addAdvance(
                    trueSeq: [observed2, observed],
                    observedCount: 2,
                    channelAdd: config.gamma,
                    lastInputPiece: observedElement.inputPiece
                )
            }
        }

        return (immediate, deferred)
    }

    private static func expandWithDeferred(
        beam: [Hypothesis],
        observedElements: [ObservedElement],
        table: InputTable,
        channel: TypoChannel,
        useInputCharacterLMFilter: Bool,
        scorer: inout LMScorer,
        config: ZenzaiTypoSearchConfig
    ) -> (expanded: [Hypothesis], allConsumed: Bool) {
        var heap = FixedSizeHeap<ScoredHypothesis>(size: max(1, config.beamSize))
        var deferredRequests: [DeferredRequest] = []
        var allConsumed = true

        for hypothesis in beam {
            if hypothesis.j >= observedElements.count {
                _ = heap.insertIfPossible(ScoredHypothesis(hypothesis))
                continue
            }
            allConsumed = false
            let (immediate, deferred) = Self.expandCandidates(
                hypothesis: hypothesis,
                observedElements: observedElements,
                table: table,
                channel: channel,
                useInputCharacterLMFilter: useInputCharacterLMFilter,
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
                guard let evaluated = Self.evaluateAdvance(
                    parent: request.parent,
                    baseState: request.baseState,
                    correctedAppend: request.correctedAppend,
                    observedCount: request.observedCount,
                    channelAdd: request.channelAdd,
                    emitted: request.emitted,
                    pending: request.pending,
                    lastInputPiece: request.lastInputPiece,
                    table: table,
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

    private static func evaluateAdvance(
        parent: Hypothesis,
        baseState: GeneratorState,
        correctedAppend: String,
        observedCount: Int,
        channelAdd: Float,
        emitted: String,
        pending: String,
        lastInputPiece: InputPiece,
        table: InputTable,
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
        let newProxyLogp = Self.pendingProxyLogProb(
            pending: pending,
            emittedTokenIDs: emittedTokenIDs,
            table: table,
            scorer: &scorer
        )
        guard newProxyLogp.isFinite else {
            return nil
        }

        var nextState = baseState
        nextState.pending = pending
        nextState.prevInputPiece = lastInputPiece
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
        next.generatorState = nextState
        return next
    }

    private static func completeHypothesis(
        hypothesis: Hypothesis,
        observedChars: [Character],
        observedElements: [ObservedElement],
        table: InputTable,
        scorer: inout LMScorer
    ) -> Hypothesis? {
        if hypothesis.j >= observedChars.count {
            return hypothesis
        }
        var completed = hypothesis
        while completed.j < observedChars.count {
            let observed = observedChars[completed.j]
            guard var state = completed.generatorState else {
                return nil
            }
            let oldProxyLogp = state.proxyLogp
            guard oldProxyLogp.isFinite else {
                return nil
            }
            let baseLMScore = completed.lmScore - oldProxyLogp
            let consumed = Self.consumeWithEmission(
                pending: state.pending,
                newChar: observed,
                table: table
            )
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
            let newProxyLogp = Self.pendingProxyLogProb(
                pending: consumed.pending,
                emittedTokenIDs: emittedTokenIDs,
                table: table,
                scorer: &scorer
            )
            guard newProxyLogp.isFinite else {
                return nil
            }
            let observedPiece: InputPiece = if observedElements.indices.contains(completed.j) {
                observedElements[completed.j].inputPiece
            } else {
                .character(observed)
            }
            state.pending = consumed.pending
            state.prevInputPiece = observedPiece
            state.proxyLogp = newProxyLogp
            completed.generatorState = state
            completed.correctedInput += String(observed)
            completed.emittedTokenIDs = emittedTokenIDs
            completed.lmScore = baseLMScore + emittedLogp + newProxyLogp
            completed.score = completed.lmScore - completed.channelCost
            completed.j += 1
        }
        return completed
    }

    private static func consumeWithEmission(
        pending: String,
        newChar: Character,
        table: InputTable
    ) -> (emitted: String, pending: String) {
        let raw = pending + String(newChar)
        let converted = Self.applyInputTable(raw: raw, table: table)
        let nextPending = Self.pendingSuffix(raw: raw, converted: converted, table: table)
        guard !nextPending.isEmpty else {
            return (converted, "")
        }
        guard converted.count >= nextPending.count else {
            return ("", nextPending)
        }
        return (String(converted.dropLast(nextPending.count)), nextPending)
    }

    private static func pendingToDisplayText(_ pending: String, table _: InputTable) -> String {
        guard !pending.isEmpty else {
            return ""
        }
        return pending
    }

    private static func applyInputTable(raw: String, table: InputTable) -> String {
        guard !raw.isEmpty else {
            return ""
        }
        var buffer: [Character] = []
        buffer.reserveCapacity(raw.count)
        for char in raw {
            table.apply(to: &buffer, added: .character(char))
        }
        return String(buffer).toKatakana()
    }

    private static func pendingSuffix(raw: String, converted: String, table: InputTable) -> String {
        guard !raw.isEmpty else {
            return ""
        }
        let rawChars = Array(raw)
        for length in stride(from: rawChars.count, through: 1, by: -1) {
            let suffix = String(rawChars.suffix(length))
            guard Self.hasContinuation(pending: suffix, table: table) else {
                continue
            }
            let suffixDisplay = Self.applyInputTable(raw: suffix, table: table)
            guard suffixDisplay == suffix, converted.hasSuffix(suffixDisplay) else {
                continue
            }
            return suffix
        }
        return ""
    }

    private static func hasContinuation(pending: String, table: InputTable) -> Bool {
        if !table.possibleNexts[pending, default: []].isEmpty {
            return true
        }
        let pendingChars = Array(pending)
        guard !pendingChars.isEmpty else {
            return false
        }
        for key in table.baseMapping.keys {
            guard key.count > pendingChars.count else {
                continue
            }
            var matched = true
            for (index, char) in pendingChars.enumerated() {
                guard key.indices.contains(index) else {
                    matched = false
                    break
                }
                guard case let .piece(piece) = key[index], case let .character(c) = piece, c == char else {
                    matched = false
                    break
                }
            }
            if matched {
                return true
            }
        }
        return false
    }

    private static func possibleNextDisplays(pending: String, table: InputTable) -> [String] {
        var result = Set(table.possibleNexts[pending, default: []].map { $0.toKatakana() })
        let pendingChars = Array(pending)
        guard !pendingChars.isEmpty else {
            return result.sorted()
        }

        for (key, value) in table.baseMapping {
            guard let any1Index = key.firstIndex(where: {
                if case .any1 = $0 {
                    return true
                }
                return false
            }), any1Index == key.count - 1 else {
                continue
            }
            let keyPrefix = key.prefix(any1Index).compactMap { element -> Character? in
                guard case let .piece(piece) = element, case let .character(c) = piece else {
                    return nil
                }
                return c
            }
            guard keyPrefix.count == any1Index, keyPrefix.elementsEqual(pendingChars) else {
                continue
            }
            let outputPrefix = value.prefix {
                if case .any1 = $0 {
                    return false
                }
                return true
            }.compactMap { element -> Character? in
                guard case let .character(c) = element else {
                    return nil
                }
                return c
            }
            if !outputPrefix.isEmpty {
                result.insert(String(outputPrefix).toKatakana())
            }
        }
        return result.sorted()
    }

    private static func pendingProxyLogProb(
        pending: String,
        emittedTokenIDs: [llama_token],
        table: InputTable,
        scorer: inout LMScorer
    ) -> Float {
        guard !pending.isEmpty else {
            return 0
        }
        let firstTokenIDs = Self.pendingFirstTokenIDs(pending: pending, table: table, scorer: &scorer)
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

    private static func pendingFirstTokenIDs(
        pending: String,
        table: InputTable,
        scorer: inout LMScorer
    ) -> [llama_token] {
        var tokenIDs: Set<llama_token> = []
        let possibleNexts = Self.possibleNextDisplays(pending: pending, table: table)
        guard !possibleNexts.isEmpty else {
            return []
        }
        for next in possibleNexts {
            guard let firstChar = next.first else {
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
