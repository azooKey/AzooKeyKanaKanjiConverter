#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import Foundation
import OrderedCollections
import SwiftUtils

/// Typo探索の探索幅・誤りコスト重みをまとめた設定。
public struct ZenzaiTypoSearchConfig: Sendable, Equatable, Hashable {
    public init(
        beamSize: Int = 32,
        topK: Int = 64,
        nBest: Int = 5,
        maxSteps: Int? = nil,
        alpha: Float = 2.0,
        beta: Float = 3.0,
        gamma: Float = 2.0
    ) {
        self.beamSize = max(1, beamSize)
        self.topK = max(1, topK)
        self.nBest = max(1, nBest)
        self.maxSteps = maxSteps
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
    }

    public var beamSize: Int
    public var topK: Int
    public var nBest: Int
    public var maxSteps: Int?
    /// 1文字置換のチャネルコスト。
    public var alpha: Float
    /// 1文字脱落（観測文字のスキップ）のチャネルコスト。
    public var beta: Float
    /// 隣接2文字の転置のチャネルコスト。
    public var gamma: Float
}

/// typo探索の最終出力候補。
public struct ZenzaiTypoCandidate: Sendable, Equatable, Hashable {
    public init(
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

    /// 訂正後の入力列（入力チャネル側）。
    public var correctedInput: String
    /// `InputTable` 適用後の表示文字列（変換チャネル側）。
    public var convertedText: String
    /// 総合スコア。`lmScore - channelCost`。
    public var score: Float
    /// 言語モデルの対数確率スコア。
    public var lmScore: Float
    /// typoチャネル由来の累積コスト。
    public var channelCost: Float
    /// best候補比の相対重み。
    public var prominence: Float
}

/// セッション跨ぎで typo 探索のLM補助キャッシュを保持するコンテナ。
final class ZenzaiTypoGenerationCache {
    fileprivate var prompt: String = ""
    fileprivate var promptTokenIDs: [llama_token] = []
    fileprivate var vocabSize: Int = 0
    fileprivate var nextLogProbCache: [[llama_token]: [Float]] = [:]
    fileprivate var encodeCache: [String: [llama_token]] = [:]
    fileprivate var tokenCharCache: [llama_token: Character?] = [:]

    func invalidateAll() {
        self.prompt = ""
        self.promptTokenIDs = []
        self.vocabSize = 0
        self.nextLogProbCache = [:]
        self.encodeCache = [:]
        self.tokenCharCache = [:]
    }

    func invalidateForModelChange() {
        self.nextLogProbCache = [:]
        self.encodeCache = [:]
        self.tokenCharCache = [:]
    }
}

/// キー配置ごとの近傍分布を表すトポロジー。
private struct KeyTopology: Sendable {
    enum ID: String, Sendable {
        case macOSStandardQwerty
        case iOSStandardQwerty
        case iOSStandardFlickTenkey
    }

    let id: ID
    private let neighborDistancesByCharacter: [Character: [Character: Float]]

    func neighborDistances(around character: Character) -> [Character: Float] {
        self.neighborDistancesByCharacter[character, default: [:]]
    }

    /// magic keyboardの配置を基にしたQWERTY近傍座標。単位距離はキー間隔1つ分。
    static let macOSStandardQwerty = KeyTopology(
        id: .macOSStandardQwerty,
        neighborDistancesByCharacter: Self.buildCoordinateNeighborDistances(
            coordinates: [
                "1": (-1.0, 0), "2": (0.25, 0), "3": (1.25, 0), "4": (2.25, 0), "5": (3.25, 0), "6": (4.25, 0), "7": (5.25, 0), "8": (6.25, 0), "9": (7.25, 0), "0": (8.25, 0), "-": (9.25, 0), "^": (10.25, 0),
                "q": (0.00, 1), "w": (1.00, 1), "e": (2.00, 1), "r": (3.00, 1), "t": (4.00, 1), "y": (5.00, 1), "u": (6.00, 1), "i": (7.00, 1), "o": (8.00, 1), "p": (9.00, 1), "@": (10.00, 1), "[": (11.00, 1),
                "a": (0.25, 2), "s": (1.25, 2), "d": (2.25, 2), "f": (3.25, 2), "g": (4.25, 2), "h": (5.25, 2), "j": (6.25, 2), "k": (7.25, 2), "l": (8.25, 2), ";": (9.25, 2), "]": (10.25, 2),
                "z": (0.80, 3), "x": (1.80, 3), "c": (2.80, 3), "v": (3.80, 3), "b": (4.80, 3), "n": (5.80, 3), "m": (6.80, 3), ",": (7.80, 3), ".": (8.80, 3), "/": (9.80, 3), "_": (10.80, 3),
            ]
        )
    )

    /// iOSのフルキーボード配置を基にしたQWERTY近傍座標。単位距離はキー間隔1つ分。Macと比べて横幅が狭く、縦幅が広い。
    static let iOSStandardQwerty = KeyTopology(
        id: .iOSStandardQwerty,
        neighborDistancesByCharacter: Self.buildCoordinateNeighborDistances(
            coordinates: [
                "q": (0.00, 1.0), "w": (1.00, 1.0), "e": (2.00, 1.0), "r": (3.00, 1.0), "t": (4.00, 1.0), "y": (5.00, 1.0), "u": (6.00, 1.0), "i": (7.00, 1.0), "o": (8.00, 1.0), "p": (9.00, 1.0),
                "a": (0.50, 2.5), "s": (1.50, 2.5), "d": (2.50, 2.5), "f": (3.50, 2.5), "g": (4.50, 2.5), "h": (5.50, 2.5), "j": (6.50, 2.5), "k": (7.50, 2.5), "l": (8.50, 2.5),
                "z": (1.50, 4.0), "x": (2.50, 4.0), "c": (3.50, 4.0), "v": (4.50, 4.0), "b": (5.50, 4.0), "n": (6.50, 4.0), "m": (7.50, 4.0),
            ]
        )
    )

    static let iOSStandardFlickTenkey = KeyTopology(
        id: .iOSStandardFlickTenkey,
        neighborDistancesByCharacter: Self.buildTenkeyNeighborDistances(groups: [
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
        ])
    )

    private static func buildCoordinateNeighborSets(
        coordinates: [Character: (x: Float, y: Float)],
        neighborMaxDistance: Float = 1.65
    ) -> [Character: Set<Character>] {
        var result: [Character: Set<Character>] = [:]
        result.reserveCapacity(coordinates.count)
        for (source, sourcePoint) in coordinates {
            var neighbors: Set<Character> = []
            for (target, targetPoint) in coordinates where target != source {
                let dx = sourcePoint.x - targetPoint.x
                let dy = sourcePoint.y - targetPoint.y
                let distance = sqrtf(dx * dx + dy * dy)
                if distance <= neighborMaxDistance {
                    neighbors.insert(target)
                }
            }
            if !neighbors.isEmpty {
                result[source] = neighbors
            }
        }
        return result
    }
        

    private static func coordinateDistance(
        _ from: Character,
        _ to: Character,
        coordinates: [Character: (x: Float, y: Float)]
    ) -> Float {
        guard let lhs = coordinates[from], let rhs = coordinates[to] else {
            return 1.0
        }
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrtf(dx * dx + dy * dy)
    }

    private static func buildCoordinateNeighborDistances(
        coordinates: [Character: (x: Float, y: Float)]
    ) -> [Character: [Character: Float]] {
        let neighborSets = Self.buildCoordinateNeighborSets(coordinates: coordinates)
        var result: [Character: [Character: Float]] = [:]
        for (source, neighbors) in neighborSets {
            var map: [Character: Float] = [:]
            map.reserveCapacity(neighbors.count)
            for neighbor in neighbors {
                map[neighbor] = Self.coordinateDistance(source, neighbor, coordinates: coordinates)
            }
            result[source] = map
        }
        return result
    }

    private static func buildTenkeyNeighborDistances(groups: [String]) -> [Character: [Character: Float]] {
        var result: [Character: [Character: Float]] = [:]
        for group in groups {
            let chars = Array(group)
            for c in chars {
                var neighbors: [Character: Float] = [:]
                for other in chars where other != c {
                    neighbors[other] = 1.0
                }
                result[c] = neighbors
            }
        }
        return result
    }
}

enum ZenzaiTypoCandidateGenerator {
    /// 観測入力をどこから組み立てるかを示す種別。
    /// - convertTarget: 画面上の変換対象文字列を使う（direct/tenkey向け）
    /// - composingInput: InputPiece列から組み立てる（roman/mapped向け）
    private enum ObservedSource {
        case convertTarget
        case composingInput
    }

    /// 実行時に解決された typo 生成条件。
    private struct TypoGenerationConfig {
        var table: InputTable
        var keyTopology: KeyTopology
        var observedSource: ObservedSource
        var usesInputCharacterLMFilter: Bool {
            self.observedSource == .convertTarget
        }
    }

    /// 探索で扱う観測単位（元のInputPieceと正規化済み文字）。
    private struct ObservedElement: Sendable {
        var inputPiece: InputPiece
        var character: Character
    }

    /// 各仮説に持たせるInputTable消費状態。
    /// `pending` は未確定の入力サフィックス、`proxyLogp` はその先読み確率。
    private struct GeneratorState: Sendable, Equatable, Hashable {
        var pending: String
        var prevInputPiece: InputPiece?
        var proxyLogp: Float
    }

    /// 探索中の1仮説。
    private struct Hypothesis: Sendable {
        var correctedInput: String
        var emittedText: String
        var emittedTokenIDs: [llama_token]
        /// 何文字の観測入力を消費したかを示すインデックス。
        var j: Int
        var prevEmittedChar: Character?
        var score: Float
        var lmScore: Float
        var channelCost: Float
        var generatorState: GeneratorState?
    }

    /// ヒープ管理用の軽量ラッパー。
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

    /// deferred評価キューに積む未評価展開。
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

    /// 次トークン分布と文字列->token変換をキャッシュするLMスコアラー。
    private struct LMScorer {
        private let context: ZenzContext
        private let cache: ZenzaiTypoGenerationCache
        private let maxNewNextLogProbCacheEntries: Int?
        private var createdNextLogProbCacheEntries: Int = 0

        init(
            context: ZenzContext,
            leftSideContext: String,
            cache: ZenzaiTypoGenerationCache,
            maxNewNextLogProbCacheEntries: Int?
        ) {
            self.context = context
            self.cache = cache
            self.maxNewNextLogProbCacheEntries = maxNewNextLogProbCacheEntries
            self.preparePrompt(leftSideContext: leftSideContext)
        }

        private func preparePrompt(leftSideContext: String) {
            let vocabSize = Int(self.context.vocabSize)
            if self.cache.vocabSize != 0, self.cache.vocabSize != vocabSize {
                self.cache.invalidateAll()
            }
            self.cache.vocabSize = vocabSize
            let prompt = ZenzPromptBuilder.typoCorrectionPromptPrefix(leftSideContext: leftSideContext)
            if self.cache.prompt != prompt || self.cache.promptTokenIDs.isEmpty {
                self.cache.prompt = prompt
                self.cache.promptTokenIDs = self.context.encodeRaw(prompt, addBOS: false, addEOS: false)
                self.cache.nextLogProbCache = [:]
            }
        }

        mutating func encodeRaw(_ text: String) -> [llama_token] {
            if let cached = self.cache.encodeCache[text] {
                return cached
            }
            let tokenIDs = self.context.encodeRaw(text, addBOS: false, addEOS: false)
            self.cache.encodeCache[text] = tokenIDs
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

        mutating func appendAndScore(
            emittedTokenIDs: [llama_token],
            lmScore: Float,
            appendText: String
        ) -> (emittedTokenIDs: [llama_token], lmScore: Float)? {
            let appendTokenIDs = self.encodeRaw(appendText)
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
            if let cached = self.cache.tokenCharCache[token] {
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
            self.cache.tokenCharCache[token] = char
            return char
        }

        mutating func nextLogProbs(emittedTokenIDs: [llama_token]) -> [Float]? {
            if let cached = self.cache.nextLogProbCache[emittedTokenIDs] {
                return cached
            }
            if let maxNewNextLogProbCacheEntries,
               self.createdNextLogProbCacheEntries >= maxNewNextLogProbCacheEntries {
                return nil
            }
            let fullTokenIDs = self.cache.promptTokenIDs + emittedTokenIDs
            guard !fullTokenIDs.isEmpty else {
                return nil
            }
            let startOffset = fullTokenIDs.count - 1
            guard let logits = self.context.inputPredictionLogits(tokens: fullTokenIDs, startOffset: startOffset) else {
                return nil
            }
            var values: [Float] = Array(repeating: 0, count: self.cache.vocabSize)
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
            self.cache.nextLogProbCache[emittedTokenIDs] = values
            self.createdNextLogProbCacheEntries += 1
            return values
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

    private static func neighborDistances(for piece: InputPiece, topology: KeyTopology) -> [Character: Float] {
        guard let observed = Self.canonicalCharacter(for: piece) else {
            return [:]
        }
        return topology.neighborDistances(around: observed)
    }

    static func generate(
        context: ZenzContext,
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        searchConfig: ZenzaiTypoSearchConfig,
        cache: ZenzaiTypoGenerationCache,
        maxNewNextLogProbCacheEntries: Int?
    ) -> [ZenzaiTypoCandidate] {
        let mode = Self.resolveGenerationConfig(inputStyle: inputStyle)
        let observedElements = Self.observedElements(composingText: composingText, source: mode.observedSource)
        guard !observedElements.isEmpty else {
            return []
        }
        let maxSteps = searchConfig.maxSteps ?? (observedElements.count * 2 + 8)

        func initialHypothesis() -> Hypothesis {
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
        }

        var scorer = LMScorer(
            context: context,
            leftSideContext: leftSideContext,
            cache: cache,
            maxNewNextLogProbCacheEntries: maxNewNextLogProbCacheEntries
        )
        var beam: [Hypothesis] = [initialHypothesis()]

        for _ in 0..<maxSteps {
            let result = Self.expandWithDeferred(
                beam: beam,
                observedElements: observedElements,
                table: mode.table,
                keyTopology: mode.keyTopology,
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
            let consumed = beam.filter { $0.j == observedElements.count }
            if !consumed.isEmpty {
                return consumed
            }
            return beam.compactMap { hypothesis in
                Self.completeHypothesis(
                    hypothesis: hypothesis,
                    observedElements: observedElements,
                    table: mode.table,
                    scorer: &scorer
                )
            }
        }()

        var mergedFinals = finals
        // original入力をbeam探索と独立に明示採点し、比較基準を常に候補集合へ含める。
        if let explicitOriginal = Self.completeHypothesis(
            hypothesis: initialHypothesis(),
            observedElements: observedElements,
            table: mode.table,
            scorer: &scorer
        ) {
            mergedFinals.append(explicitOriginal)
        }

        guard !mergedFinals.isEmpty else {
            return []
        }
        let sorted = mergedFinals.sorted(by: { $0.score > $1.score })
        let bestScore = sorted[0].score

        var unique: [String: ZenzaiTypoCandidate] = [:]
        for hypothesis in sorted {
            let convertedText = hypothesis.emittedText + (hypothesis.generatorState?.pending ?? "")
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

    private static func resolveGenerationConfig(inputStyle: InputStyle) -> TypoGenerationConfig {
        switch inputStyle {
        case .roman2kana:
            return .init(
                table: InputStyleManager.shared.table(for: .defaultRomanToKana),
                keyTopology: .macOSStandardQwerty,
                observedSource: .composingInput
            )
        case .mapped(let id):
            let table = InputStyleManager.shared.table(for: id)
            if !table.possibleNexts.isEmpty {
                return .init(table: table, keyTopology: .iOSStandardQwerty, observedSource: .composingInput)
            } else {
                return .init(table: .empty, keyTopology: .iOSStandardFlickTenkey, observedSource: .convertTarget)
            }
        default:
            return .init(table: .empty, keyTopology: .iOSStandardFlickTenkey, observedSource: .convertTarget)
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
        keyTopology: KeyTopology,
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
        let neighborDistances = Self.neighborDistances(for: observedElement.inputPiece, topology: keyTopology)
        var allowed = Set([observed])
        allowed.formUnion(neighborDistances.keys)
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

        func appendImmediate(
            correctedAppend: String,
            observedCount: Int,
            channelAdd: Float,
            emitted: String,
            pending: String,
            lastInputPiece: InputPiece
        ) {
            if let evaluated = Self.evaluateAdvance(
                parent: hypothesis,
                baseState: baseState,
                correctedAppend: correctedAppend,
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
        }

        func evaluateOrDefer(
            correctedAppend: String,
            observedCount: Int,
            channelAdd: Float,
            emitted: String,
            pending: String,
            lastInputPiece: InputPiece
        ) {
            guard !emitted.isEmpty else {
                appendImmediate(
                    correctedAppend: correctedAppend,
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece
                )
                return
            }
            let oldProxyLogp = baseState.proxyLogp
            guard oldProxyLogp.isFinite else {
                return
            }
            let baseLMScore = hypothesis.lmScore - oldProxyLogp
            guard let firstChar = emitted.first else {
                appendImmediate(
                    correctedAppend: correctedAppend,
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece
                )
                return
            }
            let firstTokens = scorer.encodeRaw(String(firstChar))
            guard firstTokens.count == 1,
                  let firstToken = firstTokens.first,
                  let nextLogProbs = scorer.nextLogProbs(emittedTokenIDs: hypothesis.emittedTokenIDs)
            else {
                appendImmediate(
                    correctedAppend: correctedAppend,
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece
                )
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
                    correctedAppend: correctedAppend,
                    observedCount: observedCount,
                    channelAdd: channelAdd,
                    emitted: emitted,
                    pending: pending,
                    lastInputPiece: lastInputPiece,
                    upperBoundScore: upperBoundScore
                )
            )
        }

        func addAdvance(trueSeq: [Character], observedCount: Int, channelAdd: Float, lastInputPiece: InputPiece) {
            guard let last = trueSeq.last else {
                return
            }
            let correctedAppend = String(trueSeq)
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
            evaluateOrDefer(
                correctedAppend: correctedAppend,
                observedCount: observedCount,
                channelAdd: channelAdd,
                emitted: emitted,
                pending: pending,
                lastInputPiece: lastInputPiece
            )
        }

        for target in targetChars {
            let isIdentity = target == observed
            let substitutionDistance = neighborDistances[target] ?? 1.0
            addAdvance(
                trueSeq: [target],
                observedCount: 1,
                channelAdd: isIdentity ? 0 : (config.alpha * substitutionDistance),
                lastInputPiece: isIdentity ? observedElement.inputPiece : .character(target)
            )
        }

        if !isInputTail,
           let prevInput = baseState.prevInputPiece,
           let insertionDistance = Self.neighborDistances(for: prevInput, topology: keyTopology)[observed] {
            let newProxyLogp = Self.pendingProxyLogProb(
                pending: baseState.pending,
                emittedTokenIDs: hypothesis.emittedTokenIDs,
                table: table,
                scorer: &scorer
            )
            if newProxyLogp.isFinite {
                var inserted = hypothesis
                inserted.j += 1
                inserted.channelCost += config.beta * insertionDistance
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
        keyTopology: KeyTopology,
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
                keyTopology: keyTopology,
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
        observedElements: [ObservedElement],
        table: InputTable,
        scorer: inout LMScorer
    ) -> Hypothesis? {
        if hypothesis.j >= observedElements.count {
            return hypothesis
        }
        var completed = hypothesis
        while completed.j < observedElements.count {
            let observed = observedElements[completed.j].character
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
            let observedPiece = observedElements[completed.j].inputPiece
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
              let nextLogProbs = scorer.nextLogProbs(emittedTokenIDs: emittedTokenIDs) else {
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
