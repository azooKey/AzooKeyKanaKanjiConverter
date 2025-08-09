import Algorithms
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
    func kana2lattice_all_with_prefix_constraint(_ inputData: ComposingText, N_best: Int, constraint: PrefixConstraint, state: DicdataStoreState? = nil) -> (result: LatticeNode, lattice: Lattice) {
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)。制約は\(constraint)")
        let result: LatticeNode = LatticeNode.EOSNode
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let rawNodes = latticeIndices.map { index in
            let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex {
                (iIndex, nil)
            } else {
                nil
            }
            let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex {
                (sIndex, nil)
            } else {
                nil
            }
            return dicdataStore.lookupDicdata(
                composingText: inputData,
                inputRange: inputRange,
                surfaceRange: surfaceRange,
                needTypoCorrection: false,
                state: state
            )
        }
        let lattice: Lattice = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: rawNodes
        )
        // 「i文字目から始まるnodes」に対して
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                // 生起確率を取得する。
                let wValue: PValue = node.data.value()
                if isHead {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                // 変換した文字数
                let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                // 文字数がcountと等しい場合登録する
                if nextIndex.surfaceIndex == surfaceCount {
                    for index in node.prevs.indices {
                        let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
                        // 学習データやユーザ辞書由来の場合は素通しする
                        if node.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                            let utf8Text = newnode.getCandidateData().data.reduce(into: []) { $0.append(contentsOf: $1.word.utf8)} + node.data.word.utf8
                            // 最終チェック
                            let condition = (!constraint.hasEOS && utf8Text.hasPrefix(constraint.constraint)) || (constraint.hasEOS && utf8Text == constraint.constraint)
                            guard condition else {
                                continue
                            }
                        }
                        result.prevs.append(newnode)
                    }
                } else {
                    let candidates: [[String.UTF8View.Element]] = node.getCandidateData().map {
                        Array(($0.data.reduce(into: "") { $0.append(contentsOf: $1.word)} + node.data.word).utf8)
                    }
                    // nodeの繋がる次にあり得る全てのnextnodeに対して
                    for nextnode in lattice[index: nextIndex] {
                        // クラスの連続確率を計算する。
                        let ccValue: PValue = self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
                        // nodeの持っている全てのprevnodeに対して
                        for (index, value) in node.values.enumerated() {
                            // 制約を少なくとも満たしている必要がある
                            // common prefixが単語か制約のどちらかに一致している必要
                            // 制約 AB 単語 ABC (OK)
                            // 制約 AB 単語 A   (OK)
                            // 制約 AB 単語 AC  (NG)
                            // ただし、学習データやユーザ辞書由来の場合は素通しする
                            if nextnode.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                                let utf8Text = candidates[index] + nextnode.data.word.utf8
                                let condition = (!constraint.hasEOS && (utf8Text.hasPrefix(constraint.constraint) || constraint.constraint.hasPrefix(utf8Text))) || (constraint.hasEOS && utf8Text.count < constraint.constraint.count && constraint.constraint.hasPrefix(utf8Text))
                                guard condition else {
                                    continue
                                }
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
        return (result: result, lattice: lattice)
    }

}
