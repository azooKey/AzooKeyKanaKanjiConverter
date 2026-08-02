import Foundation

/// N-bestの複数経路で共通する辞書データと入力範囲を1回だけ保持する。
final class RegisteredNodePayload {
    init(data: consuming DicdataElement, range: Lattice.LatticeRange) {
        self.data = data
        self.range = range
    }

    let data: DicdataElement
    let range: Lattice.LatticeRange
}

/// `indirect enum`を用いて再帰的なノード構造を実現する。
/// 辞書データと入力範囲は、同じLatticeNodeから派生したN-best経路間で共有する。
indirect enum RegisteredNode {
    case node(
        payload: RegisteredNodePayload,
        prev: RegisteredNode?,
        totalValue: PValue,
        candidateUTF8Count: UInt16,
        constraintMatchedUTF8Count: UInt16
    )

    /// このノードが保持する辞書データ
    var data: DicdataElement {
        _read {
            switch self {
            case .node(let payload, _, _, _, _):
                yield payload.data
            }
        }
    }

    /// 1つ前のノードのデータ
    var prev: RegisteredNode? {
        _read {
            switch self {
            case .node(_, let prev, _, _, _):
                yield prev
            }
        }
    }

    /// 始点からこのノードまでのコスト
    var totalValue: PValue {
        switch self {
        case .node(_, _, let totalValue, _, _):
            return totalValue
        }
    }

    var candidateUTF8Count: UInt16 {
        switch self {
        case .node(_, _, _, let candidateUTF8Count, _):
            return candidateUTF8Count
        }
    }

    var constraintMatchedUTF8Count: UInt16 {
        switch self {
        case .node(_, _, _, _, let constraintMatchedUTF8Count):
            return constraintMatchedUTF8Count
        }
    }

    /// `composingText`の`input`で対応する範囲
    var range: Lattice.LatticeRange {
        switch self {
        case .node(let payload, _, _, _, _):
            return payload.range
        }
    }

    init(data: DicdataElement, registered: RegisteredNode?, totalValue: PValue, range: Lattice.LatticeRange) {
        let candidateUTF8Count = (registered.map { Int($0.candidateUTF8Count) } ?? 0) + data.word.utf8.count
        self = .node(
            payload: RegisteredNodePayload(data: data, range: range),
            prev: registered,
            totalValue: totalValue,
            candidateUTF8Count: UInt16(clamping: candidateUTF8Count),
            constraintMatchedUTF8Count: 0
        )
    }

    init(
        payload: RegisteredNodePayload,
        registered: RegisteredNode?,
        totalValue: PValue,
        constraintState: (matched: Int, total: Int)? = nil
    ) {
        let candidateUTF8Count = constraintState?.total
            ?? ((registered.map { Int($0.candidateUTF8Count) } ?? 0) + payload.data.word.utf8.count)
        self = .node(
            payload: payload,
            prev: registered,
            totalValue: totalValue,
            candidateUTF8Count: UInt16(clamping: candidateUTF8Count),
            constraintMatchedUTF8Count: UInt16(clamping: constraintState?.matched ?? 0)
        )
    }

    /// 始点ノードを生成する関数
    /// - Returns: 始点ノードのデータ
    static func BOSNode() -> RegisteredNode {
        RegisteredNode(data: DicdataElement.BOSData, registered: nil, totalValue: 0, range: .zero)
    }

    /// 入力中、確定した部分を考慮した始点ノードを生成する関数
    /// - Returns: 始点ノードのデータ
    static func fromLastCandidate(_ candidate: Candidate) -> RegisteredNode {
        RegisteredNode(
            data: DicdataElement(word: "", ruby: "", lcid: CIDData.BOS.cid, rcid: candidate.data.last?.rcid ?? CIDData.BOS.cid, mid: candidate.lastMid, value: 0),
            registered: nil,
            totalValue: 0,
            range: .zero
        )
    }
}

extension RegisteredNode {
    /// 再帰的にノードを遡り、`CandidateData`を構築する関数
    /// - Returns: 文節単位の区切り情報を持った変換候補データ
    func getCandidateData() -> CandidateData {
        // 再帰を避けて、prevを起点まで辿ってから前方向に一度だけ処理する
        // 1) チェーンを収集（BOSまで）しつつ、非空ワード数を数える
        var chain: [RegisteredNode] = []
        chain.reserveCapacity(8)
        var nonEmptyCount = 0
        var cursor: RegisteredNode? = self
        while let node = cursor {
            chain.append(node)
            if !node.data.word.isEmpty { nonEmptyCount += 1 }
            cursor = node.prev
        }
        // 逆順にして起点->現在の順番にする
        chain.reverse()

        // 3) ローカル配列で構築して最後にCandidateDataへ格納
        let head = chain[0]
        var clauses: [(clause: ClauseDataUnit, value: PValue)] = []
        clauses.reserveCapacity(nonEmptyCount + 1)
        var data: [DicdataElement] = []
        data.reserveCapacity(nonEmptyCount)
        var unit = ClauseDataUnit()
        unit.mid = head.data.mid
        unit.ranges = [head.range]
        clauses.append((clause: unit, value: .zero))
        var lastClause = unit
        var lastClauseIndex = 0

        // 4) 前方向に一度だけ処理
        for i in 1 ..< chain.count {
            let node = chain[i]
            // もとの実装と同じく、空語はスキップ
            if node.data.word.isEmpty {
                continue
            }

            let prevNode = chain[i - 1]
            if lastClause.text.isEmpty || !DicdataStore.isClause(prevNode.data.rcid, node.data.lcid) {
                // 文節継続（structなので配列へ書き戻す）
                lastClause.text.append(node.data.word)
                lastClause.ranges.append(node.range)
                if (lastClause.mid == 500 && node.data.mid != 500) || DicdataStore.includeMMValueCalculation(node.data) {
                    lastClause.mid = node.data.mid
                }
                data.append(node.data)
                lastClause.dataEndIndex = data.count - 1
                clauses[lastClauseIndex].clause = lastClause
                clauses[lastClauseIndex].value = node.totalValue
            } else {
                // 文節境界
                var newUnit = ClauseDataUnit()
                newUnit.text = node.data.word
                newUnit.ranges.append(node.range)
                if DicdataStore.includeMMValueCalculation(node.data) {
                    newUnit.mid = node.data.mid
                }
                lastClause.nextLcid = node.data.lcid
                clauses[lastClauseIndex].clause = lastClause
                data.append(node.data)
                newUnit.dataEndIndex = data.count - 1
                clauses.append((clause: newUnit, value: node.totalValue))
                lastClause = newUnit
                lastClauseIndex = clauses.count - 1
            }
        }
        return CandidateData(clauses: clauses, data: data)
    }
}
