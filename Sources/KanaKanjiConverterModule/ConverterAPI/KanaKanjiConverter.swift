//
//  KanaKanjiConverter.swift
//  AzooKeyKanaKanjiConverter
//
//  Created by ensan on 2020/09/03.
//  Copyright © 2020 ensan. All rights reserved.
//

import Algorithms
import EfficientNGram
public import Foundation
import SwiftUtils

/// かな漢字変換の管理を受け持つクラス
public final class KanaKanjiConverter {
    private let converter: Kana2Kanji

    public init(dicdataStore: DicdataStore) {
        self.converter = .init(dicdataStore: dicdataStore)
        self.dicdataStoreState = dicdataStore.prepareState()
    }
    public convenience init(dictionaryURL: URL, preloadDictionary: Bool = false) {
        let dicdataStore = DicdataStore(dictionaryURL: dictionaryURL, preloadDictionary: preloadDictionary)
        self.init(dicdataStore: dicdataStore)
    }
    static func withoutDictionary() -> KanaKanjiConverter {
        KanaKanjiConverter(dictionaryURL: URL(fileURLWithPath: "/dev/null"), preloadDictionary: false)
    }

    nonisolated public static let defaultSpecialCandidateProviders: [any SpecialCandidateProvider] = [
        CalendarSpecialCandidateProvider(),
        EmailAddressSpecialCandidateProvider(),
        UnicodeSpecialCandidateProvider(),
        VersionSpecialCandidateProvider(),
        TimeExpressionSpecialCandidateProvider(),
        CommaSeparatedNumberSpecialCandidateProvider()
    ]
    private var checker = SpellChecker()
    private var checkerInitialized: [KeyboardLanguage: Bool] = [.none: true, .ja_JP: true]

    // 前回の変換や確定の情報を取っておく部分。
    private var previousInputData: ComposingText?
    private var lattice: Lattice = Lattice()
    private var completedData: Candidate?
    private var lastData: DicdataElement?
    /// Zenzaiのためのzenzモデル
    private var zenz: Zenz?
    private var zenzaiCache: Kana2Kanji.ZenzaiCache?
    private var zenzaiPersonalization: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?
    public private(set) var zenzStatus: String = ""
    private var dicdataStoreState: DicdataStoreState

    /// リセットする関数
    public func stopComposition() {
        self.zenz?.endSession()
        self.zenzaiPersonalization = nil
        self.zenzaiCache = nil
        self.previousInputData = nil
        self.lattice = .init()
        self.completedData = nil
        self.lastData = nil
    }

    private func getZenzaiPersonalization(mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode?) -> (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)? {
        guard let mode else {
            return nil
        }
        if let zenzaiPersonalization, zenzaiPersonalization.mode == mode {
            return zenzaiPersonalization
        }
        let tokenizer = ZenzTokenizer()
        let baseModel = EfficientNGram(baseFilename: mode.baseNgramLanguageModel, n: mode.n, d: mode.d, tokenizer: tokenizer)
        let personalModel = EfficientNGram(baseFilename: mode.personalNgramLanguageModel, n: mode.n, d: mode.d, tokenizer: tokenizer)
        self.zenzaiPersonalization = (mode, baseModel, personalModel)
        return (mode, baseModel, personalModel)
    }

    package func getModel(modelURL: URL) -> Zenz? {
        if let model = self.zenz, model.resourceURL == modelURL {
            self.zenzStatus = "load \(modelURL.absoluteString)"
            return model
        } else {
            do {
                self.zenz = try Zenz(resourceURL: modelURL)
                self.zenzStatus = "load \(modelURL.absoluteString)"
                return self.zenz
            } catch {
                self.zenzStatus = "load \(modelURL.absoluteString)    " + error.localizedDescription
                return nil
            }
        }
    }

    public func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        guard let zenz = self.getModel(modelURL: options.zenzaiMode.weightURL) else {
            print("zenz-v2 model unavailable")
            return []
        }
        guard options.zenzaiMode.versionDependentMode.version == .v2 else {
            print("next character prediction requires zenz-v2 models, not zenz-v1 nor zenz-v3 and later")
            return []
        }
        return zenz.predictNextCharacter(leftSideContext: leftSideContext, count: count)
    }

    /// 入力する言語が分かったらこの関数をなるべく早い段階で呼ぶことで、SpellCheckerの初期化が行われ、変換がスムーズになる
    public func setKeyboardLanguage(_ language: KeyboardLanguage) {
        self.dicdataStoreState.updateKeyboardLanguage(language)
        if !checkerInitialized[language, default: false] {
            switch language {
            case .en_US:
                _ = self.checker.completions(forPartialWordRange: NSRange(location: 0, length: 1), in: "a", language: "en-US")
                self.checkerInitialized[language] = true
            case .el_GR:
                _ = self.checker.completions(forPartialWordRange: NSRange(location: 0, length: 1), in: "a", language: "el-GR")
                self.checkerInitialized[language] = true
            case .none, .ja_JP:
                checkerInitialized[language] = true
            }
        }
    }

    /// 動的ユーザ辞書を引数に与えたデータで上書きします。
    /// - Parameters:
    ///   - dicdata: ユーザ辞書エントリです。動的ユーザ辞書エントリは検索効率が悪いため、現実的な件数に抑えてください。
    ///   - shortcuts: ユーザショートカットエントリです。Rubyに完全一致する場合のみ利用されます。こちらも現実的な件数に抑えてください。
    public func importDynamicUserDictionary(_ dicdata: [DicdataElement], shortcuts: [DicdataElement] = []) {
        self.dicdataStoreState.importDynamicUserDictionary(dicdata, shortcuts: shortcuts)
    }

    public func updateUserDictionaryURL(_ newURL: URL, forceReload: Bool = false) {
        self.dicdataStoreState.updateUserDictionaryURL(newURL, forceReload: forceReload)
    }

    public func updateLearningConfig(_ newConfig: LearningConfig) {
        self.dicdataStoreState.updateLearningConfig(newConfig)
    }

    /// 確定操作後、内部状態のキャッシュを変更する関数。
    /// - Parameters:
    ///   - candidate: 確定された候補。
    public func setCompletedData(_ candidate: Candidate) {
        self.completedData = candidate
    }

    /// 確定操作後、学習メモリをアップデートする関数。
    /// - Parameters:
    ///   - candidate: 確定された候補。
    /// - Warning:
    ///   `commitUpdateLearningData`を呼び出すまで永続化されません。
    public func updateLearningData(_ candidate: Candidate) {
        self.dicdataStoreState.updateLearningData(candidate, with: self.lastData)
        self.lastData = candidate.data.last
    }

    /// 確定操作後、学習メモリをアップデートする関数。
    /// - Parameters:
    ///   - candidate: 確定された候補。
    /// - Warning:
    ///   `commitUpdateLearningData`を呼び出すまで永続化されません。
    public func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        self.dicdataStoreState.updateLearningData(candidate, with: predictionCandidate)
        self.lastData = predictionCandidate.lastData
    }

    /// 確定操作後の学習メモリの更新を確定させます。
    public func commitUpdateLearningData() {
        self.dicdataStoreState.saveMemory()
    }

    /// 確定操作後の学習メモリの更新を確定させます。
    public func forgetMemory(_ candidate: Candidate) {
        self.dicdataStoreState.forgetMemory(candidate)
    }

    /// 確定操作後の学習メモリの更新を確定させます。
    public func resetMemory() {
        self.dicdataStoreState.resetMemory()
    }

    /// 賢い変換候補を生成する関数。
    /// - Parameters:
    ///   - string: 入力されたString
    /// - Returns:
    ///   `賢い変換候補
    private func getSpecialCandidate(_ inputData: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        options.specialCandidateProviders.flatMap { provider in
            provider.provideCandidates(converter: self, inputData: inputData, options: options)
        }
    }

    /// 変換候補の重複を除去する関数。
    /// - Parameters:
    ///   - candidates: uniqueを実行する候補列。
    /// - Returns:
    ///   `candidates`から重複を削除したもの。
    private func getUniqueCandidate(_ candidates: some Sequence<Candidate>, seenCandidates: Set<String> = []) -> [Candidate] {
        var result = [Candidate]()
        var textIndex = [String: Int]()
        result.reserveCapacity(candidates.underestimatedCount)
        textIndex.reserveCapacity(candidates.underestimatedCount)
        for candidate in candidates where !candidate.text.isEmpty && !seenCandidates.contains(candidate.text) {
            if let index = textIndex[candidate.text] {
                if result[index].value < candidate.value || result[index].rubyCount < candidate.rubyCount {
                    result[index] = candidate
                }
            } else {
                textIndex[candidate.text] = result.endIndex
                result.append(candidate)
            }
        }
        return result
    }

    /// 変換候補の重複を除去する関数。
    /// - Parameters:
    ///   - candidates: uniqueを実行する候補列。
    /// - Returns:
    ///   `candidates`から重複を削除したもの。
    private func getUniquePostCompositionPredictionCandidate(_ candidates: some Sequence<PostCompositionPredictionCandidate>, seenCandidates: Set<String> = []) -> [PostCompositionPredictionCandidate] {
        var result = [PostCompositionPredictionCandidate]()
        for candidate in candidates where !candidate.text.isEmpty && !seenCandidates.contains(candidate.text) {
            if let index = result.firstIndex(where: {$0.text == candidate.text}) {
                if result[index].value < candidate.value {
                    result[index] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    /// 外国語への予測変換候補を生成する関数
    /// - Parameters:
    ///   - inputData: 変換対象のデータ。
    ///   - language: 言語コード。現在は`en-US`と`el(ギリシャ語)`のみ対応している。
    /// - Returns:
    ///   予測変換候補
    private func getForeignPredictionCandidate(inputData: ComposingText, language: String, penalty: PValue = -5) -> [Candidate] {
        switch language {
        case "en-US":
            var result: [Candidate] = []
            let ruby = String(inputData.input.compactMap {
                if case let .character(c) = $0.piece { c } else { nil }
            })
            let range = NSRange(location: 0, length: ruby.utf16.count)
            if !ruby.onlyRomanAlphabet {
                return result
            }
            if let completions = checker.completions(forPartialWordRange: range, in: ruby, language: language) {
                if !completions.isEmpty {
                    let data = [DicdataElement(ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: penalty)]
                    let candidate: Candidate = Candidate(
                        text: ruby,
                        value: penalty,
                        composingCount: .inputCount(inputData.input.count),
                        lastMid: MIDData.一般.mid,
                        data: data
                    )
                    result.append(candidate)
                }
                var value: PValue = -5 + penalty
                let delta: PValue = -10 / PValue(completions.count)
                for word in completions {
                    let data = [DicdataElement(ruby: word, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)]
                    let candidate: Candidate = Candidate(
                        text: word,
                        value: value,
                        composingCount: .inputCount(inputData.input.count),
                        lastMid: MIDData.一般.mid,
                        data: data
                    )
                    result.append(candidate)
                    value += delta
                }
            }
            return result
        case "el":
            var result: [Candidate] = []
            let ruby = String(inputData.input.compactMap {
                if case let .character(c) = $0.piece { c } else { nil }
            })
            let range = NSRange(location: 0, length: ruby.utf16.count)
            if let completions = checker.completions(forPartialWordRange: range, in: ruby, language: language) {
                if !completions.isEmpty {
                    let data = [DicdataElement(ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: penalty)]
                    let candidate: Candidate = Candidate(
                        text: ruby,
                        value: penalty,
                        composingCount: .inputCount(inputData.input.count),
                        lastMid: MIDData.一般.mid,
                        data: data
                    )
                    result.append(candidate)
                }
                var value: PValue = -5 + penalty
                let delta: PValue = -10 / PValue(completions.count)
                for word in completions {
                    let data = [DicdataElement(ruby: word, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)]
                    let candidate: Candidate = Candidate(
                        text: word,
                        value: value,
                        composingCount: .inputCount(inputData.input.count),
                        lastMid: MIDData.一般.mid,
                        data: data
                    )
                    result.append(candidate)
                    value += delta
                }
            }
            return result
        default:
            return []
        }
    }

    /// 予測変換候補を生成する関数
    /// - Parameters:
    ///   - sums: 変換対象のデータ。
    /// - Returns:
    ///   予測変換候補
    private func getPredictionCandidate(_ bestCandidateDataForPrediction: consuming CandidateData, composingText: ComposingText, options _: ConvertRequestOptions) -> [Candidate] {
        // 予測変換は次の方針で行う。
        // prepart: 前半文節 lastPart: 最終文節とする。
        // まず、lastPartがnilであるところから始める

        var candidates: [Candidate] = []
        var prepart = consume bestCandidateDataForPrediction
        var lastpart: CandidateData.ClausesUnit?
        var count = 0
        while true {
            if count == 2 {
                break
            }
            if prepart.isEmpty {
                break
            }
            if let oldlastPart = lastpart {
                // 現在の最終分節をもう1つ取得
                let lastUnit = prepart.clauses.popLast()!   // prepartをmutatingでlastを取る。
                var newUnit = lastUnit.clause               // 新しいlastpartとなる部分。
                newUnit.merge(with: oldlastPart.clause)     // マージする。(最終文節の範囲を広げたことになる)
                let newValue = lastUnit.value + oldlastPart.value
                let newlastPart: CandidateData.ClausesUnit = (clause: newUnit, value: newValue)
                let predictions = converter.getPredictionCandidates(composingText: composingText, prepart: prepart, lastClause: newlastPart.clause, N_best: 5, dicdataStoreState: self.dicdataStoreState)
                lastpart = newlastPart
                // 結果がemptyでなければ
                if !predictions.isEmpty {
                    candidates += predictions
                    count += 1
                }
            } else {
                // 最終分節を取得
                lastpart = prepart.clauses.popLast()
                // 予測変換を受け取る
                let predictions = converter.getPredictionCandidates(composingText: composingText, prepart: prepart, lastClause: lastpart!.clause, N_best: 5, dicdataStoreState: self.dicdataStoreState)
                // 結果がemptyでなければ
                if !predictions.isEmpty {
                    // 結果に追加
                    candidates += predictions
                    count += 1
                }
            }
        }
        return candidates
    }

    /// トップレベルに追加する付加的な変換候補を生成する関数
    /// - Parameters:
    ///   - inputData: 変換対象のInputData。
    /// - Returns:
    ///   付加的な変換候補
    private func getTopLevelAdditionalCandidate(_ inputData: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        var candidates: [Candidate] = []
        if options.englishCandidateInRoman2KanaInput, inputData.input.allSatisfy({
            if case let .character(c) = $0.piece { c.isASCII } else { false }
        }) {
            candidates.append(contentsOf: self.getForeignPredictionCandidate(inputData: inputData, language: "en-US", penalty: -10))
        }
        return candidates
    }
    /// 部分がカタカナである可能性を調べる
    /// 小さいほどよい。
    private func getKatakanaScore<S: StringProtocol>(_ katakana: S) -> PValue {
        var score: PValue = 1
        // テキスト分析によってこれらのカタカナが入っている場合カタカナ語である可能性が高いと分かった。
        for c in katakana {
            if "プヴペィフ".contains(c) {
                score *= 0.5
            } else if "ュピポ".contains(c) {
                score *= 0.6
            } else if "パォグーム".contains(c) {
                score *= 0.7
            }
        }
        return score
    }

    /// 付加的な変換候補を生成する関数
    /// - Parameters:
    ///   - inputData: 変換対象のInputData。
    /// - Returns:
    ///   付加的な変換候補
    private func getAdditionalCandidate(_ inputData: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        var candidates: [Candidate] = []
        let string = inputData.convertTarget.toKatakana()
        let composingCount: ComposingCount = .inputCount(inputData.input.count)
        do {
            // カタカナ
            let value = -14 * getKatakanaScore(string)
            let data = DicdataElement(ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
            let katakana = Candidate(
                text: string,
                value: value,
                composingCount: composingCount,
                lastMid: MIDData.一般.mid,
                data: [data]
            )
            candidates.append(katakana)
        }
        let hiraganaString = string.toHiragana()
        do {
            // ひらがな
            let data = DicdataElement(word: hiraganaString, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14.5)

            let hiragana = Candidate(
                text: hiraganaString,
                value: -14.5,
                composingCount: composingCount,
                lastMid: MIDData.一般.mid,
                data: [data]
            )
            candidates.append(hiragana)
        }
        do {
            // 大文字
            let word = string.uppercased()
            let data = DicdataElement(word: word, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -15)
            let uppercasedLetter = Candidate(
                text: word,
                value: -14.6,
                composingCount: composingCount,
                lastMid: MIDData.一般.mid,
                data: [data]
            )
            candidates.append(uppercasedLetter)
        }
        if options.fullWidthRomanCandidate {
            // 全角英数字
            let word = string.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? ""
            let data = DicdataElement(word: word, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -15)
            let fullWidthLetter = Candidate(
                text: word,
                value: -14.7,
                composingCount: composingCount,
                lastMid: MIDData.一般.mid,
                data: [data]
            )
            candidates.append(fullWidthLetter)
        }
        if options.halfWidthKanaCandidate {
            // 半角カタカナ
            let word = string.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? ""
            let data = DicdataElement(word: word, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -15)
            let halfWidthKatakana = Candidate(
                text: word,
                value: -15,
                composingCount: composingCount,
                lastMid: MIDData.一般.mid,
                data: [data]
            )
            candidates.append(halfWidthKatakana)
        }

        return candidates
    }

    /// ラティスを処理し変換候補の形にまとめる関数
    /// - Parameters:
    ///   - inputData: 変換対象のInputData。
    ///   - result: convertToLatticeによって得られた結果。
    ///   - options: リクエストにかかるオプション。
    /// - Returns:
    ///   重複のない変換候補。
    /// - Note:
    ///   現在の実装は非常に複雑な方法で候補の順序を決定している。
    private func processResult(inputData: ComposingText, result: (result: LatticeNode, lattice: Lattice), options: ConvertRequestOptions) -> ConversionResult {
        self.previousInputData = inputData
        self.lattice = result.lattice
        // 比較的大きい配列（〜1000、2000程度の候補が含まれることがある）
        let clauseResult = result.result.getCandidateData()
        if clauseResult.isEmpty {
            let candidates = self.getUniqueCandidate(self.getAdditionalCandidate(inputData, options: options))
            return ConversionResult(mainResults: candidates, predictionResults: [], englishPredictionResults: [], firstClauseResults: candidates)   // アーリーリターン
        }

        // 予測変換用のベスト候補
        var bestCandidateDataForPrediction: CandidateData?
        // 文章全体を変換した場合の候補上位5件を作る（不要なときはlazyで中間配列を避ける）
        let wholeSentenceUniqueCandidates: [Candidate]
        if options.requireJapanesePrediction.isEnabled {
            let clauseResultCandidates = clauseResult.map { self.converter.processClauseCandidate($0) }
            bestCandidateDataForPrediction = zip(clauseResult, clauseResultCandidates).max {$0.1.value < $1.1.value}!.0
            wholeSentenceUniqueCandidates = self.getUniqueCandidate(clauseResultCandidates)
        } else {
            wholeSentenceUniqueCandidates = self.getUniqueCandidate(clauseResult.lazy.map { self.converter.processClauseCandidate($0) })
        }
        // ユーザショートカット（全文一致のみ）候補を抽出
        let userShortcutsCandidates: [Candidate] = {
            let ruby = inputData.convertTarget.toKatakana()
            guard !ruby.isEmpty else {
                return []
            }
            let dicdata = self.converter.dicdataStore.getPerfectMatchedUserShortcutsDicdata(ruby: ruby, state: self.dicdataStoreState)
            let composingCount: ComposingCount = .surfaceCount(inputData.convertTarget.count)
            return dicdata.map { data in
                Candidate(
                    text: data.word,
                    value: data.value(),
                    composingCount: composingCount,
                    lastMid: data.mid,
                    data: [data],
                    actions: [],
                    inputable: true,
                    isLearningTarget: false
                )
            }
        }()

        if case .完全一致 = options.requestQuery {
            let merged = self.getUniqueCandidate(wholeSentenceUniqueCandidates.chained(userShortcutsCandidates))
            if options.zenzaiMode.enabled {
                return ConversionResult(mainResults: consume merged, predictionResults: [], englishPredictionResults: [], firstClauseResults: [])
            } else {
                return ConversionResult(mainResults: (consume merged).sorted(by: {$0.value > $1.value}), predictionResults: [], englishPredictionResults: [], firstClauseResults: [])
            }
        }
        // モデル重みを統合
        let bestFiveSentenceCandidates: [Candidate]
        if options.zenzaiMode.enabled {
            // FIXME: もう少し良い方法はありそうだけど、短期的にかなりハックな実装にした
            // candidateのvalueをZenzaiの出力順に書き換えることで、このあとのrerank処理で騙されてくれるようになっている
            // より根本的には、`Candidate`にAI評価値をもたせるなどの方法が必要そう
            var first5 = Array(wholeSentenceUniqueCandidates.prefix(5))
            let values = first5.map(\.value).sorted(by: >)
            for (i, v) in zip(first5.indices, values) {
                first5[i].value = v
            }
            bestFiveSentenceCandidates = first5
        } else {
            bestFiveSentenceCandidates = wholeSentenceUniqueCandidates.min(count: 5, sortedBy: {$0.value > $1.value})
        }

        var predictionResults: [Candidate] = []
        var englishPredictionResults: [Candidate] = []
        let fullCandidates: [Candidate]
        do {
            // 予測変換を最大3件作成する（必要な場合のみsumsを構築）
            let bestThreePredictionCandidates: [Candidate]
            if options.requireJapanesePrediction.isEnabled, let bestCandidateDataForPrediction {
                let candidates = self.getUniqueCandidate(
                    self.getPredictionCandidate(bestCandidateDataForPrediction, composingText: inputData, options: options)
                ).min(count: 3, sortedBy: {$0.value > $1.value})
                predictionResults = candidates
                if options.requireJapanesePrediction.shouldMix {
                    bestThreePredictionCandidates = candidates
                } else {
                    bestThreePredictionCandidates = []
                }
            } else {
                bestThreePredictionCandidates = []
            }
            // 英単語の予測変換。appleのapiを使うため、処理が異なる。
            var foreignCandidates: [Candidate] = []
            if options.requireEnglishPrediction.isEnabled {
                var englishCandidates: [Candidate] = []
                englishCandidates.append(contentsOf: self.getForeignPredictionCandidate(inputData: inputData, language: "en-US"))
                if options.keyboardLanguage == .el_GR {
                    englishCandidates.append(contentsOf: self.getForeignPredictionCandidate(inputData: inputData, language: "el"))
                }
                englishPredictionResults = englishCandidates
                if options.requireEnglishPrediction.shouldMix {
                    foreignCandidates.append(contentsOf: englishCandidates)
                }
            }
            // その他のトップレベル変換（先頭に表示されうる変換候補）
            let topLevelAdditionalCandidates = self.getTopLevelAdditionalCandidate(inputData, options: options)
            // best8、foreign_candidates、zeroHintPrediction_candidates、toplevel_additional_candidate、user_shortcuts を混ぜて上位5件を取得する
            fullCandidates = getUniqueCandidate(
                bestFiveSentenceCandidates
                    .chained(consume bestThreePredictionCandidates)
                    .chained(consume foreignCandidates)
                    .chained(consume topLevelAdditionalCandidates)
                    .chained(consume userShortcutsCandidates)
            ).min(count: 5, sortedBy: {$0.value > $1.value})
        }
        // 文節のみ変換するパターン（上位5件）
        let uniqueFirstClauseCandidates = self.getUniqueCandidate((consume clauseResult).lazy.map {(candidateData: CandidateData) -> Candidate in
            let first = candidateData.clauses.first!
            let count = max(0, first.clause.dataEndIndex)
            return Candidate(
                text: first.clause.text,
                value: first.value,
                composingCount: first.clause.ranges.reduce(into: .inputCount(0)) { $0 = .composite($0, $1.count) },
                lastMid: first.clause.mid,
                data: Array(candidateData.data[0...count])
            )
        })

        var firstClauseResults = uniqueFirstClauseCandidates.min(count: 5) {
            if $0.rubyCount == $1.rubyCount {
                $0.value > $1.value
            } else {
                $0.rubyCount > $1.rubyCount
            }
        }
        // 重複のない変換候補を作成するための集合
        var seenCandidate: Set<String> = fullCandidates.mapSet {$0.text}
        // 文節のみ変換するパターン（上位5件）
        let firstClauseCandidates = self.getUniqueCandidate(consume uniqueFirstClauseCandidates, seenCandidates: seenCandidate).min(count: 5) {
            if $0.rubyCount == $1.rubyCount {
                $0.value > $1.value
            } else {
                $0.rubyCount > $1.rubyCount
            }
        }
        for c in firstClauseCandidates {
            seenCandidate.insert(c.text)
        }
        // 文字列の長さごとに並べ、かつその中で評価の高いものから順に並べる。
        let wordCandidates: [Candidate]
        do {
            // 最初の辞書データ
            let dicCandidates: [Candidate] = result.lattice[index: .bothIndex(inputIndex: 0, surfaceIndex: 0)]
                .map {
                    Candidate(
                        text: $0.data.word,
                        value: $0.data.value(),
                        composingCount: $0.range.count,
                        lastMid: $0.data.mid,
                        data: [$0.data]
                    )
                }
            // その他辞書データに追加する候補
            let additionalCandidates: [Candidate] = self.getAdditionalCandidate(inputData, options: options)
            var candidates = self.getUniqueCandidate((consume dicCandidates).chained(consume additionalCandidates), seenCandidates: seenCandidate)
                .sorted {
                    let count0 = $0.rubyCount
                    let count1 = $1.rubyCount
                    return count0 == count1 ? $0.value > $1.value : count0 > count1
                }
            for c in candidates {
                seenCandidate.insert(c.text)
            }
            // 賢く変換するパターン（任意件数）
            let wiseCandidates = self.getUniqueCandidate(self.getSpecialCandidate(inputData, options: options), seenCandidates: seenCandidate)
            // 途中でwise_candidatesを挟む
            candidates.insert(contentsOf: consume wiseCandidates, at: min(5, candidates.endIndex))
            wordCandidates = consume candidates
        }

        var result = consume fullCandidates
        // 3番目までに最低でも1つ、（誤り訂正ではなく）入力に完全一致する候補が入るようにする
        let checkRuby: (Candidate) -> Bool = {$0.data.reduce(into: "") {$0 += $1.ruby} == inputData.convertTarget.toKatakana()}
        if !result.prefix(3).contains(where: checkRuby) {
            if let candidateIndex = result.dropFirst(3).firstIndex(where: checkRuby) {
                // 3番目以降にある場合は順位を入れ替える
                let candidate = result.remove(at: candidateIndex)
                result.insert(candidate, at: min(result.endIndex, 2))
            } else if let candidate = bestFiveSentenceCandidates.first(where: checkRuby) {
                result.insert(candidate, at: min(result.endIndex, 2))
            } else if let candidate = wholeSentenceUniqueCandidates.first(where: checkRuby) {
                result.insert(candidate, at: min(result.endIndex, 2))
            }
        }

        result.append(contentsOf: consume firstClauseCandidates)
        result.append(contentsOf: consume wordCandidates)

        result.mutatingForEach { item in
            item.withActions(self.getAppropriateActions(item))
            item.parseTemplate()
        }
        firstClauseResults.mutatingForEach { item in
            item.withActions(self.getAppropriateActions(item))
            item.parseTemplate()
        }
        predictionResults.mutatingForEach { item in
            item.withActions(self.getAppropriateActions(item))
            item.parseTemplate()
        }
        englishPredictionResults.mutatingForEach { item in
            item.withActions(self.getAppropriateActions(item))
            item.parseTemplate()
        }
        return ConversionResult(mainResults: result, predictionResults: predictionResults, englishPredictionResults: englishPredictionResults, firstClauseResults: firstClauseResults)
    }

    /// 入力からラティスを構築する関数。状況に応じて呼ぶ関数を分ける。
    /// - Parameters:
    ///   - inputData: 変換対象のInputData。
    ///   - N_best: 計算途中で保存する候補数。実際に得られる候補数とは異なる。
    /// - Returns:
    ///   結果のラティスノードと、計算済みノードの全体
    private func convertToLattice(_ inputData: ComposingText, N_best: Int, zenzaiMode: ConvertRequestOptions.ZenzaiMode, needTypoCorrection: Bool) -> (result: LatticeNode, lattice: Lattice)? {
        if inputData.convertTarget.isEmpty {
            return nil
        }

        // FIXME: enable cache based zenzai
        if zenzaiMode.enabled, let model = self.getModel(modelURL: zenzaiMode.weightURL) {
            let (result, nodes, cache) = self.converter.all_zenzai(
                inputData,
                zenz: model,
                zenzaiCache: self.zenzaiCache,
                inferenceLimit: zenzaiMode.inferenceLimit,
                requestRichCandidates: zenzaiMode.requestRichCandidates,
                personalizationMode: self.getZenzaiPersonalization(mode: zenzaiMode.personalizationMode),
                versionDependentConfig: zenzaiMode.versionDependentMode,
                dicdataStoreState: self.dicdataStoreState
            )
            self.zenzaiCache = cache
            self.previousInputData = inputData
            return (result, nodes)
        }

        guard let previousInputData else {
            debug("\(#function): 新規計算用の関数を呼びますA")
            let result = converter.kana2lattice_all(
                inputData,
                N_best: N_best,
                needTypoCorrection: needTypoCorrection,
                dicdataStoreState: self.dicdataStoreState
            )
            self.previousInputData = inputData
            return result
        }

        debug("\(#function): before \(previousInputData) after \(inputData)")

        // 完全一致の場合
        if previousInputData == inputData {
            let result = converter.kana2lattice_no_change(N_best: N_best, previousResult: (inputData: previousInputData, lattice: self.lattice))
            self.previousInputData = inputData
            return result
        }

        // 文節確定の後の場合
        if let completedData, previousInputData.inputHasSuffix(inputOf: inputData) {
            debug("\(#function): 文節確定用の関数を呼びます、確定された文節は\(completedData)")
            let result = converter.kana2lattice_afterComplete(inputData, completedData: completedData, N_best: N_best, previousResult: (inputData: previousInputData, lattice: self.lattice), needTypoCorrection: needTypoCorrection)
            self.previousInputData = inputData
            self.completedData = nil
            return result
        }

        // TODO: 元々はsuffixになっていないが、文節確定の後であるケースで、確定された文節を考慮できるようにする
        // へんかん|する → 変換 する|　のようなパターンで、previousInputData: へんかん, inputData: する, となることがある

        let diff = inputData.differenceSuffix(to: previousInputData)

        debug("\(#function): 最後尾文字置換用の関数を呼びます、差分は\(diff)")
        let result = converter.kana2lattice_changed(
            inputData,
            N_best: N_best,
            counts: diff,
            previousResult: (inputData: previousInputData, lattice: self.lattice),
            needTypoCorrection: needTypoCorrection,
            dicdataStoreState: self.dicdataStoreState
        )
        self.previousInputData = inputData
        return result
    }

    public func getAppropriateActions(_ candidate: Candidate) -> [CompleteAction] {
        if ["[]", "()", "｛｝", "〈〉", "〔〕", "（）", "「」", "『』", "【】", "{}", "<>", "《》", "\"\"", "\'\'", "””"].contains(candidate.text) {
            return [.moveCursor(-1)]
        }
        if ["{{}}"].contains(candidate.text) {
            return [.moveCursor(-2)]
        }
        return []
    }

    /// 2つの連続する`Candidate`をマージする
    public func mergeCandidates(_ left: Candidate, _ right: Candidate) -> Candidate {
        converter.mergeCandidates(left, right)
    }

    /// 外部から呼ばれる変換候補を要求する関数。
    /// - Parameters:
    ///   - inputData: 変換対象のInputData。
    ///   - options: リクエストにかかるパラメータ。
    /// - Returns: `ConversionResult`
    public func requestCandidates(_ inputData: ComposingText, options: ConvertRequestOptions) -> ConversionResult {
        debug("requestCandidates 入力は", inputData)
        // 変換対象が無の場合
        if inputData.convertTarget.isEmpty {
            return ConversionResult(mainResults: [], predictionResults: [], englishPredictionResults: [], firstClauseResults: [])
        }
        if options.shouldResetMemory {
            self.resetMemory()
        }
        self.dicdataStoreState.updateIfRequired(options: options)
        #if os(iOS)
        let needTypoCorrection = options.needTypoCorrection ?? true
        #else
        let needTypoCorrection = options.needTypoCorrection ?? false
        #endif

        guard let result = self.convertToLattice(inputData, N_best: options.N_best, zenzaiMode: options.zenzaiMode, needTypoCorrection: needTypoCorrection) else {
            return ConversionResult(mainResults: [], predictionResults: [], englishPredictionResults: [], firstClauseResults: [])
        }

        return self.processResult(inputData: inputData, result: result, options: options)
    }

    /// 変換確定後の予測変換候補を要求する関数
    public func requestPostCompositionPredictionCandidates(leftSideCandidate: Candidate, options: ConvertRequestOptions) -> [PostCompositionPredictionCandidate] {
        // ゼロヒント予測変換に基づく候補を列挙
        var zeroHintResults = self.getUniquePostCompositionPredictionCandidate(self.converter.getZeroHintPredictionCandidates(preparts: [leftSideCandidate], N_best: 15))
        do {
            // 助詞は最大3つに制限する
            var joshiCount = 0
            zeroHintResults = zeroHintResults.reduce(into: []) { results, candidate in
                switch candidate.type {
                case .additional(data: let data):
                    if CIDData.isJoshi(cid: data.last?.rcid ?? CIDData.EOS.cid) {
                        if joshiCount < 3 {
                            results.append(candidate)
                            joshiCount += 1
                        }
                    } else {
                        results.append(candidate)
                    }
                case .replacement:
                    results.append(candidate)
                }
            }
        }

        // 予測変換に基づく候補を列挙
        let predictionResults = self.converter.getPredictionCandidates(
            prepart: leftSideCandidate,
            N_best: 15,
            dicdataStoreState: self.dicdataStoreState
        )
        // 絵文字を追加
        let replacer = options.textReplacer
        var emojiCandidates: [PostCompositionPredictionCandidate] = []
        for data in leftSideCandidate.data where DicdataStore.includeMMValueCalculation(data) {
            let result = replacer.getSearchResult(query: data.word, target: [.emoji], ignoreNonBaseEmoji: true)
            for emoji in result {
                emojiCandidates.append(PostCompositionPredictionCandidate(text: emoji.text, value: -3, type: .additional(data: [.init(word: emoji.text, ruby: "エモジ", cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: -3)])))
            }
        }
        emojiCandidates = self.getUniquePostCompositionPredictionCandidate(emojiCandidates)

        var results: [PostCompositionPredictionCandidate] = []
        var seenCandidates: Set<String> = []

        results.append(contentsOf: emojiCandidates.suffix(3))
        for c in emojiCandidates.suffix(3) {
            seenCandidates.insert(c.text)
        }
        // 残りの半分。ただしzeroHintResultsが足りない場合は全部で10個になるようにする。
        let predictionsCount = max((10 - results.count) / 2, 10 - results.count - zeroHintResults.count)
        let predictions = self.getUniquePostCompositionPredictionCandidate(predictionResults, seenCandidates: seenCandidates).min(count: predictionsCount, sortedBy: {$0.value > $1.value})
        results.append(contentsOf: predictions)
        for c in predictions {
            seenCandidates.insert(c.text)
        }

        let zeroHints = self.getUniquePostCompositionPredictionCandidate(zeroHintResults, seenCandidates: seenCandidates)
        results.append(contentsOf: zeroHints.min(count: 10 - results.count, sortedBy: {$0.value > $1.value}))
        return results
    }
}
