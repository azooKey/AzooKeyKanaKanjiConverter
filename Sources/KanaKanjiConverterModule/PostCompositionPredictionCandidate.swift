//
//  PostCompositionPredictionCandidate.swift
//
//
//  Created by miwa on 2023/09/19.
//

import Foundation

/// 確定後予測変換候補を表す型
public struct PostCompositionPredictionCandidate: Sendable {
    public init(text: String, value: PValue, type: PostCompositionPredictionCandidate.PredictionType) {
        self.text = text
        self.value = value
        self.type = type
        if Set(["。", ".", "．"]).contains(text) {
            self.isTerminal = true
        } else {
            self.isTerminal = false
        }
    }

    public var text: String
    public var value: PValue
    public var type: PredictionType

    /// 確定後予測変換を終了すべきか否か。句点では終了する。
    public var isTerminal: Bool

    public func join(to candidate: Candidate) -> Candidate {
        var candidate = candidate
        switch self.type {
        case .additional(let data):
            for data in data {
                candidate.text.append(contentsOf: data.word)
                candidate.data.append(data)
            }
            candidate.value = self.value
            candidate.correspondingCount = candidate.data.reduce(into: 0) { $0 += $1.ruby.count }
            candidate.lastMid = data.last(where: DicdataStore.includeMMValueCalculation)?.mid ?? candidate.lastMid
            return candidate
        case .replacement(let targetData, let replacementData):
            candidate.data.removeLast(targetData.count)
            candidate.data.append(contentsOf: replacementData)
            candidate.text = candidate.data.reduce(into: "") {$0 += $1.word}
            candidate.value = self.value
            candidate.lastMid = candidate.data.last(where: DicdataStore.includeMMValueCalculation)?.mid ?? MIDData.BOS.mid
            candidate.correspondingCount = candidate.data.reduce(into: 0) { $0 += $1.ruby.count }
            return candidate
        }
    }

    public enum PredictionType: Sendable, Hashable {
        case additional(data: [DicdataElement])
        case replacement(targetData: [DicdataElement], replacementData: [DicdataElement])
    }

    var lastData: DicdataElement? {
        switch self.type {
        case .additional(let data):
            return data.last
        case .replacement(_, let replacementData):
            return replacementData.last
        }
    }
}
