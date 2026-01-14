//
//  Candidate.swift
//  Keyboard
//
//  Created by ensan on 2020/10/26.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation

/// Data of clause.
struct ClauseDataUnit {
    /// The MID of the clause.
    var mid: Int = MIDData.EOS.mid
    /// The LCID in the next clause.
    var nextLcid = CIDData.EOS.cid
    /// The text of the unit.
    var text: String = ""
    /// The range of the unit in input text.
    var ranges: [Lattice.LatticeRange] = []
    /// The last index (inclusive) into CandidateData.data that composes this clause.
    /// - Note: -1 means unset (no words have been appended yet).
    var dataEndIndex: Int = -1

    /// Merge the given unit to this unit.
    /// - Parameter:
    ///   - unit: The unit to merge.
    mutating func merge(with unit: ClauseDataUnit) {
        self.text.append(unit.text)
        self.ranges.append(contentsOf: unit.ranges)
        self.nextLcid = unit.nextLcid
    }
}

extension ClauseDataUnit: Equatable, Sendable {
    static func == (lhs: ClauseDataUnit, rhs: ClauseDataUnit) -> Bool {
        lhs.mid == rhs.mid && lhs.nextLcid == rhs.nextLcid && lhs.text == rhs.text && lhs.ranges == rhs.ranges
    }
}

#if DEBUG
extension ClauseDataUnit: CustomDebugStringConvertible {
    var debugDescription: String {
        "ClauseDataUnit(mid: \(mid), nextLcid: \(nextLcid), text: \(text), ranges: \(ranges))"
    }
}
#endif

struct CandidateData: Sendable {
    typealias ClausesUnit = (clause: ClauseDataUnit, value: PValue)
    var clauses: [ClausesUnit]
    var data: [DicdataElement]

    init(clauses: [ClausesUnit], data: [DicdataElement]) {
        self.clauses = clauses
        self.data = data
    }

    var lastClause: ClauseDataUnit? {
        self.clauses.last?.clause
    }

    var isEmpty: Bool {
        clauses.isEmpty
    }
}

public enum CompleteAction: Equatable, Sendable {
    /// カーソルを調整する
    case moveCursor(Int)
}

public enum ComposingCount: Sendable, Equatable {
    /// composingText.inputにおいて対応する文字数。
    case inputCount(Int)
    /// composingText.convertTargeにおいて対応する文字数。
    case surfaceCount(Int)

    /// 複数のカウントの連結
    indirect case composite(lhs: Self, rhs: Self)

    static func composite(_ lhs: Self, _ rhs: Self) -> Self {
        switch (lhs, rhs) {
        case (.inputCount(let l), .inputCount(let r)):
            .inputCount(l + r)
        case (.surfaceCount(let l), .surfaceCount(let r)):
            .surfaceCount(l + r)
        default:
            .composite(lhs: lhs, rhs: rhs)
        }
    }

    private struct FlatComposingCount: Equatable {
        enum Kind {
            case inputCount
            case surfaceCount
        }
        var kind: Kind
        var value: Int
        static func inputCount(_ value: Int) -> Self {
            .init(kind: .inputCount, value: value)
        }
        static func surfaceCount(_ value: Int) -> Self {
            .init(kind: .surfaceCount, value: value)
        }
    }

    private var flatten: [FlatComposingCount] {
        switch self {
        case .inputCount(let value):
            if value == 0 {
                []
            } else {
                [.inputCount(value)]
            }
        case .surfaceCount(let value):
            if value == 0 {
                []
            } else {
                [.surfaceCount(value)]
            }
        case .composite(let lhs, let rhs):
            {
                let lFlatten = lhs.flatten
                let rFlatten = rhs.flatten
                return switch (lFlatten.last?.kind, rFlatten.first?.kind) {
                case (.inputCount, .inputCount):
                    lFlatten.dropLast() + [.inputCount(lFlatten.last!.value + rFlatten.first!.value)] + rFlatten.dropFirst()
                case (.surfaceCount, .surfaceCount):
                    lFlatten.dropLast() + [.surfaceCount(lFlatten.last!.value + rFlatten.first!.value)] + rFlatten.dropFirst()
                default:
                    lFlatten + rFlatten
                }
            }()
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.flatten == rhs.flatten
    }
}

/// 変換候補のデータ
public struct Candidate: Sendable {
    /// 入力となるテキスト
    public var text: String
    /// 評価値
    public var value: PValue

    public var composingCount: ComposingCount
    /// 最後のmid(予測変換に利用)
    public var lastMid: Int
    /// DicdataElement列
    public var data: [DicdataElement]
    /// 変換として選択した際に実行する`action`。
    /// - note: 括弧を入力した際にカーソルを移動するために追加した変数
    public var actions: [CompleteAction]
    /// 入力できるものか
    /// - note: 文字数表示のために追加したフラグ
    public let inputable: Bool

    /// ルビ文字数
    public let rubyCount: Int

    /// 学習対象かどうか（ユーザショートカット等は除外する）
    public var isLearningTarget: Bool

    public init(text: String, value: PValue, composingCount: ComposingCount, lastMid: Int, data: [DicdataElement], actions: [CompleteAction] = [], inputable: Bool = true, isLearningTarget: Bool = true) {
        self.text = text
        self.value = value
        self.composingCount = composingCount
        self.lastMid = lastMid
        self.data = data
        self.actions = actions
        self.inputable = inputable
        self.rubyCount = self.data.reduce(into: 0) { $0 += $1.ruby.count }
        self.isLearningTarget = isLearningTarget
    }
    /// 後から`action`を追加した形を生成する関数
    /// - parameters:
    ///  - actions: 実行する`action`
    @inlinable public mutating func withActions(_ actions: [CompleteAction]) {
        self.actions = actions
    }

    private static let dateExpression = "<date format=\".*?\" type=\".*?\" language=\".*?\" delta=\".*?\" deltaunit=\".*?\">"
    private static let randomExpression = "<random type=\".*?\" value=\".*?\">"

    /// テンプレートをパースして、変換候補のテキストを生成する。
    public static func parseTemplate(_ text: String) -> String {
        // MARK: Coarse Filtering: タグが入っていなければそもそも調べる必要なし
        guard text.contains("<") else {
            return text
        }
        // MARK: Fine Filtering: 正確にチェックする
        var newText = text
        while let range = newText.range(of: Self.dateExpression, options: .regularExpression) {
            let templateString = String(newText[range])
            let template = DateTemplateLiteral.import(from: templateString)
            let value = template.previewString()
            newText.replaceSubrange(range, with: value)
        }
        while let range = newText.range(of: Self.randomExpression, options: .regularExpression) {
            let templateString = String(newText[range])
            let template = RandomTemplateLiteral.import(from: templateString)
            let value = template.previewString()
            newText.replaceSubrange(range, with: value)
        }
        return newText
    }

    /// テンプレートをパースして、変換候補のテキストを生成し、反映する。
    @inlinable public mutating func parseTemplate() {
        // ここでCandidate.textとdata.map(\.word).join("")の整合性が壊れることに注意
        // ただし、dataの方を加工するのは望ましい挙動ではない。
        let newText = Self.parseTemplate(text)
        if self.text != newText {
            self.text = consume newText
            // テンプレートを適用する場合、学習の対象にはしない。
            self.isLearningTarget = false
        }
    }

    /// 入力を文としたとき、prefixになる文節に対応するCandidateを作る
    public static func makePrefixClauseCandidate(data: some Collection<DicdataElement>) -> Candidate {
        var text = ""
        var composingCount = 0
        var lastRcid = CIDData.BOS.cid
        var lastMid = 501
        var candidateData: [DicdataElement] = []
        for item in data {
            // 文節だったら
            if DicdataStore.isClause(lastRcid, item.lcid) {
                break
            }
            text.append(item.word)
            composingCount += item.ruby.count
            lastRcid = item.rcid
            // 最初だった場合を想定している
            if item.mid != 500 && DicdataStore.includeMMValueCalculation(item) {
                lastMid = item.mid
            }
            candidateData.append(item)
        }
        return Candidate(
            text: text,
            value: -5,
            composingCount: .surfaceCount(composingCount),
            lastMid: lastMid,
            data: candidateData
        )
    }
}
