import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

extension Kana2Kanji {
    struct ZenzaiCache {
        init(_ inputData: ComposingText, constraint: PrefixConstraint, satisfyingCandidate: Candidate?, lattice: Lattice? = nil) {
            self.inputData = inputData
            self.prefixConstraint = constraint
            self.satisfyingCandidate = satisfyingCandidate
            self.cachedLattice = lattice
        }

        private var prefixConstraint: PrefixConstraint
        private var satisfyingCandidate: Candidate?
        private var inputData: ComposingText
        private var cachedLattice: Lattice?

        func getNewConstraint(for newInputData: ComposingText) -> PrefixConstraint {
            if let satisfyingCandidate {
                var current = newInputData.convertTarget.toKatakana()[...]
                var constraint = [UInt8]()
                for item in satisfyingCandidate.data {
                    if current.hasPrefix(item.ruby) {
                        constraint += item.word.utf8
                        current = current.dropFirst(item.ruby.count)
                    }
                }
                return PrefixConstraint(constraint)
            } else if newInputData.convertTarget.hasPrefix(inputData.convertTarget) {
                // hasEOSの場合は落とすために改めて作り直す
                return PrefixConstraint(self.prefixConstraint.constraint)
            } else {
                return PrefixConstraint([])
            }
        }

        func getPreprocessedLattice(for newInputData: ComposingText, kanaKanji: Kana2Kanji, dicdataStoreState: DicdataStoreState) -> Lattice? {
            guard let cachedLattice else { return nil }

            // 同じComposingTextなら既存のlatticeをそのまま返す
            if newInputData.input == inputData.input && newInputData.convertTarget == inputData.convertTarget {
                cachedLattice.resetNodeStates()
                return cachedLattice
            }

            // 逐次入力の場合は差分更新でlatticeを構築
            return kanaKanji.buildLatticeWithIncrementalCache(
                inputData: newInputData,
                inputCount: newInputData.input.count,
                surfaceCount: newInputData.convertTarget.count,
                incrementalCacheInfo: (inputData: inputData, lattice: cachedLattice),
                dicdataStoreState: dicdataStoreState
            )
        }
    }

    // MARK: - Sendable support
    /// The cache holds mutable lattice references but never leaves the converter actor.
    /// We temporarily mark it as `@unchecked Sendable` to unblock CoreML refactors.
    extension ZenzaiCache: @unchecked Sendable {}

    struct PrefixConstraint: Sendable, Equatable, Hashable, CustomStringConvertible {
        init(_ constraint: [UInt8], hasEOS: Bool = false, ignoreMemoryAndUserDictionary: Bool = false) {
            self.constraint = constraint
            self.hasEOS = hasEOS
            self.ignoreMemoryAndUserDictionary = ignoreMemoryAndUserDictionary
        }

        var constraint: [UInt8]
        var hasEOS: Bool
        var ignoreMemoryAndUserDictionary: Bool

        var description: String {
            "PrefixConstraint(constraint: \"\(String(decoding: self.constraint, as: UTF8.self))\", hasEOS: \(self.hasEOS), ignoreMemoryAndUserDictionary: \(self.ignoreMemoryAndUserDictionary))"
        }

        var isEmpty: Bool {
            self.constraint.isEmpty && !self.hasEOS
        }
    }

    /// zenzaiシステムによる完全変換。
    #if ZenzaiCoreML && canImport(CoreML)
    @available(iOS 18, macOS 15, *)
    #endif
    func all_zenzai(
        _ inputData: ComposingText,
        evaluateCandidate: @escaping @Sendable (ZenzEvaluationRequest) async -> ZenzCandidateEvaluationResult,
        zenzaiCache: ZenzaiCache?,
        inferenceLimit: Int,
        requestRichCandidates: Bool,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        dicdataStoreState: DicdataStoreState
    ) async -> (result: LatticeNode, lattice: Lattice, cache: ZenzaiCache) {
        var constraint = zenzaiCache?.getNewConstraint(for: inputData) ?? PrefixConstraint([])
        debug("initial constraint", constraint)
        let eosNode = LatticeNode.EOSNode
        var lattice: Lattice = Lattice()
        var constructedCandidates: [(RegisteredNode, Candidate)] = []
        var insertedCandidates: [(RegisteredNode, Candidate)] = []
        defer {
            eosNode.prevs = insertedCandidates.map(\.0)
        }
        var inferenceLimit = inferenceLimit
        while true {
            let start = Date()
            let preprocessedLattice: Lattice?
            if !lattice.isEmpty {
                // 今回の`all_zenzai`の呼び出し内部で使われているキャッシュ（lattice）が存在する場合はそちらを優先する
                lattice.resetNodeStates()
                preprocessedLattice = lattice
            } else {
                // latticeがまだemptyの場合、zenzaiCache側に存在するキャッシュの活用を試みる
                preprocessedLattice = zenzaiCache?.getPreprocessedLattice(for: inputData, kanaKanji: self, dicdataStoreState: dicdataStoreState)
            }
            let draftResult: (result: LatticeNode, lattice: Lattice)
            if constraint.isEmpty {
                // 全部を変換する場合はN=2の変換を行う
                // 実験の結果、ここは2-bestを取ると平均的な速度が最良になることがわかったので、そうしている。
                draftResult = self.kana2lattice_all(inputData, N_best: 2, needTypoCorrection: false, preprocessedLattice: preprocessedLattice, dicdataStoreState: dicdataStoreState)
            } else {
                // 制約がついている場合は高速になるので、N=3としている
                draftResult = self.kana2lattice_all_with_prefix_constraint(inputData, N_best: 3, constraint: constraint, preprocessedLattice: preprocessedLattice, dicdataStoreState: dicdataStoreState)
            }
            if lattice.isEmpty {
                // 初回のみ
                lattice = draftResult.lattice
            }
            let candidates = draftResult.result.getCandidateData().map(self.processClauseCandidate)
            constructedCandidates.append(contentsOf: zip(draftResult.result.prevs, candidates))
            var best: (Int, Candidate)?
            for (i, cand) in candidates.enumerated() {
                if let (_, c) = best, cand.value > c.value {
                    best = (i, cand)
                } else if best == nil {
                    best = (i, cand)
                }
            }
            guard var (index, candidate) = best else {
                debug("best was not found!")
                // Emptyの場合
                // 制約が満たせない場合は無視する
                return (eosNode, lattice, ZenzaiCache(inputData, constraint: PrefixConstraint([]), satisfyingCandidate: nil, lattice: lattice))
            }

            debug("Constrained draft modeling", -start.timeIntervalSinceNow)
            reviewLoop: while true {
                // resultsを更新
                // ここでN-Bestも並び変えていることになる
                insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 0)
                if inferenceLimit == 0 {
                    debug("inference limit! \(candidate.text) is used for excuse")
                    // When inference occurs more than maximum times, then just return result at this point
                    return (eosNode, lattice, ZenzaiCache(inputData, constraint: constraint, satisfyingCandidate: candidate, lattice: lattice))
                }
                let payload = ZenzEvaluationRequest(
                    convertTarget: inputData.convertTarget,
                    candidate: candidate.zenzSnapshot(),
                    requestRichCandidates: requestRichCandidates,
                    prefixConstraint: ZenzPrefixConstraintSnapshot(constraint),
                    versionDependentConfig: versionDependentConfig
                )
                let reviewResult = await evaluateCandidate(payload)
                inferenceLimit -= 1
                let nextAction = self.review(
                    candidateIndex: index,
                    candidates: candidates,
                    reviewResult: reviewResult,
                    constraint: &constraint
                )
                switch nextAction {
                case .return(let constraint, let alternativeConstraints, let satisfied):
                    if requestRichCandidates {
                        // alternativeConstraintsに従い、insertedCandidatesにデータを追加する
                        for alternativeConstraint in alternativeConstraints.reversed() where alternativeConstraint.probabilityRatio > 0.25 {
                            // constructed candidatesのうちalternativeConstraint.prefixConstraintを満たすものを列挙する
                            let mostLiklyCandidate = constructedCandidates.filter {
                                $0.1.text.utf8.hasPrefix(alternativeConstraint.prefixConstraint)
                            }.max {
                                $0.1.value < $1.1.value
                            }
                            if let mostLiklyCandidate {
                                // 0番目は最良候補
                                insertedCandidates.insert(mostLiklyCandidate, at: 1)
                            } else if alternativeConstraint.probabilityRatio > 0.5 {
                                // 十分に高い確率の場合、変換器を実際に呼び出して候補を作ってもらう
                                lattice.resetNodeStates()
                                let draftResult = self.kana2lattice_all_with_prefix_constraint(inputData, N_best: 3, constraint: PrefixConstraint(alternativeConstraint.prefixConstraint), preprocessedLattice: lattice, dicdataStoreState: dicdataStoreState)
                                let candidates = draftResult.result.getCandidateData().map(self.processClauseCandidate)
                                let best: (Int, Candidate)? = candidates.enumerated().reduce(into: (Int, Candidate)?.none) { best, pair in
                                    if let (_, c) = best, pair.1.value > c.value {
                                        best = pair
                                    } else if best == nil {
                                        best = pair
                                    }
                                }
                                if let (index, candidate) = best {
                                    insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 1)
                                }
                            }
                        }
                    }
                    if satisfied {
                        return (eosNode, lattice, ZenzaiCache(inputData, constraint: constraint, satisfyingCandidate: candidate, lattice: lattice))
                    } else {
                        return (eosNode, lattice, ZenzaiCache(inputData, constraint: constraint, satisfyingCandidate: nil, lattice: lattice))
                    }
                case .continue:
                    break reviewLoop
                case .retry(let candidateIndex):
                    index = candidateIndex
                    candidate = candidates[candidateIndex]
                }
            }
        }
    }

    #if ZenzaiCoreML && canImport(CoreML)
    @available(iOS 18, macOS 15, *)
    #endif
    private enum NextAction {
        case `return`(constraint: PrefixConstraint, alternativeConstraints: [ZenzCandidateEvaluationResult.AlternativeConstraint], satisfied: Bool)
        case `continue`
        case `retry`(candidateIndex: Int)
    }

    #if ZenzaiCoreML && canImport(CoreML)
    @available(iOS 18, macOS 15, *)
    #endif
    private func review(
        candidateIndex: Int,
        candidates: [Candidate],
        reviewResult: consuming ZenzCandidateEvaluationResult,
        constraint: inout PrefixConstraint
    ) -> NextAction {
        switch reviewResult {
        case .error:
            // 何らかのエラーが発生
            debug("error")
            return .return(constraint: constraint, alternativeConstraints: [], satisfied: false)
        case .pass(let score, let alternativeConstraints):
            // 合格
            debug("passed:", score)
            return .return(constraint: constraint, alternativeConstraints: alternativeConstraints, satisfied: true)
        case .fixRequired(let prefixConstraint):
            if constraint.constraint == prefixConstraint {
                if !constraint.ignoreMemoryAndUserDictionary, candidates[candidateIndex].data.contains(where: { !$0.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary])}) {
                    // `ignoreMemoryAndUserDictionary`でない場合、学習候補がモデルにリジェクトされた可能性を検討する
                    debug("same constraint (fixRequired), but retry without memory and user dictionary:", prefixConstraint)
                    constraint.ignoreMemoryAndUserDictionary = true
                    for (i, candidate) in candidates.indexed() where i != candidateIndex {
                        if candidate.text.utf8.hasPrefix(prefixConstraint) && self.heuristicRetryValidation(candidate.text) {
                            debug("found \(candidate.text) as another retry")
                            return .retry(candidateIndex: i)
                        }
                    }
                    return .continue
                } else {
                    // それ以外の場合で同じ制約が2回連続で出てきたら諦める
                    debug("same constraint (fixRequired):", prefixConstraint)
                    return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
                }
            }
            // 制約が得られたので、更新する
            let isIncrementalUpdate = prefixConstraint.hasPrefix(constraint.constraint)
            constraint = PrefixConstraint(prefixConstraint, ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary)
            debug("update constraint:", constraint)
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // この処理の正当性は、prefix constraintが漸進的に更新され、candidatesの構築時に可能な候補がすべて確認されたことに由来する
                // このため、学習候補などが最終ドラフトとして採択され、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if candidate.text.utf8.hasPrefix(prefixConstraint) && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        case .wholeResult(let wholeConstraint):
            let newConstraint = PrefixConstraint(Array(wholeConstraint.utf8), hasEOS: true, ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary)
            // 同じ制約が2回連続で出てきたら諦める
            if constraint == newConstraint {
                if !constraint.ignoreMemoryAndUserDictionary, candidates[candidateIndex].data.contains(where: { !$0.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary])}) {
                    // `ignoreMemoryAndUserDictionary`でない場合、学習候補がモデルにリジェクトされた可能性を検討する
                    debug("same constraint (wholeResult), but retry without memory and user dictionary:", constraint)
                    constraint.ignoreMemoryAndUserDictionary = true
                    for (i, candidate) in candidates.indexed() where i != candidateIndex {
                        if candidate.text.utf8.elementsEqual(wholeConstraint.utf8) && self.heuristicRetryValidation(candidate.text) {
                            debug("found \(candidate.text) as another retry")
                            return .retry(candidateIndex: i)
                        }
                    }
                    return .continue
                } else {
                    // それ以外の場合で同じ制約が2回連続で出てきたら諦める
                    debug("same constraint (wholeResult):", constraint)
                    return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
                }
            }
            // 制約が得られたので、更新する
            debug("update whole constraint:", wholeConstraint)
            let isIncrementalUpdate = wholeConstraint.utf8.hasPrefix(constraint.constraint)
            constraint = PrefixConstraint(Array(wholeConstraint.utf8), hasEOS: true)
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // 上記と同様に、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if candidate.text == wholeConstraint && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        }
    }

    /// リトライの候補に対して恣意的なバリデーションを実施する
    private func heuristicRetryValidation(_ text: String) -> Bool {
        // 合成濁点・半濁点
        if text.unicodeScalars.contains("\u{3099}") || text.unicodeScalars.contains("\u{309A}") {
            return false
        }
        return true
    }
}
