#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import EfficientNGram
import Foundation
import OrderedCollections
import SwiftUtils

/// experimental typo correction API 向けの設定。
public struct ExperimentalTypoCorrectionConfig: Sendable, Equatable, Hashable {
    /// typo correction で利用する言語モデル。
    public enum LanguageModel: Sendable, Equatable, Hashable {
        /// Zenz (llama) を利用して確率を評価します。
        case zenz
        /// 学習済み n-gram モデルを利用して確率を評価します。
        case ngram(NGramLanguageModel)
    }

    /// n-gram 言語モデル設定。
    public struct NGramLanguageModel: Sendable, Equatable, Hashable {
        /// - Parameters:
        ///   - prefix: 学習済み marisa ファイル群のプレフィックス（例: `/path/to/lm` または `/path/to/lm_`）。
        ///   - n: n-gram の n。
        ///   - d: Kneser-Ney の割引係数。
        public init(prefix: String, n: Int = 5, d: Double = 0.75) {
            self.prefix = prefix
            self.n = n
            self.d = d
        }

        public var prefix: String
        public var n: Int
        public var d: Double
    }

    public init(
        languageModel: LanguageModel = .zenz,
        beamSize: Int = 32,
        topK: Int = 64,
        nBest: Int = 5,
        maxSteps: Int? = nil,
        alpha: Float = 2.0,
        beta: Float = 3.0,
        gamma: Float = 2.0
    ) {
        self.languageModel = languageModel
        self.beamSize = max(1, beamSize)
        self.topK = max(1, topK)
        self.nBest = max(1, nBest)
        self.maxSteps = maxSteps
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
    }

    public var languageModel: LanguageModel
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
    /// テスト・診断時だけ探索量を収集する。通常実行ではhot pathへの計測負荷を避ける。
    var collectsPerformanceMetrics = false
    /// 増分checkpointとの完全一致を検証するテストでのみfalseにする。
    var usesIncrementalCheckpoint = true
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

/// typo探索1回分の仕事量を表す診断値。
/// latencyとは分離し、探索アルゴリズム変更時に速くなった理由を確認するために使う。
struct ZenzaiTypoGenerationMetrics: Sendable, Equatable {
    var inputElementCount = 0
    var stepCount = 0
    var peakBeamSize = 0
    var expandedHypothesisCount = 0
    var beamPrunedHypothesisCount = 0
    var upperBoundPrunedHypothesisCount = 0
    var lmRequestCount = 0
    var lmCacheHitCount = 0
    var lmEvaluationCount = 0
    var lmCacheEntryCount = 0
}

/// 同じ有限履歴またはtoken prefixから得た次token分布と、その派生計算を共有する。
private final class ZenzaiTypoLMDistribution: @unchecked Sendable {
    init(nextLogProbs: [Float]) {
        self.nextLogProbs = nextLogProbs
    }

    let nextLogProbs: [Float]
    var pendingProxyLogProbs: [String: Float] = [:]
    var topCharacters: [Int: [Character]] = [:]
}

/// token prefixを共有するLM状態。仮説は配列キーではなくこのノードを直接参照する。
private final class ZenzaiTypoLMState: @unchecked Sendable {
    init(emittedTokenIDs: [Int]) {
        self.emittedTokenIDs = emittedTokenIDs
    }

    let emittedTokenIDs: [Int]
    var distribution: ZenzaiTypoLMDistribution?
    var children: [Int: ZenzaiTypoLMState] = [:]
}

private struct ZenzaiTypoInputTransitionKey: Hashable {
    var pending: String
    var newCharacter: Character
}

private struct ZenzaiTypoInputTransitionValue {
    var emitted: String
    var pending: String
}

private struct ZenzaiTypoGeneratorState: Sendable, Equatable, Hashable {
    var pending: String
    var prevInputPiece: InputPiece?
    var proxyLogp: Float
}

private struct ZenzaiTypoHypothesis: Sendable {
    var correctedInput: String
    var emittedText: String
    var emittedLMState: ZenzaiTypoLMState
    var j: Int
    var prevEmittedChar: Character?
    var score: Float
    var lmScore: Float
    var channelCost: Float
    var generatorState: ZenzaiTypoGeneratorState?
}

private struct ZenzaiTypoIncrementalCheckpoint {
    var prompt: String
    var inputStyle: InputStyle
    var config: ExperimentalTypoCorrectionConfig
    var observedInputPieces: [InputPiece]
    var observedCharacters: [Character]
    var beam: [ZenzaiTypoHypothesis]
    var completedStepCount: Int
}

/// セッション跨ぎで typo 探索のLM補助キャッシュを保持するコンテナ。
final class ZenzaiTypoGenerationCache {
    fileprivate var prompt: String = ""
    fileprivate var promptTokenIDs: [Int] = []
    fileprivate var vocabSize: Int = 0
    fileprivate var lmRootState = ZenzaiTypoLMState(emittedTokenIDs: [])
    fileprivate var lmCachedDistributionCount = 0
    fileprivate var encodeCache: [String: [Int]] = [:]
    fileprivate var tokenCharCache: [Int: Character?] = [:]
    fileprivate var cachedInputStyle: InputStyle?
    fileprivate var inputTransitionCache: [ZenzaiTypoInputTransitionKey: ZenzaiTypoInputTransitionValue] = [:]
    fileprivate var pendingFirstTokenIDsCache: [String: [Int]] = [:]
    fileprivate var finiteHistoryCacheNamespace: String?
    fileprivate var finiteHistoryDistributions: [[Int]: ZenzaiTypoLMDistribution] = [:]
    fileprivate var incrementalCheckpoint: ZenzaiTypoIncrementalCheckpoint?
    var lastMetrics = ZenzaiTypoGenerationMetrics()

    func invalidateAll() {
        self.prompt = ""
        self.promptTokenIDs = []
        self.vocabSize = 0
        self.lmRootState = ZenzaiTypoLMState(emittedTokenIDs: [])
        self.lmCachedDistributionCount = 0
        self.encodeCache = [:]
        self.tokenCharCache = [:]
        self.cachedInputStyle = nil
        self.inputTransitionCache = [:]
        self.pendingFirstTokenIDsCache = [:]
        self.finiteHistoryCacheNamespace = nil
        self.finiteHistoryDistributions = [:]
        self.incrementalCheckpoint = nil
    }

    func invalidateForModelChange() {
        self.lmRootState = ZenzaiTypoLMState(emittedTokenIDs: [])
        self.lmCachedDistributionCount = 0
        self.encodeCache = [:]
        self.tokenCharCache = [:]
        self.pendingFirstTokenIDsCache = [:]
        self.finiteHistoryCacheNamespace = nil
        self.finiteHistoryDistributions = [:]
        self.incrementalCheckpoint = nil
    }
}

/// n-gram 言語モデルのロード結果をセッション単位で再利用するためのコンテナ。
final class NGramCache {
    fileprivate var model: EfficientNGram?
    fileprivate var resolvedPrefix: String?
    fileprivate var n: Int = 5
    fileprivate var d: Double = 0.75
    fileprivate var loadAttempted: Bool = false
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
    private typealias GeneratorState = ZenzaiTypoGeneratorState
    private typealias Hypothesis = ZenzaiTypoHypothesis
    private typealias IncrementalCheckpoint = ZenzaiTypoIncrementalCheckpoint

    private final class MetricsRecorder {
        var value = ZenzaiTypoGenerationMetrics()
    }

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
        var neighborDistances: [Character: Float]
        var targetCharacters: [Character]
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
        /// `expandWithDeferred` に渡されたbeam内の親仮説位置。
        /// 親仮説全体を各展開へ複製すると、sort時に大きな値を移動し続けるため添字だけを保持する。
        var parentIndex: Int
        var correctedAppend: String
        var observedCount: Int
        var channelAdd: Float
        var emitted: String
        var pending: String
        var lastInputPiece: InputPiece
        var upperBoundScore: Float
    }

    private struct TokenLogProb: Comparable {
        static func < (lhs: TokenLogProb, rhs: TokenLogProb) -> Bool {
            lhs.logProb < rhs.logProb
        }

        var token: Int
        var logProb: Float
    }

    /// 次トークン分布と文字列->token変換をキャッシュするLMスコアラー。
    private struct LMScorer<Context: ZenzCompatibleInputLanguageModelContext> {
        private let context: Context
        private let cache: ZenzaiTypoGenerationCache
        private let metrics: MetricsRecorder?

        init(
            context: Context,
            leftSideContext: String,
            inputStyle: InputStyle,
            cache: ZenzaiTypoGenerationCache,
            metrics: MetricsRecorder?
        ) {
            self.context = context
            self.cache = cache
            self.metrics = metrics
            self.prepareFiniteHistoryCache()
            self.prepareInputStyle(inputStyle)
            self.preparePrompt(leftSideContext: leftSideContext)
        }

        private func prepareFiniteHistoryCache() {
            let namespace = self.context.finiteHistoryCacheDescriptor?.namespace
            guard self.cache.finiteHistoryCacheNamespace != namespace else {
                return
            }
            self.cache.invalidateForModelChange()
            self.cache.finiteHistoryCacheNamespace = namespace
        }

        private func prepareInputStyle(_ inputStyle: InputStyle) {
            guard self.cache.cachedInputStyle != inputStyle else {
                return
            }
            self.cache.cachedInputStyle = inputStyle
            self.cache.inputTransitionCache = [:]
            self.cache.pendingFirstTokenIDsCache = [:]
            self.cache.incrementalCheckpoint = nil
        }

        private func preparePrompt(leftSideContext: String) {
            let vocabSize = self.context.vocabSize
            if self.cache.vocabSize != 0, self.cache.vocabSize != vocabSize {
                self.cache.invalidateAll()
            }
            self.cache.vocabSize = vocabSize
            let prompt = ZenzPromptBuilder.typoCorrectionPromptPrefix(leftSideContext: leftSideContext)
            if self.cache.prompt != prompt || self.cache.promptTokenIDs.isEmpty {
                self.cache.prompt = prompt
                self.cache.promptTokenIDs = self.context.encodeRaw(prompt)
                self.cache.lmRootState = ZenzaiTypoLMState(emittedTokenIDs: [])
                self.cache.lmCachedDistributionCount = 0
                self.cache.incrementalCheckpoint = nil
            }
        }

        mutating func encodeRaw(_ text: String) -> [Int] {
            if let cached = self.cache.encodeCache[text] {
                return cached
            }
            let tokenIDs = self.context.encodeRaw(text)
            self.cache.encodeCache[text] = tokenIDs
            return tokenIDs
        }

        mutating func topKCharacters(emittedLMState: ZenzaiTypoLMState, k: Int) -> [Character] {
            if let cached = emittedLMState.distribution?.topCharacters[k] {
                return cached
            }
            guard let nextLogProbs = self.nextLogProbs(emittedLMState: emittedLMState) else {
                return []
            }
            var heap = FixedSizeHeap<TokenLogProb>(size: max(1, k * 4))
            for (tokenID, logProb) in nextLogProbs.indexed() {
                heap.insertIfPossible(TokenLogProb(token: tokenID, logProb: logProb))
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
            emittedLMState.distribution?.topCharacters[k] = chars
            return chars
        }

        mutating func appendAndScore(
            emittedLMState: ZenzaiTypoLMState,
            lmScore: Float,
            appendText: String
        ) -> (emittedLMState: ZenzaiTypoLMState, lmScore: Float)? {
            let appendTokenIDs = self.encodeRaw(appendText)
            guard !appendTokenIDs.isEmpty else {
                return (emittedLMState, lmScore)
            }
            var currentState = emittedLMState
            var currentScore = lmScore
            for tokenID in appendTokenIDs {
                guard let logProbs = self.nextLogProbs(emittedLMState: currentState) else {
                    return nil
                }
                let index = Int(tokenID)
                guard logProbs.indices.contains(index) else {
                    return nil
                }
                currentScore += logProbs[index]
                currentState = self.childState(parent: currentState, tokenID: tokenID)
            }
            return (currentState, currentScore)
        }

        private mutating func tokenToSingleCharacter(_ token: Int) -> Character? {
            if let cached = self.cache.tokenCharCache[token] {
                return cached
            }
            let char = self.context.tokenToSingleCharacter(tokenID: token)
            self.cache.tokenCharCache[token] = char
            return char
        }

        mutating func consumeWithEmission(
            pending: String,
            newCharacter: Character,
            table: InputTable
        ) -> (emitted: String, pending: String) {
            let key = ZenzaiTypoInputTransitionKey(pending: pending, newCharacter: newCharacter)
            if let cached = self.cache.inputTransitionCache[key] {
                return (cached.emitted, cached.pending)
            }
            let value = ZenzaiTypoCandidateGenerator.computeConsumeWithEmission(
                pending: pending,
                newCharacter: newCharacter,
                table: table
            )
            self.cache.inputTransitionCache[key] = .init(emitted: value.emitted, pending: value.pending)
            return value
        }

        mutating func pendingFirstTokenIDs(pending: String, table: InputTable) -> [Int] {
            if let cached = self.cache.pendingFirstTokenIDsCache[pending] {
                return cached
            }
            let tokenIDs = ZenzaiTypoCandidateGenerator.computePendingFirstTokenIDs(
                pending: pending,
                table: table,
                scorer: &self
            )
            self.cache.pendingFirstTokenIDsCache[pending] = tokenIDs
            return tokenIDs
        }

        private func childState(parent: ZenzaiTypoLMState, tokenID: Int) -> ZenzaiTypoLMState {
            if let child = parent.children[tokenID] {
                return child
            }
            var emittedTokenIDs = parent.emittedTokenIDs
            emittedTokenIDs.append(tokenID)
            let child = ZenzaiTypoLMState(emittedTokenIDs: emittedTokenIDs)
            parent.children[tokenID] = child
            return child
        }

        mutating func nextLogProbs(emittedLMState: ZenzaiTypoLMState) -> [Float]? {
            self.metrics?.value.lmRequestCount += 1
            if let cached = emittedLMState.distribution {
                self.metrics?.value.lmCacheHitCount += 1
                return cached.nextLogProbs
            }
            let finiteHistoryKey: [Int]? = if let descriptor = self.context.finiteHistoryCacheDescriptor {
                if descriptor.tokenLimit == 0 {
                    []
                } else if emittedLMState.emittedTokenIDs.count >= descriptor.tokenLimit {
                    Array(emittedLMState.emittedTokenIDs.suffix(descriptor.tokenLimit))
                } else {
                    Array(
                        (self.cache.promptTokenIDs + emittedLMState.emittedTokenIDs)
                            .suffix(descriptor.tokenLimit)
                    )
                }
            } else {
                nil
            }
            if let finiteHistoryKey,
               let cached = self.cache.finiteHistoryDistributions[finiteHistoryKey] {
                self.metrics?.value.lmCacheHitCount += 1
                emittedLMState.distribution = cached
                return cached.nextLogProbs
            }
            self.metrics?.value.lmEvaluationCount += 1
            let values = self.context.nextLogProbs(
                promptTokenIDs: self.cache.promptTokenIDs,
                emittedTokenIDs: emittedLMState.emittedTokenIDs
            )
            guard let values else {
                return nil
            }
            let distribution = ZenzaiTypoLMDistribution(nextLogProbs: values)
            emittedLMState.distribution = distribution
            if let finiteHistoryKey {
                self.cache.finiteHistoryDistributions[finiteHistoryKey] = distribution
            }
            self.cache.lmCachedDistributionCount += 1
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

    static func resolveNGramContext(
        experimentalConfig: ExperimentalTypoCorrectionConfig,
        cache: NGramCache
    ) -> NGramContext? {
        guard case .ngram(let ngramConfig) = experimentalConfig.languageModel else {
            return nil
        }

        let rawPrefix = ngramConfig.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPrefix.isEmpty else {
            return nil
        }
        let n = max(1, ngramConfig.n)
        let d = ngramConfig.d

        var trimmedUnderscorePrefix = rawPrefix
        while trimmedUnderscorePrefix.last == "_" {
            trimmedUnderscorePrefix.removeLast()
        }
        let candidatePrefixes = [rawPrefix, trimmedUnderscorePrefix].filter { !$0.isEmpty }.uniqued()
        let requiredSuffixes = ["_c_abc.marisa", "_u_abx.marisa", "_u_xbc.marisa", "_r_xbx.marisa"]
        let fileManager = FileManager.default

        let resolvedPrefix = candidatePrefixes.first { prefix in
            requiredSuffixes.allSatisfy { suffix in
                fileManager.fileExists(atPath: prefix + suffix)
            }
        }

        guard let resolvedPrefix else {
            if !cache.loadAttempted {
                debug("[Warning] ExperimentalTypoCorrectionConfig.languageModel=.ngram is set, but required n-gram files were not found.")
                debug("[Warning] Checked prefixes: \(candidatePrefixes.joined(separator: ", "))")
                cache.loadAttempted = true
            }
            return nil
        }

        let model: EfficientNGram
        if let existingModel = cache.model,
           cache.resolvedPrefix == resolvedPrefix,
           cache.n == n,
           cache.d == d {
            model = existingModel
        } else {
            let tokenizer = ZenzTokenizer()
            model = EfficientNGram(baseFilename: resolvedPrefix, n: n, d: d, tokenizer: tokenizer)
            cache.model = model
            cache.resolvedPrefix = resolvedPrefix
            cache.n = n
            cache.d = d
            cache.loadAttempted = true
        }
        return NGramContext(
            model: model,
            cacheNamespace: "\(resolvedPrefix)|n=\(n)|d=\(d.bitPattern)",
            historyTokenLimit: max(0, n - 1)
        )
    }

    static func generate<Context: ZenzCompatibleInputLanguageModelContext>(
        context: Context,
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        experimentalConfig: ExperimentalTypoCorrectionConfig,
        cache: ZenzaiTypoGenerationCache
    ) -> [ZenzaiTypoCandidate] {
        let metrics = experimentalConfig.collectsPerformanceMetrics ? MetricsRecorder() : nil
        cache.lastMetrics = .init()
        let mode = Self.resolveGenerationConfig(inputStyle: inputStyle)
        let observedElements = Self.observedElements(
            composingText: composingText,
            source: mode.observedSource,
            keyTopology: mode.keyTopology
        )
        guard !observedElements.isEmpty else {
            return []
        }
        metrics?.value.inputElementCount = observedElements.count
        defer {
            if let metrics {
                metrics.value.lmCacheEntryCount = if cache.finiteHistoryCacheNamespace == nil {
                    cache.lmCachedDistributionCount
                } else {
                    cache.finiteHistoryDistributions.count
                }
                cache.lastMetrics = metrics.value
            }
        }
        let maxSteps = experimentalConfig.maxSteps ?? (observedElements.count * 2 + 8)

        func initialHypothesis() -> Hypothesis {
            Hypothesis(
                correctedInput: "",
                emittedText: "",
                emittedLMState: cache.lmRootState,
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
            inputStyle: inputStyle,
            cache: cache,
            metrics: metrics
        )
        let observedInputPieces = observedElements.map(\.inputPiece)
        let observedCharacters = observedElements.map(\.character)
        let previousInputPieces = Array(observedInputPieces.dropLast())
        let previousCharacters = Array(observedCharacters.dropLast())
        let resumeCheckpoint: IncrementalCheckpoint? = if
            let checkpoint = cache.incrementalCheckpoint,
            experimentalConfig.usesIncrementalCheckpoint,
            checkpoint.prompt == cache.prompt,
            checkpoint.inputStyle == inputStyle,
            checkpoint.config == experimentalConfig,
            checkpoint.observedInputPieces == previousInputPieces,
            checkpoint.observedCharacters == previousCharacters {
            checkpoint
        } else {
            nil
        }
        var beam = resumeCheckpoint?.beam ?? [initialHypothesis()]
        var completedStepCount = resumeCheckpoint?.completedStepCount ?? 0
        var nextCheckpoint: IncrementalCheckpoint?
        metrics?.value.peakBeamSize = beam.count

        while completedStepCount < maxSteps {
            // 1文字追加後も探索が同一である範囲だけを保存する。observedCountは最大2なので、
            // current tailの2文字前へ到達する前ならisInputTail/reachesTailの分岐に触れない。
            if experimentalConfig.usesIncrementalCheckpoint,
               observedElements.count >= 3,
               beam.allSatisfy({ $0.j <= observedElements.count - 3 }) {
                nextCheckpoint = .init(
                    prompt: cache.prompt,
                    inputStyle: inputStyle,
                    config: experimentalConfig,
                    observedInputPieces: observedInputPieces,
                    observedCharacters: observedCharacters,
                    beam: beam,
                    completedStepCount: completedStepCount
                )
            }
            metrics?.value.stepCount += 1
            let result = Self.expandWithDeferred(
                beam: beam,
                observedElements: observedElements,
                table: mode.table,
                keyTopology: mode.keyTopology,
                useInputCharacterLMFilter: mode.usesInputCharacterLMFilter,
                scorer: &scorer,
                config: experimentalConfig,
                metrics: metrics
            )
            let expanded = result.expanded
            let allConsumed = result.allConsumed
            guard !expanded.isEmpty else {
                break
            }
            beam = Array(expanded.sorted(by: { $0.score > $1.score }).prefix(experimentalConfig.beamSize))
            completedStepCount += 1
            if let metrics {
                metrics.value.peakBeamSize = max(metrics.value.peakBeamSize, beam.count)
            }
            if allConsumed {
                break
            }
        }
        cache.incrementalCheckpoint = nextCheckpoint

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
            if unique.count >= experimentalConfig.nBest * 3 {
                break
            }
        }

        return Array(unique.values.sorted(by: { $0.score > $1.score }).prefix(experimentalConfig.nBest))
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

    private static func observedElements(
        composingText: ComposingText,
        source: ObservedSource,
        keyTopology: KeyTopology
    ) -> [ObservedElement] {
        func makeElement(inputPiece: InputPiece, character: Character) -> ObservedElement {
            let neighborDistances = keyTopology.neighborDistances(around: character)
            return .init(
                inputPiece: inputPiece,
                character: character,
                neighborDistances: neighborDistances,
                targetCharacters: ([character] + neighborDistances.keys).sorted()
            )
        }
        if source == .convertTarget {
            return composingText.convertTarget.toKatakana().map {
                makeElement(inputPiece: .character($0), character: $0)
            }
        }
        var result: [ObservedElement] = []
        result.reserveCapacity(composingText.input.count)
        for element in composingText.input {
            guard let normalized = Self.canonicalCharacter(for: element.piece) else {
                continue
            }
            result.append(makeElement(inputPiece: element.piece, character: normalized))
        }
        return result
    }

    private static func expandCandidates<Context: ZenzCompatibleInputLanguageModelContext>(
        hypothesis: Hypothesis,
        parentIndex: Int,
        observedElements: [ObservedElement],
        table: InputTable,
        keyTopology: KeyTopology,
        useInputCharacterLMFilter: Bool,
        scorer: inout LMScorer<Context>,
        config: ExperimentalTypoCorrectionConfig
    ) -> (immediate: [Hypothesis], deferred: [DeferredRequest]) {
        guard observedElements.indices.contains(hypothesis.j), let baseState = hypothesis.generatorState else {
            return ([hypothesis], [])
        }
        let observedElement = observedElements[hypothesis.j]
        let observed = observedElement.character
        let isInputTail = hypothesis.j == observedElements.count - 1
        let neighborDistances = observedElement.neighborDistances
        let targetChars: [Character]
        if useInputCharacterLMFilter {
            let lmTopChars = Set(scorer.topKCharacters(emittedLMState: hypothesis.emittedLMState, k: config.topK))
            let scoredTargets = observedElement.targetCharacters.filter { $0 == observed || lmTopChars.contains($0) }
            targetChars = scoredTargets.isEmpty ? [observed] : scoredTargets.sorted(by: { $0 < $1 })
        } else {
            targetChars = observedElement.targetCharacters
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
                  let nextLogProbs = scorer.nextLogProbs(emittedLMState: hypothesis.emittedLMState)
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
                    parentIndex: parentIndex,
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
                let consumed = scorer.consumeWithEmission(pending: pending, newCharacter: char, table: table)
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
                emittedLMState: hypothesis.emittedLMState,
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

    private static func expandWithDeferred<Context: ZenzCompatibleInputLanguageModelContext>(
        beam: [Hypothesis],
        observedElements: [ObservedElement],
        table: InputTable,
        keyTopology: KeyTopology,
        useInputCharacterLMFilter: Bool,
        scorer: inout LMScorer<Context>,
        config: ExperimentalTypoCorrectionConfig,
        metrics: MetricsRecorder?
    ) -> (expanded: [Hypothesis], allConsumed: Bool) {
        var heap = FixedSizeHeap<ScoredHypothesis>(size: max(1, config.beamSize))
        var deferredRequests: [DeferredRequest] = []
        var allConsumed = true
        var viableHypothesisCount = 0

        for (parentIndex, hypothesis) in beam.enumerated() {
            if hypothesis.j >= observedElements.count {
                viableHypothesisCount += 1
                _ = heap.insertIfPossible(ScoredHypothesis(hypothesis))
                continue
            }
            allConsumed = false
            let (immediate, deferred) = Self.expandCandidates(
                hypothesis: hypothesis,
                parentIndex: parentIndex,
                observedElements: observedElements,
                table: table,
                keyTopology: keyTopology,
                useInputCharacterLMFilter: useInputCharacterLMFilter,
                scorer: &scorer,
                config: config
            )
            metrics?.value.expandedHypothesisCount += immediate.count + deferred.count
            for candidate in immediate {
                viableHypothesisCount += 1
                _ = heap.insertIfPossible(ScoredHypothesis(candidate))
            }
            deferredRequests.append(contentsOf: deferred)
        }

        if !deferredRequests.isEmpty {
            deferredRequests.sort(by: { $0.upperBoundScore > $1.upperBoundScore })
            for (index, request) in deferredRequests.enumerated() {
                if heap.unordered.count >= max(1, config.beamSize),
                   let cutoff = heap.min?.score,
                   request.upperBoundScore < cutoff {
                    metrics?.value.upperBoundPrunedHypothesisCount += deferredRequests.count - index
                    break
                }
                let parent = beam[request.parentIndex]
                guard let baseState = parent.generatorState,
                      let evaluated = Self.evaluateAdvance(
                          parent: parent,
                          baseState: baseState,
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
                viableHypothesisCount += 1
                _ = heap.insertIfPossible(ScoredHypothesis(evaluated))
            }
        }

        let expanded = heap.unordered.sorted(by: { $0.score > $1.score }).map(\.hypothesis)
        metrics?.value.beamPrunedHypothesisCount += max(0, viableHypothesisCount - expanded.count)
        return (expanded, allConsumed)
    }

    private static func evaluateAdvance<Context: ZenzCompatibleInputLanguageModelContext>(
        parent: Hypothesis,
        baseState: GeneratorState,
        correctedAppend: String,
        observedCount: Int,
        channelAdd: Float,
        emitted: String,
        pending: String,
        lastInputPiece: InputPiece,
        table: InputTable,
        scorer: inout LMScorer<Context>
    ) -> Hypothesis? {
        let oldProxyLogp = baseState.proxyLogp
        guard oldProxyLogp.isFinite else {
            return nil
        }
        let baseLMScore = parent.lmScore - oldProxyLogp
        var emittedLMState = parent.emittedLMState
        var emittedLogp: Float = 0
        var prevEmittedChar = parent.prevEmittedChar
        if !emitted.isEmpty {
            guard let appended = scorer.appendAndScore(
                emittedLMState: emittedLMState,
                lmScore: 0,
                appendText: emitted
            ) else {
                return nil
            }
            emittedLMState = appended.emittedLMState
            emittedLogp = appended.lmScore
            prevEmittedChar = emitted.last
        }
        let newProxyLogp = Self.pendingProxyLogProb(
            pending: pending,
            emittedLMState: emittedLMState,
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
        next.emittedLMState = emittedLMState
        next.lmScore = baseLMScore + emittedLogp + newProxyLogp
        next.channelCost += channelAdd
        next.score = next.lmScore - next.channelCost
        next.j += observedCount
        next.prevEmittedChar = prevEmittedChar
        next.generatorState = nextState
        return next
    }

    private static func completeHypothesis<Context: ZenzCompatibleInputLanguageModelContext>(
        hypothesis: Hypothesis,
        observedElements: [ObservedElement],
        table: InputTable,
        scorer: inout LMScorer<Context>
    ) -> Hypothesis? {
        if hypothesis.j >= observedElements.count {
            return hypothesis
        }
        guard var state = hypothesis.generatorState else {
            return nil
        }
        let oldProxyLogp = state.proxyLogp
        guard oldProxyLogp.isFinite else {
            return nil
        }

        var completed = hypothesis
        let baseLMScore = completed.lmScore - oldProxyLogp
        var newlyEmitted = ""
        while completed.j < observedElements.count {
            let observed = observedElements[completed.j].character
            let consumed = scorer.consumeWithEmission(
                pending: state.pending,
                newCharacter: observed,
                table: table
            )
            state.pending = consumed.pending
            state.prevInputPiece = observedElements[completed.j].inputPiece
            completed.correctedInput += String(observed)
            completed.j += 1
            newlyEmitted += consumed.emitted
        }

        var emittedLMState = completed.emittedLMState
        var emittedLogp: Float = 0
        if !newlyEmitted.isEmpty {
            let appended = scorer.appendAndScore(
                emittedLMState: emittedLMState,
                lmScore: 0,
                appendText: newlyEmitted
            )
            guard let appended else {
                return nil
            }
            emittedLMState = appended.emittedLMState
            emittedLogp = appended.lmScore
            completed.prevEmittedChar = newlyEmitted.last
            completed.emittedText += newlyEmitted
        }
        let newProxyLogp = Self.pendingProxyLogProb(
            pending: state.pending,
            emittedLMState: emittedLMState,
            table: table,
            scorer: &scorer
        )
        guard newProxyLogp.isFinite else {
            return nil
        }
        state.proxyLogp = newProxyLogp
        completed.generatorState = state
        completed.emittedLMState = emittedLMState
        completed.lmScore = baseLMScore + emittedLogp + newProxyLogp
        completed.score = completed.lmScore - completed.channelCost
        return completed
    }

    private static func computeConsumeWithEmission(
        pending: String,
        newCharacter: Character,
        table: InputTable
    ) -> (emitted: String, pending: String) {
        let raw = pending + String(newCharacter)
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

    private static func pendingProxyLogProb<Context: ZenzCompatibleInputLanguageModelContext>(
        pending: String,
        emittedLMState: ZenzaiTypoLMState,
        table: InputTable,
        scorer: inout LMScorer<Context>
    ) -> Float {
        guard !pending.isEmpty else {
            return 0
        }
        if let cached = emittedLMState.distribution?.pendingProxyLogProbs[pending] {
            return cached
        }
        let firstTokenIDs = scorer.pendingFirstTokenIDs(pending: pending, table: table)
        guard !firstTokenIDs.isEmpty,
              let nextLogProbs = scorer.nextLogProbs(emittedLMState: emittedLMState) else {
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
        let result = maxLogProb + logf(sumExp)
        emittedLMState.distribution?.pendingProxyLogProbs[pending] = result
        return result
    }

    private static func computePendingFirstTokenIDs<Context: ZenzCompatibleInputLanguageModelContext>(
        pending: String,
        table: InputTable,
        scorer: inout LMScorer<Context>
    ) -> [Int] {
        var tokenIDs: Set<Int> = []
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
