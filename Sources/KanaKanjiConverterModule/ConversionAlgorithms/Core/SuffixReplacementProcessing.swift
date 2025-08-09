//
//  changed_last_n_character.swift
//  Keyboard
//
//  Created by ensan on 2020/10/14.
//  Copyright © 2020 ensan. All rights reserved.
//

import Algorithms
import Foundation
import SwiftUtils

extension Kana2Kanji {
    /// カナを漢字に変換する関数, 最後の一文字が変わった場合。
    /// ### 実装状況
    /// (0)多用する変数の宣言。
    ///
    /// (1)まず、変更前の一文字につながるノードを全て削除する。
    ///
    /// (2)次に、変更後の一文字につながるノードを全て列挙する。
    ///
    /// (3)(1)を解析して(2)にregisterしていく。
    ///
    /// (4)registerされた結果をresultノードに追加していく。
    ///
    /// (5)ノードをアップデートした上で返却する。

    func kana2lattice_changed(
        _ inputData: ComposingText,
        N_best: Int,
        counts: (deletedInput: Int, addedInput: Int, deletedSurface: Int, addedSurface: Int),
        previousResult: (inputData: ComposingText, lattice: Lattice),
        needTypoCorrection: Bool,
        state: DicdataStoreState? = nil
    ) -> (result: LatticeNode, lattice: Lattice) {
        // (0)
        let inputCount = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let commonInputCount = previousResult.inputData.input.count - counts.deletedInput
        let commonSurfaceCount = previousResult.inputData.convertTarget.count - counts.deletedSurface
        debug("kana2lattice_changed", inputData, counts, previousResult.inputData, inputCount, commonInputCount)

        // (1)
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        var lattice = previousResult.lattice.prefix(inputCount: commonInputCount, surfaceCount: commonSurfaceCount)

        var terminalNodes = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: lattice.map {
                $0.filter {
                    $0.range.endIndex == .input(inputCount) || $0.range.endIndex == .surface(surfaceCount)
                }
            }
        )
        if !(counts.addedInput == 0 && counts.addedSurface == 0) {
            // (2)
            let rawNodes = latticeIndices.map { index in
                let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex, max(commonInputCount, iIndex) < inputCount {
                    (iIndex, max(commonInputCount, iIndex) ..< inputCount)
                } else {
                    nil
                }
                let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex, max(commonSurfaceCount, sIndex) < surfaceCount {
                    (sIndex, max(commonSurfaceCount, sIndex) ..< surfaceCount)
                } else {
                    nil
                }
                return self.dicdataStore.lookupDicdata(
                    composingText: inputData,
                    inputRange: inputRange,
                    surfaceRange: surfaceRange,
                    needTypoCorrection: needTypoCorrection,
                    state: state
                )
            }
            let addedNodes: Lattice = Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
            // (3)
            for nodeArray in lattice {
                for node in nodeArray {
                    if node.prevs.isEmpty {
                        continue
                    }
                    if self.dicdataStore.shouldBeRemoved(data: node.data) {
                        continue
                    }
                    // 変換した文字数
                    let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                    if nextIndex.surfaceIndex != surfaceCount {
                        self.updateNextNodes(with: node, nextNodes: addedNodes[index: nextIndex], nBest: N_best)
                    }
                }
            }
            lattice.merge(addedNodes)
            terminalNodes.merge(addedNodes)
        }

        // (3)
        // terminalNodesの各要素を結果ノードに接続する
        let result = LatticeNode.EOSNode

        for (i, nodes) in terminalNodes.enumerated() {
            for node in nodes {
                if node.prevs.isEmpty {
                    continue
                }
                // この関数はこの時点で呼び出して、後のnode.registered.isEmptyで最終的に弾くのが良い。
                if self.dicdataStore.shouldBeRemoved(data: node.data) {
                    continue
                }
                // 生起確率を取得する。
                let wValue = node.data.value()
                if i == 0 {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                if nextIndex.surfaceIndex == surfaceCount {
                    self.updateResultNode(with: node, resultNode: result)
                } else {
                    self.updateNextNodes(with: node, nextNodes: terminalNodes[index: nextIndex], nBest: N_best)
                }
            }
        }
        return (result: result, lattice: lattice)
    }

}
