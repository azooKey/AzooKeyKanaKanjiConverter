//
//  mid_composition_prediction.swift
//  AzooKeyKanaKanjiConverter
//
//  Created by ensan on 2020/12/09.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import SwiftUtils

// 変換中の予測変換に関する実装
extension Kana2Kanji {
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
    func getPredictionCandidates(
        composingText: ComposingText,
        prepart: CandidateData,
        lastClause: ClauseDataUnit,
        N_best: Int,
        dicdataStoreState: DicdataStoreState,
        zenzNextTokenTopK: [ZenzContext.CandidateEvaluationResult.NextTokenPrediction]? = nil,
        lookupRubyOverride: String? = nil,
        baseCandidateOverride: Candidate? = nil
    ) -> [Candidate] {
        debug(#function, composingText, lastClause.ranges, lastClause.text)
        let debugPredictionNeedles = [
            "ぶっ飛ばされるる",
            "ぶっ飛ばされるぅ",
            "ぶっ飛ばされルの"
        ]
        let inputRuby = lastClause.ranges.reduce(into: "") {
            let ruby = switch $1 {
            case let .input(left, right):
                ComposingText.getConvertTarget(for: composingText.input[left..<right]).toKatakana()
            case let .surface(left, right):
                String(composingText.convertTarget.dropFirst(left).prefix(right - left)).toKatakana()
            }
            $0.append(ruby)
        }
        let inputRubyCount = inputRuby.count
        let lookupRuby = (lookupRubyOverride?.toKatakana() ?? inputRuby)
        let lookupRubyCount = lookupRuby.count

        let osuserdict: [DicdataElement] = dicdataStore.getPrefixMatchDynamicUserDict(lookupRuby, state: dicdataStoreState)

        let lastCandidate: Candidate
        let datas: [DicdataElement]
        let composingCount: ComposingCount
        let ignoreCCValue: PValue
        if let baseCandidateOverride {
            lastCandidate = baseCandidateOverride
            datas = baseCandidateOverride.data
            composingCount = baseCandidateOverride.composingCount
            ignoreCCValue = .zero
        } else {
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
            lastCandidate = prepart.isEmpty ? Candidate(text: "", value: .zero, composingCount: .inputCount(0), lastMid: MIDData.EOS.mid, data: []) : self.processClauseCandidate(prepart)
            composingCount = .composite(lastCandidate.composingCount, .surfaceCount(inputRubyCount))
            let nextLcid = prepart.lastClause?.nextLcid ?? CIDData.BOS.cid
            ignoreCCValue = self.dicdataStore.getCCValue(lastCandidate.data.last?.rcid ?? CIDData.BOS.cid, nextLcid)
        }
        let lastRcid: Int = lastCandidate.data.last?.rcid ?? CIDData.BOS.cid
        let lastMid: Int = lastCandidate.lastMid

        let inputStyle = composingText.input.last?.inputStyle ?? .direct
        let dicdata: [DicdataElement]
        switch inputStyle {
        case .direct:
            dicdata = self.dicdataStore.getPredictionLOUDSDicdata(key: lookupRuby, state: dicdataStoreState)
        case .roman2kana, .mapped:
            let table = if case let .mapped(id) = inputStyle {
                InputStyleManager.shared.table(for: id)
            } else {
                InputStyleManager.shared.table(for: .defaultRomanToKana)
            }
            let roman = lookupRuby.suffix(while: {String($0).onlyRomanAlphabet})
            if !roman.isEmpty {
                let ruby: Substring = lookupRuby.dropLast(roman.count)
                if ruby.isEmpty {
                    dicdata = []
                    break
                }
                let possibleNexts: [Substring] = table.possibleNexts[String(roman), default: []].map {ruby + $0}
                debug(#function, lookupRuby, ruby, roman, possibleNexts, prepart, lookupRubyCount)
                dicdata = possibleNexts.flatMap { self.dicdataStore.getPredictionLOUDSDicdata(key: $0, state: dicdataStoreState) }
            } else {
                debug(#function, lookupRuby, "roman == \"\"")
                dicdata = self.dicdataStore.getPredictionLOUDSDicdata(key: lookupRuby, state: dicdataStoreState)
            }
        }

        var result: [Candidate] = []

        result.reserveCapacity(N_best &+ 1)
        let ccLatter = self.dicdataStore.getCCLatter(lastRcid)
        for data in (dicdata + osuserdict) {
            let includeMMValueCalculation = DicdataStore.includeMMValueCalculation(data)
            let mmValue: PValue = includeMMValueCalculation ? self.dicdataStore.getMMValue(lastMid, data.mid) : .zero
            let ccValue: PValue = ccLatter.get(data.lcid)
            let penalty: PValue = -PValue(data.ruby.count &- lookupRubyCount) * 1.0   // 文字数差をペナルティとする
            let wValue: PValue = data.value()
            let zenzBonus: PValue = {
                guard let zenzNextTokenTopK else { return .zero }
                // 先頭1トークン一致で加点（カタカナ正規化）
                let normRuby = data.ruby.toKatakana()
                // 入力済みの ruby を除いた「次文字候補位置」の1文字目と比較する
                let remaining = String(normRuby.dropFirst(inputRubyCount))
                let match = zenzNextTokenTopK.first(where: { tok in
                    guard let c = remaining.first else { return false }
                    return String(c).hasPrefix(tok.token.toKatakana().prefix(1))
                })
                guard let match else {
                    return .zero
                }
                let bonus = PValue(match.probabilityRatio) * 6
                return bonus
            }()
            let newValue: PValue = lastCandidate.value + mmValue + ccValue + wValue + penalty + zenzBonus - ignoreCCValue
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
            if debugPredictionNeedles.contains(where: { candidate.text.contains($0) }) {
                let isDynamicUserDict = osuserdict.contains(where: { $0 == data })
                let source = if isDynamicUserDict {
                    "dynamic_user_dict"
                } else if data.metadata.contains(.isLearned) {
                    "learned"
                } else if data.metadata.contains(.isFromUserDictionary) {
                    "user_dict"
                } else {
                    "system_dict"
                }
                debug(
                    "prediction candidate detail",
                    "source:", source,
                    "lookupRuby:", lookupRuby,
                    "inputRuby:", inputRuby,
                    "lastClause:", lastClause.text,
                    "lastCandidate:", lastCandidate.text,
                    "data:", data.debugDescription,
                    "candidate:", candidate.text
                )
            }
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
