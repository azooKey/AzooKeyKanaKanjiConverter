//
//  LOUDS.swift
//  Keyboard
//
//  Created by ensan on 2020/09/30.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation

/// LOUDS
package struct LOUDS: Sendable {
    private typealias Unit = UInt64
    private static let unit = 64
    private static let uExp = 6

    private let bits: [Unit]
    /// indexを並べてflattenしたArray。
    /// LOUDS形式が4GB未満を前提としているため、64-bit環境でも`UInt32`で表現できる。
    ///  - seealso: flatChar2nodeIndicesIndex
    private let flatChar2nodeIndices: [UInt32]
    /// 256個の値を入れるArray。`flatChar2nodeIndices[flatChar2nodeIndicesIndex[char - 1] ..< flatChar2nodeIndicesIndex[char]]`が`nodeIndices`になる
    private let flatChar2nodeIndicesIndex: [UInt32]
    /// 0の数（1の数ではない）
    ///
    /// LOUDSのサイズが4GBまでは`UInt32`で十分
    private let rankLarge: [UInt32]

    @inlinable init(bytes: [UInt64], nodeIndex2ID: [UInt8]) {
        self.bits = bytes
        // flatChar2nodeIndicesIndexを構築する
        // これは、どのcharがどれだけの長さのnodeIndicesを持つかを知るために行う
        var flatChar2nodeIndicesIndex = [Int](repeating: 0, count: 256)
        flatChar2nodeIndicesIndex.withUnsafeMutableBufferPointer { buffer in
            for value in nodeIndex2ID {
                buffer[Int(value)] += 1
            }
            // 累積和にする
            for i in 1 ..< 256 {
                buffer[i] = buffer[i - 1] + buffer[i]
            }
        }
        // flatChar2nodeIndicesを構築する
        // すでに開始位置はflatChar2nodeIndicesIndexで分かるので、もう一度countsを構築しながら適切な場所にindexを入れていく
        var counts = [Int](repeating: 0, count: 256)
        self.flatChar2nodeIndices = counts.withUnsafeMutableBufferPointer { countsBuffer in
            var flatChar2nodeIndices = [UInt32](repeating: 0, count: nodeIndex2ID.count)
            for (i, value) in zip(nodeIndex2ID.indices, nodeIndex2ID) {
                if value == .zero {
                    flatChar2nodeIndices[countsBuffer[Int(value)]] = UInt32(i)
                } else {
                    flatChar2nodeIndices[flatChar2nodeIndicesIndex[Int(value) - 1] + countsBuffer[Int(value)]] = UInt32(i)
                }
                countsBuffer[Int(value)] += 1
            }
            return flatChar2nodeIndices
        }
        self.flatChar2nodeIndicesIndex = flatChar2nodeIndicesIndex.map(UInt32.init)

        var rankLarge: [UInt32] = .init(repeating: 0, count: bytes.count + 1)
        rankLarge.withUnsafeMutableBufferPointer { buffer in
            for (i, byte) in zip(bytes.indices, bytes) {
                buffer[i + 1] = buffer[i] &+ UInt32(Self.unit &- byte.nonzeroBitCount)
            }
        }
        self.rankLarge = rankLarge
    }

    /// parentNodeIndex個の0を探索し、その次から1個増えるまでのIndexを返す。
    @inlinable func childNodeIndices(from parentNodeIndex: Int) -> Range<Int> {
        // 求めるのは、
        // startIndex == 自身の左側にparentNodeIndex個の0があるような最小のindex
        // endIndex == 自身の左側にparentNodeIndex+1個の0があるような最小のindex
        // すなわち、childNodeIndicesである。
        // まずstartIndexを発見し、そこから0が現れる点を探すことでendIndexを見つける方針で実装している。

        // 探索パート①
        // rankLargeは左側の0の数を示すので、difを取っている
        // まず最低限の絞り込みを行う。leftを探索する。
        // 探しているのは、startIndexが含まれるbitsのindex `i`
        var left = parentNodeIndex >> Self.uExp
        var right = self.rankLarge.endIndex - 1
        while left <= right {
            let mid = (left + right) / 2
            if self.rankLarge[mid] >= parentNodeIndex {
                right = mid - 1
            } else {
                left = mid + 1
            }
        }
        guard left != self.rankLarge.endIndex else {
            return 0 ..< 0
        }
        let i = left - 1
        return self.bits.withUnsafeBufferPointer {(buffer: UnsafeBufferPointer<Unit>) -> Range<Int> in
            // 探索パート②
            // 目標はparentNodeIndex番目の0の位置である`k`の発見
            let byte = buffer[i]
            var k = 0
            for _ in  0 ..< parentNodeIndex - Int(self.rankLarge[i]) {
                k = (~(byte << k)).leadingZeroBitCount &+ k &+ 1
            }
            let start = (i << Self.uExp) &+ k &- parentNodeIndex &+ 1
            // ちょうどparentNodeIndex個の0がi番目にあるかどうか
            if self.rankLarge[i &+ 1] == parentNodeIndex {
                var j = i &+ 1
                while buffer[j] == Unit.max {
                    j &+= 1
                }
                // 最初の0を探す作業
                // 反転して、先頭から0の数を数えると最初の0の位置が出てくる
                // Ex. 1110_0000 => [000]1_1111 => 3
                let byte2 = buffer[j]
                let a = (~byte2).leadingZeroBitCount % Self.unit
                return start ..< (j << Self.uExp) &+ a &- parentNodeIndex &+ 1
            } else {
                // difが0以上の場合、k番目以降の初めての0を発見したい
                // 例えばk=1の場合
                // Ex. 1011_1101 => 0111_1010 => 1000_0101 => 1 => 2
                let a = ((~(byte << k)).leadingZeroBitCount &+ k) % Self.unit
                return start ..< (i << Self.uExp) &+ a &- parentNodeIndex &+ 1
            }
        }
    }

    /// charIndexを取得する
    /// `childNodeIndices`と差し引きして、二分探索部分の速度への影響は高々0.02秒ほど
    @inlinable func searchCharNodeIndex(from parentNodeIndex: Int, char: UInt8) -> Int? {
        // char2nodeIndicesには単調増加性があるので二分探索が成立する
        let childNodeIndices = self.childNodeIndices(from: parentNodeIndex)
        let nodeIndices: ArraySlice<UInt32> = if char == .zero {
            self.flatChar2nodeIndices[0 ..< Int(self.flatChar2nodeIndicesIndex[Int(char)])]
        } else {
            self.flatChar2nodeIndices[
                Int(self.flatChar2nodeIndicesIndex[Int(char - 1)]) ..< Int(self.flatChar2nodeIndicesIndex[Int(char)])
            ]
        }
        let childStart = UInt32(childNodeIndices.startIndex)
        let childEnd = UInt32(childNodeIndices.endIndex)

        var left = nodeIndices.startIndex
        var right = nodeIndices.endIndex
        while left < right {
            let mid = (left + right) >> 1
            if childStart <= nodeIndices[mid] {
                right = mid
            } else {
                left = mid + 1
            }
        }
        if left < nodeIndices.endIndex && childStart <= nodeIndices[left] && nodeIndices[left] < childEnd {
            return Int(nodeIndices[left])
        } else {
            return nil
        }
    }

    /// 完全一致検索を実行する
    /// - Parameter chars: CharIDに変換した文字列
    /// - Returns: 対応するloudstxt3ファイル内のインデックス
    @inlinable func searchNodeIndex(chars: [UInt8]) -> Int? {
        var index = 1
        for char in chars {
            if let nodeIndex = self.searchCharNodeIndex(from: index, char: char) {
                index = nodeIndex
            } else {
                return nil
            }
        }
        return index
    }

    @inlinable func prefixNodeIndices(nodeIndex: Int, depth: Int = 0, maxDepth: Int, maxCount: Int) -> [Int] {
        var childNodeIndices = Array(self.childNodeIndices(from: nodeIndex))
        if depth == maxDepth {
            return childNodeIndices
        }
        for index in childNodeIndices {
            if childNodeIndices.count > maxCount {
                break
            }
            childNodeIndices.append(
                contentsOf: self.prefixNodeIndices(
                    nodeIndex: index,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    maxCount: maxCount - childNodeIndices.count
                )
            )
        }
        return childNodeIndices
    }

    /// 前方一致検索を実行する
    ///
    /// 「しかい」を入力した場合、そこから先の「しかいし」「しかいしゃ」「しかいいん」なども探す。
    /// - Parameter chars: CharIDに変換した文字列
    /// - Parameter maxDepth: 先に進む深さの最大値
    /// - Returns: 対応するloudstxt3ファイル内のインデックスのリスト
    @inlinable package func prefixNodeIndices(chars: [UInt8], maxDepth: Int, maxCount: Int) -> [Int] {
        guard let nodeIndex = self.searchNodeIndex(chars: chars) else {
            return []
        }
        return self.prefixNodeIndices(nodeIndex: nodeIndex, maxDepth: maxDepth, maxCount: maxCount)
    }

    struct MovingTowardPrefixSearchHelper {
        init(louds: LOUDS) {
            self.louds = louds
        }
        let louds: LOUDS
        // 最終出力となる
        var indices: [(depth: Int, index: Int)] = []
        // 現在の探索結果を保存しておく
        var stack: [(nodeIndex: Int, char: UInt8)] = []

        func indicesInDepth(depth: Range<Int>) -> [Int] {
            self.indices
                .lazy
                .filter { depth.contains($0.depth) }
                .map { $0.index }
        }

        /// `target`を用いて更新する
        /// - Parameter target: 検索対象の`CharID`の列
        /// - Returns: `updated`はこれによって`indices`の更新があったかどうか。`availableMaxIndex`はアクセスに成功した最大インデックス
        @inlinable mutating func update(target: [UInt8]) -> (updated: Bool, availableMaxIndex: Int) {
            var updated = false
            var availableMaxIndex = 0
            // iがupperBoundを超えない範囲で検索を行う
            for (i, char) in target.enumerated() {
                if i < self.stack.count, self.stack[i].char == char {
                    // すでに探索済み
                    availableMaxIndex = i
                    continue
                } else if i < self.stack.count, self.stack[i].char != char {
                    // 異なる文字が見つかったら、その時点でそこから先のstackを破棄
                    self.stack = Array(self.stack[..<i])
                }
                // ここに到達する場合、stack[i]は存在しない。
                assert(i >= self.stack.count, "stack[\(i)] must not exist for logical reason.")
                // このケースでは、探索を行う
                // 直前のstackを取り出し、そのnodeIndexから次のcharを探索する
                if let nodeIndex = self.louds.searchCharNodeIndex(from: self.stack.last?.nodeIndex ?? 1, char: char) {
                    self.indices.append((i, nodeIndex))
                    updated = true
                    availableMaxIndex = i
                    self.stack.append((nodeIndex, char))
                } else {
                    // 見つからなかった場合、打ち切る
                    break
                }
            }
            return (updated, availableMaxIndex)
        }
    }
}
