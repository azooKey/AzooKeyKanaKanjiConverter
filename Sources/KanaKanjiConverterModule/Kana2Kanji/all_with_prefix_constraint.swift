import Foundation
import SwiftUtils

extension Kana2Kanji {
    /// カナを漢字に変換する関数, 前提はなくかな列が与えられた場合。
    /// - Parameters:
    ///   - inputData: 入力データ。
    ///   - N_best: N_best。
    /// - Returns:
    ///   変換候補。
    /// ### 実装状況
    /// (0)多用する変数の宣言。
    ///
    /// (1)まず、追加された一文字に繋がるノードを列挙する。
    ///
    /// (2)次に、計算済みノードから、(1)で求めたノードにつながるようにregisterして、N_bestを求めていく。
    ///
    /// (3)(1)のregisterされた結果をresultノードに追加していく。この際EOSとの連接計算を行っておく。
    ///
    /// (4)ノードをアップデートした上で返却する。
    func kana2lattice_all_with_prefix_constraint(_ inputData: ComposingText, N_best: Int, constraint: PrefixConstraint) -> (result: LatticeNode, nodes: Nodes) {
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)。制約は\(constraint)")
        let count: Int = inputData.input.count
        let result: LatticeNode = LatticeNode.EOSNode
        let utf16Constraint = Array(constraint.constraint.utf16)
        let nodes: [[LatticeNode]] = (.zero ..< count).map {dicdataStore.getFrozenLOUDSDataInRange(inputData: inputData, from: $0)}
        // 「i文字目から始まるnodes」に対して
        for (i, nodeArray) in nodes.enumerated() {
            // それぞれのnodeに対して
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if self.dicdataStore.shouldBeRemoved(data: node.data) {
                    continue
                }
                // 生起確率を取得する。
                let wValue: PValue = node.data.value()
                if i == 0 {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                // 変換した文字数
                let nextIndex: Int = node.inputRange.endIndex
                // 文字数がcountと等しい場合登録する
                if nextIndex == count {
                    for index in node.prevs.indices {
                        let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
                        let text = newnode.getCandidateData().data.reduce(into: "") { $0.append(contentsOf: $1.word)} + node.data.word
                        let condition = (!constraint.hasEOS && text.utf16.hasPrefix(utf16Constraint)) || (constraint.hasEOS && text == constraint.constraint)
                        if condition {
                            result.prevs.append(newnode)
                        }
                    }
                } else {
                    let candidates: [[String.UTF16View.Element]] = node.getCandidateData().map {
                        Array(($0.data.reduce(into: "") { $0.append(contentsOf: $1.word)} + node.data.word).utf16)
                    }
                    // nodeの繋がる次にあり得る全てのnextnodeに対して
                    for nextnode in nodes[nextIndex] {
                        // この関数はこの時点で呼び出して、後のnode.registered.isEmptyで最終的に弾くのが良い。
                        if self.dicdataStore.shouldBeRemoved(data: nextnode.data) {
                            continue
                        }
                        // クラスの連続確率を計算する。
                        let ccValue: PValue = self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
                        // nodeの持っている全てのprevnodeに対して
                        for (index, value) in node.values.enumerated() {
                            // 制約を少なくとも満たしている必要がある
                            // common prefixが単語か制約のどちらかに一致している必要
                            // 制約 AB 単語 ABC (OK)
                            // 制約 AB 単語 A   (OK)
                            // 制約 AB 単語 AC  (NG)
                            let text = candidates[index] + nextnode.data.word.utf16
                            let condition = (!constraint.hasEOS && (text.hasPrefix(utf16Constraint) || utf16Constraint.hasPrefix(text))) || (constraint.hasEOS && text.count < utf16Constraint.count && utf16Constraint.hasPrefix(text))
                            guard condition else {
                                continue
                            }
                            let newValue: PValue = ccValue + value
                            // 追加すべきindexを取得する
                            let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                            if lastindex == N_best {
                                continue
                            }
                            let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                            // カウントがオーバーしている場合は除去する
                            if nextnode.prevs.count >= N_best {
                                nextnode.prevs.removeLast()
                            }
                            // removeしてからinsertした方が速い (insertはO(N)なので)
                            nextnode.prevs.insert(newnode, at: lastindex)
                        }
                    }
                }
            }
        }
        return (result: result, nodes: nodes)
    }

}
