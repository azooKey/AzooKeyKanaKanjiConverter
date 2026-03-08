//
//  mid_composition_prediction.swift
//  AzooKeyKanaKanjiConverter
//
//  Created by ensan on 2020/12/09.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import SwiftUtils

struct PredictiveInputCacheContext: Sendable, Equatable {
    var leftSideContext: String
    var inputStyle: InputStyle
    var weightURL: URL
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
}

struct PredictiveInputCacheEntry: Sendable, Equatable {
    var context: PredictiveInputCacheContext
    var originalConvertTarget: String
    var suffixCount: Int
    var predictedText: String

    func remainingPrediction(currentConvertTarget: String, count: Int) -> String? {
        guard count > 0 else {
            return nil
        }
        let droppedSuffixCount = min(max(self.suffixCount, 0), self.originalConvertTarget.count)
        let baseConvertTarget = String(self.originalConvertTarget.dropLast(droppedSuffixCount))
        guard currentConvertTarget.hasPrefix(baseConvertTarget) else {
            return nil
        }

        let consumedInsertText = String(currentConvertTarget.dropFirst(baseConvertTarget.count))
        let predictedInsertText = if self.context.inputStyle == .roman2kana {
            self.predictedText.toHiragana()
        } else {
            self.predictedText
        }
        guard predictedInsertText.hasPrefix(consumedInsertText) else {
            return nil
        }

        let consumedCount = consumedInsertText.count
        guard consumedCount < self.predictedText.count else {
            return nil
        }
        return String(self.predictedText.dropFirst(consumedCount).prefix(count))
    }
}

struct StablePredictionCandidateCacheEntry: Sendable {
    var originalConvertTarget: String
    var suffixCount: Int
    var candidates: [Candidate]

    func compatibleCandidates(
        currentConvertTarget: String,
        baseConvertTarget: String,
        possibleNexts: [String]
    ) -> [Candidate] {
        let droppedSuffixCount = min(max(self.suffixCount, 0), self.originalConvertTarget.count)
        let cachedBaseConvertTarget = String(self.originalConvertTarget.dropLast(droppedSuffixCount))
        guard baseConvertTarget.hasPrefix(cachedBaseConvertTarget) else {
            return []
        }
        let compatiblePrefixes = if possibleNexts.isEmpty {
            [currentConvertTarget.toKatakana()]
        } else {
            possibleNexts.map { (baseConvertTarget + $0).toKatakana() }
        }
        let currentRuby = currentConvertTarget.toKatakana()
        return self.candidates.filter { candidate in
            let candidateRuby = if candidate.data.isEmpty {
                candidate.text.toKatakana()
            } else {
                candidate.data.reduce(into: "", { $0 += $1.ruby })
            }
            return !candidate.text.isEmpty &&
                candidateRuby != currentRuby &&
                compatiblePrefixes.contains(where: { prefix in
                    candidateRuby.hasPrefix(prefix)
                })
        }
    }
}

struct PredictiveInputSource: Sendable, Equatable {
    var baseConvertTarget: String
    var possibleNexts: [String]
    var droppedSuffixCount: Int
}

// 変換中の予測変換に関する実装
extension Kana2Kanji {
    func resolvePredictiveInputSource(
        composingText: ComposingText,
        inputStyle: InputStyle
    ) -> PredictiveInputSource {
        if inputStyle == .direct {
            return .init(baseConvertTarget: composingText.convertTarget, possibleNexts: [], droppedSuffixCount: 0)
        }

        let table: InputTable
        if case .roman2kana = inputStyle {
            table = InputStyleManager.shared.table(for: .defaultRomanToKana)
        } else if case .mapped(let id) = inputStyle {
            table = InputStyleManager.shared.table(for: id)
        } else {
            return .init(baseConvertTarget: composingText.convertTarget, possibleNexts: [], droppedSuffixCount: 0)
        }

        if let suffixInfo = Self.romanSuffixAndPossibleNexts(composingText: composingText, table: table) {
            return .init(
                baseConvertTarget: suffixInfo.baseConvertTarget,
                possibleNexts: suffixInfo.possibleNexts,
                droppedSuffixCount: composingText.convertTarget.count - suffixInfo.baseConvertTarget.count
            )
        }
        return .init(baseConvertTarget: composingText.convertTarget, possibleNexts: [], droppedSuffixCount: 0)
    }

    private static func romanSuffixAndPossibleNexts(
        composingText: ComposingText,
        table: InputTable
    ) -> (baseConvertTarget: String, possibleNexts: [String])? {
        let romanSuffix = composingText.convertTarget.suffix(while: { String($0).onlyRomanAlphabet })
        guard !romanSuffix.isEmpty else {
            return nil
        }
        let possibleNexts = table.possibleNexts[String(romanSuffix), default: []]
        guard !possibleNexts.isEmpty else {
            return nil
        }
        return (String(composingText.convertTarget.dropLast(romanSuffix.count)), possibleNexts)
    }

    /// CandidateDataの状態から予測変換候補を取得する関数
    /// - parameters:
    ///   - prepart: CandidateDataで、予測変換候補に至る前の部分。例えば「これはき」の「き」の部分から予測をする場合「これは」の部分がprepart。
    ///   - lastRuby:
    ///     「これはき」の「き」の部分
    ///   - N_best: 取得する数
    /// - returns:
    ///    「これはき」から「これは今日」に対応する候補などを作って返す。
    /// - note:
    ///     この関数の役割は意味連接の考慮にある。
    func getPredictionCandidates(composingText: ComposingText, prepart: CandidateData, lastClause: ClauseDataUnit, N_best: Int, dicdataStoreState: DicdataStoreState) -> [Candidate] {
        debug(#function, composingText, lastClause.ranges, lastClause.text)
        let lastRuby = lastClause.ranges.reduce(into: "") {
            let ruby = switch $1 {
            case let .input(left, right):
                ComposingText.getConvertTarget(for: composingText.input[left..<right]).toKatakana()
            case let .surface(left, right):
                String(composingText.convertTarget.dropFirst(left).prefix(right - left)).toKatakana()
            }
            $0.append(ruby)
        }
        let lastRubyCount = lastRuby.count
        let datas: [DicdataElement]
        do {
            var _str = ""
            let prestring: String = prepart.clauses.reduce(into: "") {$0.append(contentsOf: $1.clause.text)}
            var count: Int = .zero
            while true {
                if prestring == _str {
                    break
                }
                _str += prepart.data[count].word
                count += 1
            }
            datas = Array(prepart.data.prefix(count))
        }

        let osuserdict: [DicdataElement] = dicdataStore.getPrefixMatchDynamicUserDict(lastRuby, state: dicdataStoreState)

        let lastCandidate: Candidate = prepart.isEmpty ? Candidate(text: "", value: .zero, composingCount: .inputCount(0), lastMid: MIDData.EOS.mid, data: []) : self.processClauseCandidate(prepart)
        let lastRcid: Int = lastCandidate.data.last?.rcid ?? CIDData.BOS.cid
        let nextLcid: Int = prepart.lastClause?.nextLcid ?? CIDData.BOS.cid
        let lastMid: Int = lastCandidate.lastMid
        let composingCount: ComposingCount = .composite(lastCandidate.composingCount, .surfaceCount(lastRubyCount))
        let ignoreCCValue: PValue = self.dicdataStore.getCCValue(lastRcid, nextLcid)

        let inputStyle = composingText.input.last?.inputStyle ?? .direct
        let dicdata: [DicdataElement]
        switch inputStyle {
        case .direct:
            dicdata = self.dicdataStore.getPredictionLOUDSDicdata(key: lastRuby, state: dicdataStoreState)
        case .roman2kana, .mapped:
            let table = if case let .mapped(id) = inputStyle {
                InputStyleManager.shared.table(for: id)
            } else {
                InputStyleManager.shared.table(for: .defaultRomanToKana)
            }
            let roman = lastRuby.suffix(while: {String($0).onlyRomanAlphabet})
            if !roman.isEmpty {
                let ruby: Substring = lastRuby.dropLast(roman.count)
                if ruby.isEmpty {
                    dicdata = []
                    break
                }
                let possibleNexts: [Substring] = table.possibleNexts[String(roman), default: []].map {ruby + $0}
                debug(#function, lastRuby, ruby, roman, possibleNexts, prepart, lastRubyCount)
                dicdata = possibleNexts.flatMap { self.dicdataStore.getPredictionLOUDSDicdata(key: $0, state: dicdataStoreState, includeExactMatch: true) }
            } else {
                debug(#function, lastRuby, "roman == \"\"")
                dicdata = self.dicdataStore.getPredictionLOUDSDicdata(key: lastRuby, state: dicdataStoreState)
            }
        }

        var result: [Candidate] = []

        result.reserveCapacity(N_best &+ 1)
        let ccLatter = self.dicdataStore.getCCLatter(lastRcid)
        for data in (dicdata + osuserdict) {
            let includeMMValueCalculation = DicdataStore.includeMMValueCalculation(data)
            let mmValue: PValue = includeMMValueCalculation ? self.dicdataStore.getMMValue(lastMid, data.mid) : .zero
            let ccValue: PValue = ccLatter.get(data.lcid)
            let penalty: PValue = -PValue(data.ruby.count &- lastRuby.count) * 1.0   // 文字数差をペナルティとする
            let wValue: PValue = data.value()
            let newValue: PValue = lastCandidate.value + mmValue + ccValue + wValue + penalty - ignoreCCValue
            // 追加すべきindexを取得する
            let lastindex: Int = (result.lastIndex(where: {$0.value >= newValue}) ?? -1) + 1
            if lastindex >= N_best {
                continue
            }
            var nodedata: [DicdataElement] = datas
            nodedata.append(data)
            let candidate: Candidate = Candidate(
                text: lastCandidate.text + data.word,
                value: newValue,
                composingCount: composingCount,
                lastMid: includeMMValueCalculation ? data.mid : lastMid,
                data: nodedata
            )
            // カウントがオーバーしそうな場合は除去する
            if result.count >= N_best {
                result.removeLast()
            }
            // removeしてからinsertした方が速い (insertはO(N)なので)
            result.insert(candidate, at: lastindex)
        }

        return result
    }
}
