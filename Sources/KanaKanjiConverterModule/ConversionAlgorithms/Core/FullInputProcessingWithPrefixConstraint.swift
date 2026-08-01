import Algorithms
import Foundation
import SwiftUtils

extension Kana2Kanji {
    // Compute matched bytes with constraint and total candidate bytes for (prev-chain + currentWord)
    private func computeMatchedAndTotalLength(
        prev: borrowing RegisteredNode?,
        currentWord: borrowing String,
        constraintBytes: borrowing [UInt8]
    ) -> (matched: Int, total: Int) {
        let previousTotal = prev.map { Int($0.candidateUTF8Count) } ?? 0
        var matched = prev.map { Int($0.constraintMatchedUTF8Count) } ?? 0
        let total = previousTotal + currentWord.utf8.count

        // 直前までに不一致がなければ、今回追加する単語だけを照合する。
        // RegisteredNode生成時に累積値を保持するため、経路全体の再走査は不要。
        guard matched == min(previousTotal, constraintBytes.count) else {
            return (matched, total)
        }
        for byte in currentWord.utf8 {
            guard matched < constraintBytes.count, byte == constraintBytes[matched] else {
                break
            }
            matched += 1
        }
        return (matched, total)
    }

    // Extend match with next word starting from current matched index
    private func extendMatched(
        matched: Int,
        nextWord: borrowing String,
        constraintBytes: borrowing [UInt8]
    ) -> (matched: Int, mismatch: Bool) {
        var ci = matched
        if ci >= constraintBytes.count {
            return (ci, false)
        }
        for b in nextWord.utf8 {
            if ci >= constraintBytes.count {
                return (ci, false)
            }
            if b != constraintBytes[ci] {
                return (ci, true)
            }
            ci += 1
        }
        return (ci, false)
    }

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
    func kana2lattice_all_with_prefix_constraint(
        _ inputData: ComposingText,
        N_best: Int,
        constraint: PrefixConstraint,
        preprocessedLattice: Lattice? = nil,
        dicdataStoreState: DicdataStoreState
    ) -> (result: LatticeNode, lattice: Lattice) {
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)。制約は\(constraint)")
        let result: LatticeNode = LatticeNode.EOSNode
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let lattice: Lattice
        if let preprocessedLattice {
            lattice = preprocessedLattice
        } else {
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
                    state: dicdataStoreState
                )
            }
            lattice = Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }
        let constraintBytes = constraint.constraint
        let constraintLength = constraintBytes.count
        let enforcesConstraintOnStaticDictionary = !constraint.ignoreMemoryAndUserDictionary
        // 「i文字目から始まるnodes」に対して
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if N_best == 1, let previous = node.prevs.first {
                    let wValue = node.data.value()
                    let value = previous.totalValue + wValue + (
                        isHead
                            ? self.dicdataStore.getCCValue(previous.data.rcid, node.data.lcid)
                            : 0
                    )
                    let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                    let matchState = self.computeMatchedAndTotalLength(
                        prev: previous,
                        currentWord: node.data.word,
                        constraintBytes: constraintBytes
                    )
                    if nextIndex.surfaceIndex == surfaceCount {
                        if enforcesConstraintOnStaticDictionary,
                           node.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                            let condition = if constraint.hasEOS {
                                matchState.matched == constraintLength
                                    && matchState.total == constraintLength
                            } else {
                                matchState.matched == constraintLength
                            }
                            guard condition else {
                                continue
                            }
                        }
                        let newNode = node.getRegisteredNode(
                            0,
                            value: value,
                            constraintState: matchState
                        )
                        if let current = result.prevs.first {
                            if newNode.totalValue > current.totalValue {
                                result.prevs[0] = newNode
                            }
                        } else {
                            result.prevs.append(newNode)
                        }
                        continue
                    }

                    let ccLatter = self.dicdataStore.getCCLatter(node.data.rcid)
                    for nextNode in lattice[index: nextIndex] {
                        let newValue = value + ccLatter.get(nextNode.data.lcid)
                        if let current = nextNode.prevs.first,
                           current.totalValue >= newValue {
                            continue
                        }
                        if enforcesConstraintOnStaticDictionary,
                           nextNode.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                            guard matchState.matched
                                == min(matchState.total, constraintLength) else {
                                continue
                            }
                            let nextLength = nextNode.data.word.utf8.count
                            let (matched, mismatch) = self.extendMatched(
                                matched: matchState.matched,
                                nextWord: nextNode.data.word,
                                constraintBytes: constraintBytes
                            )
                            if mismatch {
                                continue
                            }
                            let newTotal = matchState.total + nextLength
                            let isCompatible = if constraint.hasEOS {
                                matched == newTotal && newTotal < constraintLength
                            } else {
                                matched == constraintLength
                                    || (newTotal <= constraintLength && matched == newTotal)
                            }
                            guard isCompatible else {
                                continue
                            }
                        }
                        let newNode = node.getRegisteredNode(
                            0,
                            value: newValue,
                            constraintState: matchState
                        )
                        if nextNode.prevs.isEmpty {
                            nextNode.prevs.append(newNode)
                        } else {
                            nextNode.prevs[0] = newNode
                        }
                    }
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
                    // Precompute matched/total lengths per prev for (prev + current word)
                    let mtPerPrev: [(matched: Int, total: Int)] = node.prevs.indices.map { idx in
                        self.computeMatchedAndTotalLength(prev: node.prevs[idx], currentWord: node.data.word, constraintBytes: constraintBytes)
                    }
                    for index in node.prevs.indices {
                        // 学習データやユーザ辞書由来の場合は素通しする
                        if enforcesConstraintOnStaticDictionary,
                           node.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                            let (matched, total) = mtPerPrev[index]
                            // 最終チェック（EOS時の条件に合わせる）
                            let condition = if constraint.hasEOS {
                                matched == constraintLength && total == constraintLength
                            } else {
                                matched == constraintLength
                            }
                            guard condition else {
                                continue
                            }
                        }
                        let newnode: RegisteredNode = node.getRegisteredNode(
                            index,
                            value: node.values[index],
                            constraintState: mtPerPrev[index]
                        )
                        if N_best == 1 {
                            if let current = result.prevs.first {
                                if newnode.totalValue > current.totalValue {
                                    result.prevs[0] = newnode
                                }
                            } else {
                                result.prevs.append(newnode)
                            }
                        } else {
                            result.prevs.append(newnode)
                        }
                    }
                } else {
                    // Precompute matched/total lengths per prev for (prev + current word)
                    let mtPerPrev: [(matched: Int, total: Int)] = node.prevs.indices.map { idx in
                        self.computeMatchedAndTotalLength(prev: node.prevs[idx], currentWord: node.data.word, constraintBytes: constraintBytes)
                    }
                    let ccLatter = self.dicdataStore.getCCLatter(node.data.rcid)
                    // nodeの繋がる次にあり得る全てのnextnodeに対して
                    for nextnode in lattice[index: nextIndex] {
                        // クラスの連続確率を計算する。
                        let ccValue: PValue = ccLatter.get(nextnode.data.lcid)
                        // nodeの持っている全てのprevnodeに対して
                        for (index, value) in node.values.enumerated() {
                            let newValue: PValue = ccValue + value
                            // 追加すべきindexを取得する
                            let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                            if lastindex == N_best {
                                continue
                            }
                            // 制約チェックは重いので、必要なものに対してのみ行う
                            // common prefixが単語か制約のどちらかに一致している必要
                            // 制約 AB 単語 ABC (OK)
                            // 制約 AB 単語 A   (OK)
                            // 制約 AB 単語 AC  (NG)
                            // ただし、学習データやユーザ辞書由来の場合は素通しする
                            if enforcesConstraintOnStaticDictionary,
                               nextnode.data.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary]) {
                                let (matchedPrev, totalPrev) = mtPerPrev[index]
                                // ensure no prior mismatch
                                guard matchedPrev == min(totalPrev, constraintLength) else {
                                    continue
                                }
                                let nextLen = nextnode.data.word.utf8.count
                                // matchedPrevまではconstraintBytesと一致しているので、その先をチェックする
                                let (matchedExt, mismatch) = self.extendMatched(matched: matchedPrev, nextWord: nextnode.data.word, constraintBytes: constraintBytes)
                                if mismatch {
                                    continue
                                }
                                let newTotal = totalPrev + nextLen
                                let ok: Bool = if constraint.hasEOS {
                                    // require strict prefix of constraint
                                    matchedExt == newTotal && newTotal < constraintLength
                                } else {
                                    // accept either: constraint is prefix of candidate, or candidate is prefix of constraint
                                    (matchedExt == constraintLength)
                                        || (newTotal <= constraintLength && matchedExt == newTotal)
                                }
                                guard ok else {
                                    continue
                                }
                            }
                            // カウントがオーバーしている場合は除去する
                            if nextnode.prevs.count >= N_best {
                                nextnode.prevs.removeLast()
                            }
                            let newnode: RegisteredNode = node.getRegisteredNode(
                                index,
                                value: newValue,
                                constraintState: mtPerPrev[index]
                            )
                            // removeしてからinsertした方が速い (insertはO(N)なので)
                            nextnode.prevs.insert(newnode, at: lastindex)
                        }
                    }
                }
            }
        }
        return (result: result, lattice: lattice)
    }

    /// 逐次入力の差分更新を活用してLatticeを構築
    func buildLatticeWithIncrementalCache(
        inputData: ComposingText,
        inputCount: Int,
        surfaceCount: Int,
        incrementalCacheInfo: (inputData: ComposingText, lattice: Lattice)?,
        dicdataStoreState: DicdataStoreState
    ) -> Lattice {
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        guard let incrementalCacheInfo else {
            // キャッシュがない場合は通常の辞書引き
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
                    state: dicdataStoreState
                )
            }
            return Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }

        // 差分を計算
        let oldInput = incrementalCacheInfo.inputData.input
        let newInput = inputData.input
        let oldSurface = incrementalCacheInfo.inputData.convertTarget
        let newSurface = inputData.convertTarget

        // 共通プレフィックスを計算
        let commonInputCount = zip(oldInput, newInput).prefix { $0 == $1 }.count
        let commonSurfaceCount = zip(oldSurface, newSurface).prefix { $0 == $1 }.count

        // inputの中間が変更された場合は通常の処理に戻す。
        // Roman/AZIKの逐次入力では、inputは単純なsuffix追加でも
        // convertTargetの未確定suffixが `k -> か` のように書き換わる。
        // そのケースは下で独立セグメント境界まで戻し、suffixだけ作り直す。
        if commonInputCount != oldInput.count {
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
                    state: dicdataStoreState
                )
            }
            return Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }

        // 逐次入力の場合：既存Latticeから共通部分を再利用し、新しい部分のみ辞書引き
        let cachedLattice = incrementalCacheInfo.lattice

        // surfaceの末尾書き換えがある場合、commonSurfaceCountがローマ字変換の
        // 独立セグメント内を指すことがある。その位置ではinput/surfaceの
        // 対応が一意でないため、直前の独立セグメント境界まで戻す。
        let reusableBoundary: (input: Int, surface: Int)
        if commonSurfaceCount == oldSurface.count {
            reusableBoundary = (commonInputCount, commonSurfaceCount)
        } else {
            reusableBoundary = incrementalCacheInfo.inputData
                .inputIndexToSurfaceIndexMap()
                .lazy
                .filter { $0.value <= commonSurfaceCount }
                .map { (input: $0.key, surface: $0.value) }
                .max {
                    if $0.surface == $1.surface {
                        $0.input < $1.input
                    } else {
                        $0.surface < $1.surface
                    }
                } ?? (0, 0)
        }
        let reusableInputCount = reusableBoundary.input
        let reusableSurfaceCount = reusableBoundary.surface

        // 純粋なsuffix追加では既存Latticeの全ノードがそのまま有効なので、
        // 各ノード配列のfilterと再構築を避ける。削除を伴う場合だけprefixを切り出す。
        var newLattice = if reusableInputCount == oldInput.count,
                            reusableSurfaceCount == oldSurface.count {
            cachedLattice
        } else {
            cachedLattice.prefix(
                inputCount: reusableInputCount,
                surfaceCount: reusableSurfaceCount
            )
        }
        newLattice.resetNodeStates()

        // 新規部分に関わる辞書引き（既存部分から新規部分にまたがる単語も含む）
        // lookupDicdata自体がmaxlengthより長い範囲を探索しないため、それより前から
        // 始まるノードは新規suffixへ到達できない。
        let earliestAffectedInputIndex = max(
            0,
            reusableInputCount + 1 - self.dicdataStore.maxlength
        )
        let earliestAffectedSurfaceIndex = max(
            0,
            reusableSurfaceCount + 1 - self.dicdataStore.maxlength
        )
        let additionalRawNodes = latticeIndices.map { index in
            let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex,
                                                                              iIndex >= earliestAffectedInputIndex,
                                                                              max(reusableInputCount, iIndex) < inputCount {
                (iIndex, max(reusableInputCount, iIndex) ..< inputCount)
            } else {
                nil
            }
            let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex,
                                                                                sIndex >= earliestAffectedSurfaceIndex,
                                                                                max(reusableSurfaceCount, sIndex) < surfaceCount {
                (sIndex, max(reusableSurfaceCount, sIndex) ..< surfaceCount)
            } else {
                nil
            }

            // 新規部分に関わる場合のみ辞書引き
            if inputRange != nil || surfaceRange != nil {
                return dicdataStore.lookupDicdata(
                    composingText: inputData,
                    inputRange: inputRange,
                    surfaceRange: surfaceRange,
                    needTypoCorrection: false,
                    state: dicdataStoreState
                )
            } else {
                // 完全に既存部分のみの場合は空配列
                return []
            }
        }

        // 追加部分をマージ
        let additionalLattice = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: additionalRawNodes
        )

        newLattice.merge(additionalLattice)
        return newLattice
    }
}
