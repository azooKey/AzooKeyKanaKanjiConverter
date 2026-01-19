//
//  LatticeNode.swift
//  Keyboard
//
//  Created by ensan on 2020/09/11.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation

/// ラティスのノード。これを用いて計算する。
public final class LatticeNode {
    /// このノードが保持する辞書データ
    public let data: DicdataElement
    /// このノードの前に来ているノード。`N_best`の分だけ保存する
    var prevs: [RegisteredNode] = []
    /// `prevs`の各要素に対応するスコアのデータ
    var values: [PValue] = []
    /// inputData.input内のrange
    var range: Lattice.LatticeRange

    /// `EOS`に対応するノード。
    static var EOSNode: LatticeNode {
        LatticeNode(data: DicdataElement.EOSData, range: .zero)
    }

    init(data: DicdataElement, range: Lattice.LatticeRange) {
        self.data = data
        self.values = [data.value()]
        self.range = range
    }

    /// `LatticeNode`の持っている情報を反映した`RegisteredNode`を作成する
    /// `LatticeNode`は複数の過去のノードを持つことができるが、`RegisteredNode`は1つしか持たない。
    func getRegisteredNode(_ index: Int, value: PValue) -> RegisteredNode {
        RegisteredNode(data: self.data, registered: self.prevs[index], totalValue: value, range: self.range)
    }

    /// 再帰的にノードを遡り、`CandidateData`を構築する関数
    /// - Returns: 文節単位の区切り情報を持った変換候補データのリスト。
    /// - Note: 最終的に`EOS`ノードにおいて実行する想定のAPIになっている。
    func getCandidateData() -> [CandidateData] {
        self.prevs.map {$0.getCandidateData()}
    }
}

// MARK: - Sendable support
/// `LatticeNode` stores mutable references that are confined to the converter actor.
/// Until the CoreML bridge returns fully value-typed snapshots (Session 2 plan),
/// we mark it as `@unchecked Sendable` so it can cross async boundaries via DTO wrappers.
extension LatticeNode: @unchecked Sendable {}
