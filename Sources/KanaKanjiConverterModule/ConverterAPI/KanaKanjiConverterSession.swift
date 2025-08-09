//
//  KanaKanjiConverterSession.swift
//  AzooKeyKanaKanjiConverter
//
//  A per-conversion session cache holder that isolates state like lattice,
//  previous input, and zenzai cache from other sessions.
//

import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

@MainActor public final class KanaKanjiConverterSession {
    private unowned let converter: KanaKanjiConverter

    // Session-local caches/state
    private var previousInputData: ComposingText?
    private var lattice: Lattice = Lattice()
    private var completedData: Candidate?
    private var lastData: DicdataElement?
    private var zenzaiCache: Kana2Kanji.ZenzaiCache?

    public init(converter: KanaKanjiConverter) {
        self.converter = converter
    }

    // MARK: - Session state for DicdataStore
    let state = DicdataStoreState()
    /// Update session state (e.g., dynamic user dictionary)
    public func updateConfiguration(_ update: (inout [DicdataElement]) -> Void) {
        update(&self.state.dynamicUserDict)
    }

    public func stop() {
        // Reset only session-local states
        self.zenzaiCache = nil
        self.previousInputData = nil
        self.lattice = .init()
        self.completedData = nil
        self.lastData = nil
        // do not touch long-term memory here
    }

    public func setCompletedData(_ candidate: Candidate) {
        self.completedData = candidate
    }

    // Persist session learning into long-term memory
    public func saveLearning() {
        self.state.save()
        self.converter.converterCore.dicdataStore.reloadUser()
        self.converter.converterCore.dicdataStore.reloadMemory()
    }

    // Forget specified candidate from learning (both temporary and long-term)
    public func forgetMemory(_ candidate: Candidate) {
        self.state.forget(candidate)
        self.converter.converterCore.dicdataStore.reloadMemory()
    }

    // Import dynamic user dictionary into this session
    public func importDynamicUserDictionary(_ dicdata: [DicdataElement]) {
        self.state.dynamicUserDict = dicdata
        self.state.dynamicUserDict.mutatingForEach { element in
            element.metadata = .isFromUserDictionary
        }
    }

    public func setKeyboardLanguage(_ language: KeyboardLanguage) {
        self.converter.warmupSpellChecker(language)
        self.state.keyboardLanguage = language
    }

    public func updateLearningData(_ candidate: Candidate) {
        // Update learning memory (session-scoped temporary memory)
        if let previous = self.lastData {
            self.state.learningManager.update(data: [previous] + candidate.data)
        } else {
            self.state.learningManager.update(data: candidate.data)
        }
        self.lastData = candidate.data.last
    }

    public func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        switch predictionCandidate.type {
        case .additional(data: let data):
            self.state.learningManager.update(data: candidate.data, updatePart: data)
        case .replacement(targetData: let targetData, replacementData: let replacementData):
            self.state.learningManager.update(data: candidate.data.dropLast(targetData.count), updatePart: replacementData)
        }
        self.lastData = predictionCandidate.lastData
    }

    public var zenzStatus: String { converter.zenzStatus }

    // MARK: - Public conversion APIs

    public func requestCandidates(_ inputData: ComposingText, options: ConvertRequestOptions) -> ConversionResult {
        // メモリのリセットが必要である場合、このタイミングでまず実施する
        if options.shouldResetMemory {
            let resetSuceess = self.state.resetLearning()
            if resetSuceess {
                self.converter.converterCore.dicdataStore.reloadMemory()
            }
        }
        let learningManagerConfiguration = LearningManagerConfiguration(from: options)
        self.state.learningManager.updateConfiguration(learningManagerConfiguration)


        // empty input → no candidates
        if inputData.convertTarget.isEmpty {
            return ConversionResult(mainResults: [], firstClauseResults: [])
        }
        // Note: Do not mutate shared DicdataStore options here.
        // Caller (app/CLI) should set request options on converter upfront to avoid cross-session interference.

        #if os(iOS)
        let needTypoCorrection = options.needTypoCorrection ?? true
        #else
        let needTypoCorrection = options.needTypoCorrection ?? false
        #endif

        guard let latticeResult = self.convertToLattice(inputData, N_best: options.N_best, zenzaiMode: options.zenzaiMode, needTypoCorrection: needTypoCorrection) else {
            return ConversionResult(mainResults: [], firstClauseResults: [])
        }
        return self.processResult(inputData: inputData, result: latticeResult, options: options)
    }

    public func requestPostCompositionPredictionCandidates(leftSideCandidate: Candidate, options: ConvertRequestOptions) -> [PostCompositionPredictionCandidate] {
        var zeroHintResults = self.getUniquePostCompositionPredictionCandidate(self.converter.converterCore.getZeroHintPredictionCandidates(preparts: [leftSideCandidate], N_best: 15))
        do {
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

        let predictionResults = self.converter.converterCore.getPredictionCandidates(prepart: leftSideCandidate, N_best: 15, state: self.state)

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
        seenCandidates.formUnion(emojiCandidates.suffix(3).map { $0.text })

        let predictionsCount = max((10 - results.count) / 2, 10 - results.count - zeroHintResults.count)
        let predictions = self.getUniquePostCompositionPredictionCandidate(predictionResults, seenCandidates: seenCandidates).min(count: predictionsCount, sortedBy: { $0.value > $1.value })
        results.append(contentsOf: predictions)
        seenCandidates.formUnion(predictions.map { $0.text })

        let zeroHints = self.getUniquePostCompositionPredictionCandidate(zeroHintResults, seenCandidates: seenCandidates)
        results.append(contentsOf: zeroHints.min(count: 10 - results.count, sortedBy: { $0.value > $1.value }))
        return results
    }

    // MARK: - Internal helpers (session versions)

    private func getUniqueCandidate(_ candidates: some Sequence<Candidate>, seenCandidates: Set<String> = []) -> [Candidate] {
        var result = [Candidate]()
        var textIndex = [String: Int]()
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

    private func getUniquePostCompositionPredictionCandidate(_ candidates: some Sequence<PostCompositionPredictionCandidate>, seenCandidates: Set<String> = []) -> [PostCompositionPredictionCandidate] {
        var result = [PostCompositionPredictionCandidate]()
        for candidate in candidates where !candidate.text.isEmpty && !seenCandidates.contains(candidate.text) {
            if let index = result.firstIndex(where: { $0.text == candidate.text }) {
                if result[index].value < candidate.value {
                    result[index] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    // Use shared spell checker from converter to leverage its warm-up

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
            if let completions = self.converter.sharedChecker.completions(forPartialWordRange: range, in: ruby, language: language) {
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
            if let completions = self.converter.sharedChecker.completions(forPartialWordRange: range, in: ruby, language: language) {
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

    private func getPredictionCandidate(_ sums: [(CandidateData, Candidate)], composingText: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        var candidates: [Candidate] = []
        var prepart: CandidateData = sums.max { $0.1.value < $1.1.value }!.0
        var lastpart: CandidateData.ClausesUnit?
        var count = 0
        while true {
            if count == 2 { break }
            if prepart.isEmpty { break }
            if let oldlastPart = lastpart {
                let lastUnit = prepart.clauses.popLast()!
                let newUnit = lastUnit.clause
                newUnit.merge(with: oldlastPart.clause)
                let newValue = lastUnit.value + oldlastPart.value
                let newlastPart: CandidateData.ClausesUnit = (clause: newUnit, value: newValue)
                let predictions = self.converter.converterCore.getPredictionCandidates(composingText: composingText, prepart: prepart, lastClause: newlastPart.clause, N_best: 5, state: self.state)
                lastpart = newlastPart
                if !predictions.isEmpty {
                    candidates += predictions
                    count += 1
                }
            } else {
                lastpart = prepart.clauses.popLast()
                let predictions = self.converter.converterCore.getPredictionCandidates(composingText: composingText, prepart: prepart, lastClause: lastpart!.clause, N_best: 5, state: self.state)
                if !predictions.isEmpty {
                    candidates += predictions
                    count += 1
                }
            }
        }
        return candidates
    }

    private func getTopLevelAdditionalCandidate(_ inputData: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        var candidates: [Candidate] = []
        if options.englishCandidateInRoman2KanaInput, inputData.input.allSatisfy({ if case let .character(c) = $0.piece { c.isASCII } else { false } }) {
            candidates.append(contentsOf: self.getForeignPredictionCandidate(inputData: inputData, language: "en-US", penalty: -10))
        }
        return candidates
    }

    // Additional candidates like hiragana/katakana/fullwidth/halfwidth transformations
    private func getAdditionalCandidate(_ inputData: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        var candidates: [Candidate] = []
        let string = inputData.convertTarget.toKatakana()
        let composingCount: ComposingCount = .inputCount(inputData.input.count)
        do {
            let value: PValue = -14 * {
                var score: PValue = 1
                for c in string {
                    if "プヴペィフ".contains(c) { score *= 0.5 } else if "ュピポ".contains(c) { score *= 0.6 } else if "パォグーム".contains(c) { score *= 0.7 }
                }
                return score
            }()
            let data = DicdataElement(ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
            let katakana = Candidate(text: string, value: value, composingCount: composingCount, lastMid: MIDData.一般.mid, data: [data])
            candidates.append(katakana)
        }
        let hiraganaString = string.toHiragana()
        do {
            let data = DicdataElement(word: hiraganaString, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14.5)
            let hiragana = Candidate(text: hiraganaString, value: -14.5, composingCount: composingCount, lastMid: MIDData.一般.mid, data: [data])
            candidates.append(hiragana)
        }
        do {
            let word = string.uppercased()
            let data = DicdataElement(word: word, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -15)
            let uppercasedLetter = Candidate(text: word, value: -14.6, composingCount: composingCount, lastMid: MIDData.一般.mid, data: [data])
            candidates.append(uppercasedLetter)
        }
        if options.fullWidthRomanCandidate {
            let word = string.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? ""
            let data = DicdataElement(word: word, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -15)
            let fullWidthLetter = Candidate(text: word, value: -14.7, composingCount: composingCount, lastMid: MIDData.一般.mid, data: [data])
            candidates.append(fullWidthLetter)
        }
        if options.halfWidthKanaCandidate {
            let word = string.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? ""
            let data = DicdataElement(word: word, ruby: string, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -15)
            let halfWidthKatakana = Candidate(text: word, value: -15, composingCount: composingCount, lastMid: MIDData.一般.mid, data: [data])
            candidates.append(halfWidthKatakana)
        }
        return candidates
    }

    // Build lattice for the given input using session-local caches
    private func convertToLattice(_ inputData: ComposingText, N_best: Int, zenzaiMode: ConvertRequestOptions.ZenzaiMode, needTypoCorrection: Bool) -> (result: LatticeNode, lattice: Lattice)? {
        if inputData.convertTarget.isEmpty { return nil }

        if zenzaiMode.enabled, let model = self.converter.getModel(modelURL: zenzaiMode.weightURL) {
            let (result, nodes, cache) = self.converter.converterCore.all_zenzai(
                inputData,
                zenz: model,
                zenzaiCache: self.zenzaiCache,
                inferenceLimit: zenzaiMode.inferenceLimit,
                requestRichCandidates: zenzaiMode.requestRichCandidates,
                personalizationMode: self.converter.getZenzaiPersonalization(mode: zenzaiMode.personalizationMode),
                versionDependentConfig: zenzaiMode.versionDependentMode,
                state: self.state
            )
            self.zenzaiCache = cache
            self.previousInputData = inputData
            return (result, nodes)
        }

        guard let previousInputData else {
            let result = self.converter.converterCore.kana2lattice_all(inputData, N_best: N_best, needTypoCorrection: needTypoCorrection, state: self.state)
            self.previousInputData = inputData
            return result
        }

        if previousInputData == inputData {
            let result = self.converter.converterCore.kana2lattice_no_change(N_best: N_best, previousResult: (inputData: previousInputData, lattice: self.lattice))
            self.previousInputData = inputData
            return result
        }

        if let completedData, previousInputData.inputHasSuffix(inputOf: inputData) {
            let result = self.converter.converterCore.kana2lattice_afterComplete(inputData, completedData: completedData, N_best: N_best, previousResult: (inputData: previousInputData, lattice: self.lattice), needTypoCorrection: needTypoCorrection, state: self.state)
            self.previousInputData = inputData
            self.completedData = nil
            return result
        }

        let diff = inputData.differenceSuffix(to: previousInputData)
        let result = self.converter.converterCore.kana2lattice_changed(inputData, N_best: N_best, counts: diff, previousResult: (inputData: previousInputData, lattice: self.lattice), needTypoCorrection: needTypoCorrection, state: self.state)
        self.previousInputData = inputData
        return result
    }

    private func processResult(inputData: ComposingText, result: (result: LatticeNode, lattice: Lattice), options: ConvertRequestOptions) -> ConversionResult {
        self.previousInputData = inputData
        self.lattice = result.lattice
        let clauseResult = result.result.getCandidateData()
        if clauseResult.isEmpty {
            let candidates = self.getUniqueCandidate(self.getAdditionalCandidate(inputData, options: options))
            return ConversionResult(mainResults: candidates, firstClauseResults: candidates)
        }
        let clauseCandidates: [Candidate] = clauseResult.map { (candidateData: CandidateData) -> Candidate in
            let first = candidateData.clauses.first!
            var count = 0
            do {
                var str = ""
                while true {
                    str += candidateData.data[count].word
                    if str == first.clause.text { break }
                    count += 1
                }
            }
            return Candidate(
                text: first.clause.text,
                value: first.value,
                composingCount: first.clause.ranges.reduce(into: .inputCount(0)) { $0 = .composite($0, $1.count) },
                lastMid: first.clause.mid,
                data: Array(candidateData.data[0...count])
            )
        }
        let sums: [(CandidateData, Candidate)] = clauseResult.map { ($0, self.converter.converterCore.processClauseCandidate($0)) }

        let whole_sentence_unique_candidates = self.getUniqueCandidate(sums.map { $0.1 })
        if case .完全一致 = options.requestQuery {
            if options.zenzaiMode.enabled {
                return ConversionResult(mainResults: whole_sentence_unique_candidates, firstClauseResults: [])
            } else {
                return ConversionResult(mainResults: whole_sentence_unique_candidates.sorted(by: { $0.value > $1.value }), firstClauseResults: [])
            }
        }

        let sentence_candidates: [Candidate]
        if options.zenzaiMode.enabled {
            var first5 = Array(whole_sentence_unique_candidates.prefix(5))
            let values = first5.map(\.value).sorted(by: >)
            for (i, v) in zip(first5.indices, values) { first5[i].value = v }
            sentence_candidates = first5
        } else {
            sentence_candidates = whole_sentence_unique_candidates.min(count: 5, sortedBy: { $0.value > $1.value })
        }

        let prediction_candidates: [Candidate] = options.requireJapanesePrediction ? Array(self.getUniqueCandidate(self.getPredictionCandidate(sums, composingText: inputData, options: options)).min(count: 3, sortedBy: { $0.value > $1.value })) : []

        var foreign_candidates: [Candidate] = []
        if options.requireEnglishPrediction {
            foreign_candidates.append(contentsOf: self.getForeignPredictionCandidate(inputData: inputData, language: "en-US"))
        }
        if options.keyboardLanguage == .el_GR {
            foreign_candidates.append(contentsOf: self.getForeignPredictionCandidate(inputData: inputData, language: "el"))
        }

        let best8 = getUniqueCandidate(sentence_candidates.prefix(5).chained(prediction_candidates)).sorted { $0.value > $1.value }
        let toplevel_additional_candidate = self.getTopLevelAdditionalCandidate(inputData, options: options)
        let full_candidate = getUniqueCandidate(
            best8
                .chained(foreign_candidates)
                .chained(toplevel_additional_candidate)
        ).min(count: 5, sortedBy: { $0.value > $1.value })

        var seenCandidate: Set<String> = full_candidate.mapSet { $0.text }
        let clause_candidates = self.getUniqueCandidate(clauseCandidates, seenCandidates: seenCandidate).min(count: 5) {
            if $0.rubyCount == $1.rubyCount {
                $0.value > $1.value
            } else {
                $0.rubyCount > $1.rubyCount
            }
        }
        seenCandidate.formUnion(clause_candidates.map { $0.text })

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
        let additionalCandidates: [Candidate] = self.getAdditionalCandidate(inputData, options: options)

        var word_candidates: [Candidate] = self.getUniqueCandidate(dicCandidates.chained(additionalCandidates), seenCandidates: seenCandidate)
            .sorted {
                let count0 = $0.rubyCount
                let count1 = $1.rubyCount
                return count0 == count1 ? $0.value > $1.value : count0 > count1
            }
        seenCandidate.formUnion(word_candidates.map { $0.text })

        let wise_candidates: [Candidate] = options.specialCandidateProviders.flatMap { provider in
            provider.provideCandidates(converter: self.converter, inputData: inputData, options: options)
        }
        word_candidates.insert(contentsOf: wise_candidates, at: min(5, word_candidates.endIndex))

        var result = Array(full_candidate)
        if let first = result.indices.first {
            result[first].withActions(self.converter.getAppropriateActions(result[first]))
            result[first].parseTemplate()
        }
        var firstClauseResults = clause_candidates
        firstClauseResults.mutatingForEach { item in
            item.withActions(self.converter.getAppropriateActions(item))
            item.parseTemplate()
        }
        return ConversionResult(mainResults: result, firstClauseResults: firstClauseResults)
    }
}
