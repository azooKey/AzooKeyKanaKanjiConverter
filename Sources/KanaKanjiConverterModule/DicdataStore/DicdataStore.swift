//
//  DicdataStore.swift
//  Keyboard
//
//  Created by ensan on 2020/09/17.
//  Copyright © 2020 ensan. All rights reserved.
//

import Algorithms
import Foundation
import SwiftUtils

public final class DicdataStore {
    public init(convertRequestOptions: ConvertRequestOptions) {
        self.requestOptions = convertRequestOptions
        self.setup()
    }

    init(requestOptions: ConvertRequestOptions = .default) {
        self.requestOptions = requestOptions
        debug("DicdataStoreが初期化されました")
        self.setup()
    }

    private var ccParsed: [Bool] = .init(repeating: false, count: 1319)
    private var ccLines: [[Int: PValue]] = []
    private var mmValue: [PValue] = []

    private var loudses: [String: LOUDS] = [:]
    private var loudstxts: [String: Data] = [:]    
    private var importedLoudses: Set<String> = []
    private var charsID: [Character: UInt8] = [:]
    private var learningManager = LearningManager()

    private var dynamicUserDict: [DicdataElement] = []

    /// 辞書のエントリの最大長さ
    ///  - TODO: make this value as an option
    public let maxlength: Int = 20
    /// この値以下のスコアを持つエントリは積極的に無視する
    ///  - TODO: make this value as an option
    public let threshold: PValue = -17
    private let midCount = 502
    private let cidCount = 1319

    private var requestOptions: ConvertRequestOptions = .default

    private let numberFormatter = NumberFormatter()
    /// 初期化時のセットアップ用の関数。プロパティリストを読み込み、連接確率リストを読み込んで行分割し保存しておく。
    private func setup() {
        numberFormatter.numberStyle = .spellOut
        numberFormatter.locale = .init(identifier: "ja-JP")
        self.ccLines = [[Int: PValue]].init(repeating: [:], count: CIDData.totalCount)

        do {
            let string = try String(contentsOf: self.requestOptions.dictionaryResourceURL.appendingPathComponent("louds/charID.chid", isDirectory: false), encoding: String.Encoding.utf8)
            charsID = [Character: UInt8].init(uniqueKeysWithValues: string.enumerated().map {($0.element, UInt8($0.offset))})
        } catch {
            debug("Error: louds/charID.chidが存在しません。このエラーは深刻ですが、テスト時には無視できる場合があります。Description: \(error)")
        }
        do {
            let url = requestOptions.dictionaryResourceURL.appendingPathComponent("mm.binary", isDirectory: false)
            do {
                let binaryData = try Data(contentsOf: url, options: [.uncached])
                self.mmValue = binaryData.toArray(of: Float.self).map {PValue($0)}
            } catch {
                debug("Error: mm.binaryが存在しません。このエラーは深刻ですが、テスト時には無視できる場合があります。Description: \(error)")
                self.mmValue = [PValue].init(repeating: .zero, count: self.midCount * self.midCount)
            }
        }
        self.reloadUser()
        _ = self.loadLOUDS(query: "user")
        self.reloadMemory()
        _ = self.loadLOUDS(query: "memory")

        if requestOptions.preloadDictionary {
            self.preloadDictionary()
        }
    }

    /// ファイルI/Oの遅延を減らすために、辞書を事前に読み込む関数。
    private func preloadDictionary() {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: self.requestOptions.dictionaryResourceURL.appendingPathComponent("louds", isDirectory: true),
            includingPropertiesForKeys: nil
        ) else { return }

        for url in fileURLs {
            let identifier = url.deletingPathExtension().lastPathComponent
            let pathExt = url.pathExtension
            
            switch pathExt {
                case "louds":
                    // userやmemoryは実行中に更新される場合があるため、キャッシュから除外
                    if identifier == "user" || identifier == "memory" {
                        continue
                    }
                    loudses[identifier] = LOUDS.load(identifier, option: self.requestOptions)
                case "loudstxt3":
                    if let data = try? Data(contentsOf: url) {
                        loudstxts[identifier] = data
                    } else {
                        debug("Error: Could not load loudstxt3 file at \(url)")
                    }
                default:
                    continue
            }
        }
    }

    public enum Notification {
        /// use `importDynamicUserDict` for data that cannot be obtained statically.
        /// - warning: Too many dynamic user dictionary will damage conversion performance, as dynamic user dictionary uses inefficent algorithms for looking up. If your entries can be listed up statically, then use normal user dictionaries.
        case importDynamicUserDict([DicdataElement])
        @available(*, deprecated, renamed: "importDynamicUserDict", message: "it will be removed in AzooKeyKanaKanjiConverter v1.0")
        case importOSUserDict([DicdataElement])
        case setRequestOptions(ConvertRequestOptions)
        case forgetMemory(Candidate)
        case closeKeyboard
    }

    func sendToDicdataStore(_ data: Notification) {
        switch data {
        case .closeKeyboard:
            self.closeKeyboard()
        case .importOSUserDict(let dicdata), .importDynamicUserDict(let dicdata):
            self.dynamicUserDict = dicdata
            self.dynamicUserDict.mutatingForEach {
                $0.metadata = .isFromUserDictionary
            }
        case let .forgetMemory(candidate):
            self.learningManager.forgetMemory(data: candidate.data)
            // loudsの処理があるので、リセットを実施する
            self.reloadMemory()
        case let .setRequestOptions(value):
            // bundleURLが変わる場合はsetupを再実行する
            if value.dictionaryResourceURL != self.requestOptions.dictionaryResourceURL {
                self.requestOptions = value
                self.setup()
            } else {
                self.requestOptions = value
            }
            let shouldReset = self.learningManager.setRequestOptions(value)
            if shouldReset {
                self.reloadMemory()
            }
        }
    }

    func character2charId(_ character: Character) -> UInt8 {
        self.charsID[character, default: .max]
    }

    private func reloadMemory() {
        self.loudses.removeValue(forKey: "memory")
        self.importedLoudses.remove("memory")
    }

    private func reloadUser() {
        self.loudses.removeValue(forKey: "user")
        self.importedLoudses.remove("user")
    }

    private func closeKeyboard() {
        self.learningManager.save()
        // saveしたあとにmemoryのキャッシュされたLOUDSを使い続けないよう、キャッシュから削除する。
        self.reloadMemory()
        self.reloadUser()
    }

    /// ペナルティ関数。文字数で決める。
    @inlinable static func getPenalty(data: borrowing DicdataElement) -> PValue {
        -2.0 / PValue(data.word.count)
    }

    /// 計算時に利用。無視すべきデータかどうか。
    private func shouldBeRemoved(value: PValue, wordCount: Int) -> Bool {
        let d = value - self.threshold
        if d < 0 {
            return true
        }
        // dは正
        return -2.0 / PValue(wordCount) < -d
    }

    /// 計算時に利用。無視すべきデータかどうか。
    @inlinable func shouldBeRemoved(data: borrowing DicdataElement) -> Bool {
        let d = data.value() - self.threshold
        if d < 0 {
            return true
        }
        return Self.getPenalty(data: data) < -d
    }

    func loadLOUDS(query: String) -> LOUDS? {
        if importedLoudses.contains(query) {
            return self.loudses[query]
        }
        // LOUDSが読み込めたか否かにかかわらず、importedLoudsesは更新する
        importedLoudses.insert(query)
        // 一部のASCII文字はエスケープする
        let identifier = [
            "\\n": "[0A]",
            " ": "[20]",
            "\"": "[22]",
            "\'": "[27]",
            "*": "[2A]",
            "+": "[2B]",
            ".": "[2E]",
            "/": "[2F]",
            ":": "[3A]",
            "<": "[3C]",
            ">": "[3E]",
            "\\": "[5C]",
            "|": "[7C]",
        ][query, default: query]
        if let louds = LOUDS.load(identifier, option: self.requestOptions) {
            self.loudses[query] = louds
            return louds
        } else {
            if identifier == "user" || identifier == "memory" {
                debug("Error: IDが「\(identifier) (query: \(query))」のloudsファイルの読み込みに失敗しましたが、このエラーは深刻ではありません。")
            } else {
                debug("Error: IDが「\(identifier) (query: \(query))」のloudsファイルの読み込みに失敗しました。IDに対する辞書データが存在しないことが想定される場合はこのエラーは深刻ではありませんが、そうでない場合は深刻なエラーの可能性があります。")
            }
            return nil
        }
    }

    func perfectMatchLOUDS(query: String, charIDs: [UInt8]) -> [Int] {
        guard let louds = self.loadLOUDS(query: query) else {
            return []
        }
        return [louds.searchNodeIndex(chars: charIDs)].compactMap {$0}
    }

    private func throughMatchLOUDS(query: String, charIDs: [UInt8], depth: Range<Int>) -> [Int] {
        guard let louds = self.loadLOUDS(query: query) else {
            return []
        }
        let result = louds.byfixNodeIndices(chars: charIDs)
        // result[1]から始まるので、例えば3..<5 (3文字と4文字)の場合は1文字ずつずらして4..<6の範囲をもらう
        return Array(result[min(depth.lowerBound + 1, result.endIndex) ..< min(depth.upperBound + 1, result.endIndex)])
    }

    /// 辞書検索用関数
    /// - Parameters:
    ///   - group: ファイルのプレフィックスとなる文字列（通常、最初の1文字）と、その文字列で始まる文字IDのプレフィックスの集合
    ///   - depth: 検索対象となる深さ。`2..<4`の場合は2文字・3文字の候補のみ取りだす
    /// - Returns: 発見されたすべてのインデックス
    private func throughMatchLOUDS(group: [String: [([Character], [UInt8])]], depth: Range<Int>) -> [(key: String, indices: Set<Int>)] {
        let indices: [(String, Set<Int>)] = group.map {dic in
            guard let louds = self.loadLOUDS(query: dic.key) else {
                return (dic.key, [])
            }
            // バルク処理用の実装を呼び出す
            let result = louds.byfixNodeIndices(targets: dic.value.map { $0.1 }, depth: depth)
            return (dic.key, Set(result))
        }
        return indices
    }

    private func prefixMatchLOUDS(query: String, charIDs: [UInt8], depth: Int = .max, maxCount: Int = .max) -> [Int] {
        guard let louds = self.loadLOUDS(query: query) else {
            return []
        }
        return louds.prefixNodeIndices(chars: charIDs, maxDepth: depth, maxCount: maxCount)
    }

    package func getDicdataFromLoudstxt3(identifier: String, indices: some Sequence<Int>) -> [DicdataElement] {
        // split = 2048
        let dict = [Int: [Int]].init(grouping: indices, by: {$0 >> 11})
        var data: [DicdataElement] = []
        for (key, value) in dict {
            data.append(contentsOf: LOUDS.getDataForLoudstxt3(identifier + "\(key)", indices: value.map {$0 & 2047}, cache: self.loudstxts[identifier + "\(key)"], option: self.requestOptions))
        }
        if identifier == "memory" {
            data.mutatingForEach {
                $0.metadata = .isLearned
            }
        }
        if identifier == "user" {
            data.mutatingForEach {
                $0.metadata = .isFromUserDictionary
            }
        }
        return data
    }

    /// kana2latticeから参照する。
    /// - Parameters:
    ///   - inputData: 入力データ
    ///   - from: 起点
    ///   - toIndexRange: `from ..< (toIndexRange)`の範囲で辞書ルックアップを行う。
    public func getLOUDSDataInRange(inputData: ComposingText, from fromIndex: Int, toIndexRange: Range<Int>? = nil, needTypoCorrection: Bool = true) -> [LatticeNode] {
        if !needTypoCorrection {
            return self.getFrozenLOUDSDataInRange(inputData: inputData, from: fromIndex, toIndexRange: toIndexRange)
        }
        let toIndexLeft = toIndexRange?.startIndex ?? fromIndex
        let toIndexRight = min(toIndexRange?.endIndex ?? inputData.input.count, fromIndex + self.maxlength)
        if fromIndex > toIndexLeft || toIndexLeft >= toIndexRight {
            debug(#function, "index is wrong")
            return []
        }

        let segments = (fromIndex ..< toIndexRight).reduce(into: []) { (segments: inout [String], rightIndex: Int) in
            segments.append((segments.last ?? "") + String(inputData.input[rightIndex].character.toKatakana()))
        }
        // MARK: 誤り訂正の対象を列挙する。非常に重い処理。
        var stringToInfo = inputData.getRangesWithTypos(fromIndex, rightIndexRange: toIndexLeft ..< toIndexRight)
        // MARK: 検索対象を列挙していく。
        let stringSet: [([Character], [UInt8])] = stringToInfo.keys.map {($0, $0.map(self.character2charId))}
        let (minCharIDsCount, maxCharIDsCount) = stringSet.lazy.map {$0.1.count}.minAndMax() ?? (0, -1)
        let depth = minCharIDsCount - 1 ..< maxCharIDsCount
        let group = [String: [([Character], [UInt8])]].init(grouping: stringSet, by: {String($0.0.first!)})
        var indices = self.throughMatchLOUDS(group: group, depth: depth)
        if learningManager.enabled {
            indices.append(contentsOf: self.throughMatchLOUDS(group: ["user": stringSet, "memory": stringSet], depth: depth))
        } else {
            indices.append(contentsOf: self.throughMatchLOUDS(group: ["user": stringSet], depth: depth))
        }
        // MARK: 検索によって得たindicesから辞書データを実際に取り出していく
        var dicdata: [DicdataElement] = []
        for (identifier, value) in indices {
            let result: [DicdataElement] = self.getDicdataFromLoudstxt3(identifier: identifier, indices: value).compactMap { (data) -> DicdataElement? in
                let rubyArray = Array(data.ruby)
                let penalty = stringToInfo[rubyArray, default: (0, .zero)].penalty
                if penalty.isZero {
                    return data
                }
                let ratio = Self.penaltyRatio[data.lcid]
                let pUnit: PValue = Self.getPenalty(data: data) / 2   // 負の値
                let adjust = pUnit * penalty * ratio
                if self.shouldBeRemoved(value: data.value() + adjust, wordCount: rubyArray.count) {
                    return nil
                }
                return data.adjustedData(adjust)
            }
            dicdata.append(contentsOf: result)
        }
        // temporalな学習結果にpenaltyを加えて追加する
        for (_, charIds) in consume stringSet {
            for data in self.learningManager.temporaryThroughMatch(charIDs: consume charIds, depth: depth) {
                let rubyArray = Array(data.ruby)
                let penalty = stringToInfo[rubyArray, default: (0, .zero)].penalty
                if penalty.isZero {
                    dicdata.append(data)
                }
                let ratio = Self.penaltyRatio[data.lcid]
                let pUnit: PValue = Self.getPenalty(data: data) / 2   // 負の値
                let adjust = pUnit * penalty * ratio
                if self.shouldBeRemoved(value: data.value() + adjust, wordCount: rubyArray.count) {
                    continue
                }
                dicdata.append(data.adjustedData(adjust))
            }
        }

        for i in toIndexLeft ..< toIndexRight {
            do {
                let result = self.getWiseDicdata(convertTarget: segments[i - fromIndex], inputData: inputData, inputRange: fromIndex ..< i + 1)
                for item in result {
                    stringToInfo[Array(item.ruby)] = (i, 0)
                }
                dicdata.append(contentsOf: result)
            }
            do {
                let result = self.getMatchDynamicUserDict(segments[i - fromIndex])
                for item in result {
                    stringToInfo[Array(item.ruby)] = (i, 0)
                }
                dicdata.append(contentsOf: result)
            }
        }
        if fromIndex == .zero {
            let result: [LatticeNode] = dicdata.compactMap {
                guard let endIndex = stringToInfo[Array($0.ruby)]?.endIndex else {
                    return nil
                }
                let node = LatticeNode(data: $0, inputRange: fromIndex ..< endIndex + 1)
                node.prevs.append(RegisteredNode.BOSNode())
                return node
            }
            return result
        } else {
            let result: [LatticeNode] = dicdata.compactMap {
                guard let endIndex = stringToInfo[Array($0.ruby)]?.endIndex else {
                    return nil
                }
                return LatticeNode(data: $0, inputRange: fromIndex ..< endIndex + 1)
            }
            return result
        }
    }

    /// kana2latticeから参照する。
    /// - Parameters:
    ///   - inputData: 入力データ
    ///   - from: 起点
    ///   - toIndexRange: `from ..< (toIndexRange)`の範囲で辞書ルックアップを行う。
    private func getFrozenLOUDSDataInRange(inputData: ComposingText, from fromIndex: Int, toIndexRange: Range<Int>? = nil) -> [LatticeNode] {
        let toIndexLeft = toIndexRange?.startIndex ?? fromIndex
        let toIndexRight = min(toIndexRange?.endIndex ?? inputData.input.count, fromIndex + self.maxlength)
        debug(#function, fromIndex, toIndexRange?.description ?? "nil", toIndexLeft, toIndexRight)
        if fromIndex > toIndexLeft || toIndexLeft >= toIndexRight {
            debug(#function, "index is wrong")
            return []
        }

        let character = String(inputData.input[fromIndex].character.toKatakana())
        let characterNode = LatticeNode(data: DicdataElement(word: character, ruby: character, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10), inputRange: fromIndex ..< fromIndex + 1)
        if fromIndex == .zero {
            characterNode.prevs.append(.BOSNode())
        }

        // MARK: 誤り訂正なし
        let stringToEndIndex = inputData.getRangesWithoutTypos(fromIndex, rightIndexRange: toIndexLeft ..< toIndexRight)
        // MARK: 検索対象を列挙していく。
        guard let (minString, maxString) = stringToEndIndex.keys.minAndMax(by: {$0.count < $1.count}) else {
            debug(#function, "minString/maxString is nil", stringToEndIndex)
            return [characterNode]
        }
        let maxIDs = maxString.map(self.character2charId)
        var keys = [String(stringToEndIndex.keys.first!.first!), "user"]
        if learningManager.enabled {
            keys.append("memory")
        }
        // MARK: 検索によって得たindicesから辞書データを実際に取り出していく
        var dicdata: [DicdataElement] = []
        let depth = minString.count - 1 ..< maxString.count
        for identifier in keys {
            dicdata.append(contentsOf: self.getDicdataFromLoudstxt3(identifier: identifier, indices: self.throughMatchLOUDS(query: identifier, charIDs: maxIDs, depth: depth)))
        }
        if learningManager.enabled {
            // temporalな学習結果にpenaltyを加えて追加する
            dicdata.append(contentsOf: self.learningManager.temporaryThroughMatch(charIDs: consume maxIDs, depth: depth))
        }
        for (key, value) in stringToEndIndex {
            let convertTarget = String(key)
            dicdata.append(contentsOf: self.getWiseDicdata(convertTarget: convertTarget, inputData: inputData, inputRange: fromIndex ..< value + 1))
            dicdata.append(contentsOf: self.getMatchDynamicUserDict(convertTarget))
        }
        if fromIndex == .zero {
            return dicdata.compactMap {
                guard let endIndex = stringToEndIndex[Array($0.ruby)] else {
                    return nil
                }
                let node = LatticeNode(data: $0, inputRange: fromIndex ..< endIndex + 1)
                node.prevs.append(RegisteredNode.BOSNode())
                return node
            } + [characterNode]
        } else {
            return dicdata.compactMap {
                guard let endIndex = stringToEndIndex[Array($0.ruby)] else {
                    return nil
                }
                return LatticeNode(data: $0, inputRange: fromIndex ..< endIndex + 1)
            } + [characterNode]
        }
    }

    /// kana2latticeから参照する。louds版。
    /// - Parameters:
    ///   - inputData: 入力データ
    ///   - from: 始点
    ///   - to: 終点
    public func getLOUDSData(inputData: ComposingText, from fromIndex: Int, to toIndex: Int, needTypoCorrection: Bool) -> [LatticeNode] {
        if toIndex - fromIndex > self.maxlength || fromIndex > toIndex {
            return []
        }
        let segment = inputData.input[fromIndex...toIndex].reduce(into: "") {$0.append($1.character)}.toKatakana()

        // TODO: 最適化の余地あり
        let string2penalty = inputData.getRangeWithTypos(fromIndex, toIndex).filter {
            needTypoCorrection || $0.value == 0.0
        }

        // MARK: 検索によって得たindicesから辞書データを実際に取り出していく
        // 先頭の文字: そこで検索したい文字列の集合
        let strings = string2penalty.keys.map {
            (key: $0, charIDs: $0.map(self.character2charId))
        }
        let group = [Character: [(key: [Character], charIDs: [UInt8])]].init(grouping: strings, by: {$0.key.first!})

        var indices: [(String, Set<Int>)] = group.map {dic in
            let head = String(dic.key)
            let set = dic.value.flatMapSet { (_, charIDs) in
                self.perfectMatchLOUDS(query: head, charIDs: charIDs)
            }
            return (head, set)
        }
        do {
            let set = strings.flatMapSet { (_, charIDs) in
                self.perfectMatchLOUDS(query: "user", charIDs: charIDs)
            }
            indices.append(("user", set))
        }
        if learningManager.enabled {
            let set = strings.flatMapSet { (_, charIDs) in
                self.perfectMatchLOUDS(query: "memory", charIDs: charIDs)
            }
            indices.append(("memory", set))
        }
        var dicdata: [DicdataElement] = []
        for (identifier, value) in indices {
            let result: [DicdataElement] = self.getDicdataFromLoudstxt3(identifier: identifier, indices: value).compactMap { (data) -> DicdataElement? in
                let rubyArray = Array(data.ruby)
                let penalty = string2penalty[rubyArray, default: .zero]
                if penalty.isZero {
                    return data
                }
                let ratio = Self.penaltyRatio[data.lcid]
                let pUnit: PValue = Self.getPenalty(data: data) / 2   // 負の値
                let adjust = pUnit * penalty * ratio
                if self.shouldBeRemoved(value: data.value() + adjust, wordCount: rubyArray.count) {
                    return nil
                }
                return data.adjustedData(adjust)
            }
            dicdata.append(contentsOf: result)
        }
        // temporalな学習結果にpenaltyを加えて追加する
        for (characters, charIds) in consume strings {
            for data in self.learningManager.temporaryPerfectMatch(charIDs: consume charIds) {
                // perfect matchなので、Array(data.ruby)はcharactersに等しい
                let penalty = string2penalty[characters, default: .zero]
                if penalty.isZero {
                    dicdata.append(data)
                }
                let ratio = Self.penaltyRatio[data.lcid]
                let pUnit: PValue = Self.getPenalty(data: data) / 2   // 負の値
                let adjust = pUnit * penalty * ratio
                if self.shouldBeRemoved(value: data.value() + adjust, wordCount: characters.count) {
                    continue
                }
                dicdata.append(data.adjustedData(adjust))
            }
        }

        dicdata.append(contentsOf: self.getWiseDicdata(convertTarget: segment, inputData: inputData, inputRange: fromIndex ..< toIndex + 1))
        for segment in string2penalty.keys {
            dicdata.append(contentsOf: self.getMatchDynamicUserDict(String(segment)))
        }

        if fromIndex == .zero {
            let result: [LatticeNode] = dicdata.map {
                let node = LatticeNode(data: $0, inputRange: fromIndex ..< toIndex + 1)
                node.prevs.append(RegisteredNode.BOSNode())
                return node
            }
            return result
        } else {
            let result: [LatticeNode] = dicdata.map {LatticeNode(data: $0, inputRange: fromIndex ..< toIndex + 1)}
            return result
        }
    }

    func getZeroHintPredictionDicdata(lastRcid: Int) -> [DicdataElement] {
        do {
            let csvString = try String(contentsOf: requestOptions.dictionaryResourceURL.appendingPathComponent("p/pc_\(lastRcid).csv", isDirectory: false), encoding: .utf8)
            let csvLines = csvString.split(separator: "\n")
            let csvData = csvLines.map {$0.split(separator: ",", omittingEmptySubsequences: false)}
            let dicdata: [DicdataElement] = csvData.map {self.parseLoudstxt2FormattedEntry(from: $0)}
            return dicdata
        } catch {
            debug("Error: 右品詞ID\(lastRcid)のためのZero Hint Predictionのためのデータの読み込みに失敗しました。このエラーは深刻ですが、テスト時には無視できる場合があります。 Description: \(error.localizedDescription)")
            return []
        }
    }

    /// 辞書から予測変換データを読み込む関数
    /// - Parameters:
    ///   - head: 辞書を引く文字列
    /// - Returns:
    ///   発見されたデータのリスト。
    func getPredictionLOUDSDicdata(key: some StringProtocol) -> [DicdataElement] {
        let count = key.count
        if count == .zero {
            return []
        }
        // 最大700件に絞ることによって低速化を回避する。
        let maxCount = 700
        var result: [DicdataElement] = []
        let first = String(key.first!)
        let charIDs = key.map(self.character2charId)
        // 1, 2文字に対する予測変換は候補数が大きいので、depth（〜文字数）を制限する
        let depth = if count == 1 {
            3
        } else if count == 2 {
            5
        } else {
            Int.max
        }
        let prefixIndices = self.prefixMatchLOUDS(query: first, charIDs: charIDs, depth: depth, maxCount: maxCount)

        result.append(
            contentsOf: self.getDicdataFromLoudstxt3(identifier: first, indices: Set(prefixIndices))
                .filter { Self.predictionUsable[$0.rcid] }
        )
        let userDictIndices = self.prefixMatchLOUDS(query: "user", charIDs: charIDs, maxCount: maxCount)
        result.append(contentsOf: self.getDicdataFromLoudstxt3(identifier: "user", indices: Set(consume userDictIndices)))
        if learningManager.enabled {
            let memoryDictIndices = self.prefixMatchLOUDS(query: "memory", charIDs: charIDs, maxCount: maxCount)
            result.append(contentsOf: self.getDicdataFromLoudstxt3(identifier: "memory", indices: Set(consume memoryDictIndices)))
            result.append(contentsOf: self.learningManager.temporaryPrefixMatch(charIDs: charIDs))
        }
        return result
    }

    private func parseLoudstxt2FormattedEntry(from dataString: [some StringProtocol]) -> DicdataElement {
        let ruby = String(dataString[0])
        let word = dataString[1].isEmpty ? ruby:String(dataString[1])
        let lcid = Int(dataString[2]) ?? .zero
        let rcid = Int(dataString[3]) ?? lcid
        let mid = Int(dataString[4]) ?? .zero
        let value: PValue = PValue(dataString[5]) ?? -30.0
        return DicdataElement(word: word, ruby: ruby, lcid: lcid, rcid: rcid, mid: mid, value: value)
    }

    /// 補足的な辞書情報を得る。
    ///  - parameters:
    ///     - convertTarget: カタカナ変換済みの文字列
    /// - note
    ///     - 入力全体をカタカナとかひらがなに変換するやつは、Converter側でやっているので注意。
    func getWiseDicdata(convertTarget: String, inputData: ComposingText, inputRange: Range<Int>) -> [DicdataElement] {
        var result: [DicdataElement] = []
        result.append(contentsOf: self.getJapaneseNumberDicdata(head: convertTarget))
        if inputData.input[..<inputRange.startIndex].last?.character.isNumber != true && inputData.input[inputRange.endIndex...].first?.character.isNumber != true, let number = Int(convertTarget) {
            result.append(DicdataElement(ruby: convertTarget, cid: CIDData.数.cid, mid: MIDData.小さい数字.mid, value: -14))
            if Double(number) <= 1E12 && -1E12 <= Double(number), let kansuji = self.numberFormatter.string(from: NSNumber(value: number)) {
                result.append(DicdataElement(word: kansuji, ruby: convertTarget, cid: CIDData.数.cid, mid: MIDData.小さい数字.mid, value: -16))
            }
        }

        // convertTargetを英単語として候補に追加する
        if requestOptions.keyboardLanguage == .en_US && convertTarget.onlyRomanAlphabet {
            result.append(DicdataElement(ruby: convertTarget, cid: CIDData.固有名詞.cid, mid: MIDData.英単語.mid, value: -14))
        }

        // ローマ字入力の場合、単体でひらがな・カタカナ化した候補も追加
        if requestOptions.keyboardLanguage != .en_US && inputData.input[inputRange].allSatisfy({$0.inputStyle == .roman2kana}) {
            let roman = String(inputData.input[inputRange].map(\.character))
            if let katakana = Roman2Kana.katakanaChanges[roman], let hiragana = Roman2Kana.hiraganaChanges[Array(roman)] {
                result.append(DicdataElement(word: String(hiragana), ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -13))
                result.append(DicdataElement(ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14))
            }
        }

        // 入力を全てひらがな、カタカナに変換したものを候補に追加する
        if convertTarget.count == 1 {
            let katakana = convertTarget.toKatakana()
            let hiragana = convertTarget.toHiragana()
            if convertTarget == katakana {
                result.append(DicdataElement(ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14))
            } else {
                result.append(DicdataElement(word: hiragana, ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -13))
                result.append(DicdataElement(ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14))
            }
        }

        // 記号変換
        if convertTarget.count == 1, let first = convertTarget.first {
            var value: PValue = -14
            let hs = Self.fullwidthToHalfwidth[first, default: first]

            if hs != first {
                result.append(DicdataElement(word: convertTarget, ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
                result.append(DicdataElement(word: String(hs), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
            }
            if let fs = Self.halfwidthToFullwidth[first], fs != first {
                result.append(DicdataElement(word: convertTarget, ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
                result.append(DicdataElement(word: String(fs), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
            }
            for group in Self.weakRelatingSymbolGroups where group.contains(hs) {
                for symbol in group where symbol != hs {
                    result.append(DicdataElement(word: String(symbol), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                    value -= 5.0
                    if let fs = Self.halfwidthToFullwidth[symbol] {
                        result.append(DicdataElement(word: String(fs), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                        value -= 5.0
                    }
                }
            }
        }
        return result
    }

    // 記号に対する半角・全角変換
    private static let (fullwidthToHalfwidth, halfwidthToFullwidth) = zip(
        "＋ー＊＝・！＃％＆＇＂〜｜￡＄￥＠｀；：＜＞，．＼／＿￣－",
        "＋ー＊＝・！＃％＆＇＂〜｜￡＄￥＠｀；：＜＞，．＼／＿￣－".applyingTransform(.fullwidthToHalfwidth, reverse: false)!
    )
    .reduce(into: ([Character: Character](), [Character: Character]())) { (results: inout ([Character: Character], [Character: Character]), values: (Character, Character)) in
        results.0[values.0] = values.1
        results.1[values.1] = values.0
    }

    // 弱い類似(矢印同士のような関係)にある記号をグループにしたもの
    // 例えば→に対して⇒のような記号はより類似度が強いため、上位に出したい。これを実現する必要が生じた場合はstrongRelatingSymbolGroupsを新設する。
    // 宣言順不同
    // 1つを入れると他が出る、というイメージ
    // 半角と全角がある場合は半角のみ
    private static let weakRelatingSymbolGroups: [[Character]] = [
        // 異体字セレクト用 (試験実装)
        ["高", "髙"], // ハシゴダカ
        ["斎", "斉", "齋", "齊"],
        ["澤", "沢"],
        ["気", "氣"],
        ["澁", "渋"],
        ["対", "對"],
        ["辻", "辻󠄀"],
        ["禰󠄀", "禰"],
        ["煉󠄁", "煉"],
        ["崎", "﨑"], // タツザキ
        ["栄", "榮"],
        ["吉", "𠮷"], // ツチヨシ
        ["橋", "𣘺", "槗", "𫞎"],
        ["浜", "濱", "濵"],
        ["鴎", "鷗"],
        ["学", "學"],
        ["角", "⻆"],
        ["亀", "龜"],
        ["桜", "櫻"],
        ["真", "眞"],

        // 記号変換
        ["☆", "★", "♡", "☾", "☽"],  // 星
        ["^", "＾"],  // ハット
        ["¥", "$", "¢", "€", "£", "₿"], // 通貨
        ["%", "‰"], // パーセント
        ["°", "℃", "℉"],
        ["◯"], // 図形
        ["*", "※", "✳︎", "✴︎"],   // こめ
        ["・", "…", "‥", "•"],
        ["+", "±", "⊕"],
        ["×", "❌", "✖️"],
        ["÷", "➗" ],
        ["<", "≦", "≪", "〈", "《", "‹", "«"],
        [">", "≧", "≫", "〉", "》", "›", "»"],
        ["=", "≒", "≠", "≡"],
        [":", ";"],
        ["!", "❗️", "❣️", "‼︎", "⁉︎", "❕", "‼️", "⁉️", "¡"],
        ["?", "❓", "⁉︎", "⁇", "❔", "⁉️", "¿"],
        ["〒", "〠", "℡", "☎︎"],
        ["々", "ヾ", "ヽ", "ゝ", "ゞ", "〃", "仝", "〻"],
        ["〆", "〼", "ゟ", "ヿ"], // 特殊仮名
        ["♂", "♀", "⚢", "⚣", "⚤", "⚥", "⚦", "⚧", "⚨", "⚩", "⚪︎", "⚲"], // ジェンダー記号
        ["→", "↑", "←", "↓", "↙︎", "↖︎", "↘︎", "↗︎", "↔︎", "↕︎", "↪︎", "↩︎", "⇆"], // 矢印
        ["♯", "♭", "♪", "♮", "♫", "♬", "♩", "𝄞", "𝄞"],  // 音符
        ["√", "∛", "∜"]  // 根号
    ]

    private func loadCCBinary(url: URL) -> [(Int32, Float)] {
        do {
            let binaryData = try Data(contentsOf: url, options: [.uncached])
            return binaryData.toArray(of: (Int32, Float).self)
        } catch {
            debug("Error: 品詞連接コストデータの読み込みに失敗しました。このエラーは深刻ですが、テスト時には無視できる場合があります。 Description: \(error.localizedDescription)")
            return []
        }
    }

    /// 動的ユーザ辞書からrubyに等しい語を返す。
    func getMatchDynamicUserDict(_ ruby: some StringProtocol) -> [DicdataElement] {
        self.dynamicUserDict.filter {$0.ruby == ruby}
    }

    /// 動的ユーザ辞書からrubyに先頭一致する語を返す。
    func getPrefixMatchDynamicUserDict(_ ruby: some StringProtocol) -> [DicdataElement] {
        self.dynamicUserDict.filter {$0.ruby.hasPrefix(ruby)}
    }

    // 学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with previous: DicdataElement?) {
        if let previous {
            self.learningManager.update(data: [previous] + candidate.data)
        } else {
            self.learningManager.update(data: candidate.data)
        }
    }
    // 予測変換に基づいて学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        switch predictionCandidate.type {
        case .additional(data: let data):
            self.learningManager.update(data: candidate.data, updatePart: data)
        case .replacement(targetData: let targetData, replacementData: let replacementData):
            self.learningManager.update(data: candidate.data.dropLast(targetData.count), updatePart: replacementData)
        }
    }
    /// class idから連接確率を得る関数
    /// - Parameters:
    ///   - former: 左側の語のid
    ///   - latter: 右側の語のid
    /// - Returns:
    ///   連接確率の対数。
    /// - 要求があった場合ごとにファイルを読み込んで
    /// 速度: ⏱0.115224 : 変換_処理_連接コスト計算_CCValue
    public func getCCValue(_ former: Int, _ latter: Int) -> PValue {
        if !ccParsed[former] {
            let url = requestOptions.dictionaryResourceURL.appendingPathComponent("cb/\(former).binary", isDirectory: false)
            let values = loadCCBinary(url: url)
            ccLines[former] = [Int: PValue].init(uniqueKeysWithValues: values.map {(Int($0.0), PValue($0.1))})
            ccParsed[former] = true
        }
        let defaultValue = ccLines[former][-1, default: -25]
        return ccLines[former][latter, default: defaultValue]
    }

    /// meaning idから意味連接尤度を得る関数
    /// - Parameters:
    ///   - former: 左側の語のid
    ///   - latter: 右側の語のid
    /// - Returns:
    ///   意味連接確率の対数。
    /// - 要求があった場合ごとに確率値をパースして取得する。
    public func getMMValue(_ former: Int, _ latter: Int) -> PValue {
        if former == 500 || latter == 500 {
            return 0
        }
        return self.mmValue[former * self.midCount + latter]
    }

    private static let possibleLOUDS: Set<Character> = [
        "　", "￣", "‐", "―", "〜", "・", "、", "…", "‥", "。", "‘", "’", "“", "”", "〈", "〉", "《", "》", "「", "」", "『", "』", "【", "】", "〔", "〕", "‖", "*", "′", "〃", "※", "´", "¨", "゛", "゜", "←", "→", "↑", "↓", "─", "■", "□", "▲", "△", "▼", "▽", "◆", "◇", "○", "◎", "●", "★", "☆", "々", "ゝ", "ヽ", "ゞ", "ヾ", "ー", "〇", "ァ", "ア", "ィ", "イ", "ゥ", "ウ", "ヴ", "ェ", "エ", "ォ", "オ", "ヵ", "カ", "ガ", "キ", "ギ", "ク", "グ", "ヶ", "ケ", "ゲ", "コ", "ゴ", "サ", "ザ", "シ", "ジ", "〆", "ス", "ズ", "セ", "ゼ", "ソ", "ゾ", "タ", "ダ", "チ", "ヂ", "ッ", "ツ", "ヅ", "テ", "デ", "ト", "ド", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "バ", "パ", "ヒ", "ビ", "ピ", "フ", "ブ", "プ", "ヘ", "ベ", "ペ", "ホ", "ボ", "ポ", "マ", "ミ", "ム", "メ", "モ", "ヤ", "ユ", "ョ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ヮ", "ワ", "ヰ", "ヱ", "ヲ", "ン", "仝", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "！", "？", "(", ")", "#", "%", "&", "^", "_", "'", "\""
    ]

    // 誤り訂正候補の構築の際、ファイルが存在しているか事前にチェックし、存在していなければ以後の計算を打ち切ることで、計算を減らす。
    static func existLOUDS(for character: Character) -> Bool {
        Self.possibleLOUDS.contains(character)
    }

    /*
     文節の切れ目とは

     * 後置機能語→前置機能語
     * 後置機能語→内容語
     * 内容語→前置機能語
     * 内容語→内容語

     となる。逆に文節の切れ目にならないのは

     * 前置機能語→内容語
     * 内容語→後置機能語

     の二通りとなる。

     */
    /// class idから、文節かどうかを判断する関数。
    /// - Parameters:
    ///   - c_former: 左側の語のid
    ///   - c_latter: 右側の語のid
    /// - Returns:
    ///   そこが文節の境界であるかどうか。
    @inlinable static func isClause(_ former: Int, _ latter: Int) -> Bool {
        // EOSが基本多いので、この順の方がヒット率が上がると思われる。
        let latter_wordtype = Self.wordTypes[latter]
        if latter_wordtype == 3 {
            return false
        }
        let former_wordtype = Self.wordTypes[former]
        if former_wordtype == 3 {
            return false
        }
        if latter_wordtype == 0 {
            return former_wordtype != 0
        }
        if latter_wordtype == 1 {
            return former_wordtype != 0
        }
        return false
    }

    /// wordTypesの初期化時に使うのみ。
    private static let BOS_EOS_wordIDs: Set<Int> = [CIDData.BOS.cid, CIDData.EOS.cid]
    /// wordTypesの初期化時に使うのみ。
    private static let PREPOSITION_wordIDs: Set<Int> = [1315, 6, 557, 558, 559, 560]
    /// wordTypesの初期化時に使うのみ。
    private static let INPOSITION_wordIDs: Set<Int> = Set<Int>(
        Array(561..<868).chained(1283..<1297).chained(1306..<1310).chained(11..<53).chained(555..<557).chained(1281..<1283)
    ).union([1314, 3, 2, 4, 5, 1, 9])

    /*
     private static let POSTPOSITION_wordIDs: Set<Int> = Set<Int>((7...8).map{$0}
     + (54..<555).map{$0}
     + (868..<1281).map{$0}
     + (1297..<1306).map{$0}
     + (1310..<1314).map{$0}
     ).union([10])
     */

    /// - Returns:
    ///   - 3 when BOS/EOS
    ///   - 0 when preposition
    ///   - 1 when core
    ///   - 2 when postposition
    /// - データ1つあたり1Bなので、1.3KBくらいのメモリを利用する。
    public static let wordTypes = (0...1319).map(_judgeWordType)

    /// wordTypesの初期化時に使うのみ。
    private static func _judgeWordType(cid: Int) -> UInt8 {
        if Self.BOS_EOS_wordIDs.contains(cid) {
            return 3    // BOS/EOS
        }
        if Self.PREPOSITION_wordIDs.contains(cid) {
            return 0    // 前置
        }
        if Self.INPOSITION_wordIDs.contains(cid) {
            return 1 // 内容
        }
        return 2   // 後置
    }

    @inlinable static func includeMMValueCalculation(_ data: DicdataElement) -> Bool {
        // 非自立動詞
        if 895...1280 ~= data.lcid || 895...1280 ~= data.rcid {
            return true
        }
        // 非自立名詞
        if 1297...1305 ~= data.lcid || 1297...1305 ~= data.rcid {
            return true
        }
        // 内容語かどうか
        return wordTypes[data.lcid] == 1 || wordTypes[data.rcid] == 1
    }

    /// - データ1つあたり2Bなので、2.6KBくらいのメモリを利用する。
    static let penaltyRatio = (0...1319).map(_getTypoPenaltyRatio)

    /// penaltyRatioの初期化時に使うのみ。
    static func _getTypoPenaltyRatio(_ lcid: Int) -> PValue {
        // 助詞147...368, 助動詞369...554
        if 147...554 ~= lcid {
            return 2.5
        }
        return 1
    }

    /// 予測変換で終端になれない品詞id
    static let predictionUsable = (0...1319).map(_getPredictionUsable)
    /// penaltyRatioの初期化時に使うのみ。
    static func _getPredictionUsable(_ rcid: Int) -> Bool {
        // 連用タ接続
        // 次のコマンドにより機械的に生成`cat cid.txt | grep 連用タ | awk '{print $1}' | xargs -I {} echo -n "{}, "`
        if Set([33, 34, 50, 86, 87, 88, 103, 127, 128, 144, 397, 398, 408, 426, 427, 450, 457, 480, 687, 688, 703, 704, 727, 742, 750, 758, 766, 786, 787, 798, 810, 811, 829, 830, 831, 893, 973, 974, 975, 976, 977, 1007, 1008, 1009, 1010, 1063, 1182, 1183, 1184, 1185, 1186, 1187, 1188, 1189, 1190, 1191, 1192, 1193, 1194, 1240, 1241, 1242, 1243, 1268, 1269, 1270, 1271]).contains(rcid) {
            return false
        }
        // 仮定縮約
        // cat cid.txt | grep 仮定縮約 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([15, 16, 17, 18, 41, 42, 59, 60, 61, 62, 63, 64, 94, 95, 109, 110, 111, 112, 135, 136, 379, 380, 381, 382, 402, 412, 413, 442, 443, 471, 472, 562, 572, 582, 591, 598, 618, 627, 677, 678, 693, 694, 709, 710, 722, 730, 737, 745, 753, 761, 770, 771, 791, 869, 878, 885, 896, 906, 917, 918, 932, 948, 949, 950, 951, 952, 987, 988, 989, 990, 1017, 1018, 1033, 1034, 1035, 1036, 1058, 1078, 1079, 1080, 1081, 1082, 1083, 1084, 1085, 1086, 1087, 1088, 1089, 1090, 1212, 1213, 1214, 1215]).contains(rcid) {
            return false
        }
        // 未然形
        // cat cid.txt | grep 未然形 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([372, 406, 418, 419, 431, 437, 438, 455, 462, 463, 464, 495, 496, 504, 533, 534, 540, 551, 567, 577, 587, 595, 606, 614, 622, 630, 641, 647, 653, 659, 665, 672, 683, 684, 699, 700, 715, 716, 725, 733, 740, 748, 756, 764, 780, 781, 794, 806, 807, 823, 824, 825, 837, 842, 847, 852, 859, 865, 873, 881, 890, 901, 911, 925, 935, 963, 964, 965, 966, 967, 999, 1000, 1001, 1002, 1023, 1024, 1045, 1046, 1047, 1048, 1061, 1143, 1144, 1145, 1146, 1147, 1148, 1149, 1150, 1151, 1152, 1153, 1154, 1155, 1224, 1225, 1226, 1227, 1260, 1261, 1262, 1263, 1278]).contains(rcid) {
            return false
        }
        // 未然特殊
        // cat cid.txt | grep 未然特殊 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([420, 421, 631, 782, 783, 795, 891, 936, 1156, 1157, 1158, 1159, 1160, 1161, 1162, 1163, 1164, 1165, 1166, 1167, 1168, 1228, 1229, 1230, 1231]).contains(rcid) {
            return false
        }
        // 未然ウ接続
        // cat cid.txt | grep 未然ウ接続 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([25, 26, 46, 74, 75, 76, 99, 119, 120, 140, 389, 390, 405, 416, 417, 447, 476, 493, 494, 566, 576, 585, 594, 603, 621, 629, 671, 681, 682, 697, 698, 713, 714, 724, 732, 739, 747, 755, 763, 778, 779, 793, 804, 805, 820, 821, 822, 872, 880, 889, 900, 910, 923, 924, 934, 958, 959, 960, 961, 962, 995, 996, 997, 998, 1021, 1022, 1041, 1042, 1043, 1044, 1060, 1130, 1131, 1132, 1133, 1134, 1135, 1136, 1137, 1138, 1139, 1140, 1141, 1142, 1220, 1221, 1222, 1223, 1256, 1257, 1258, 1259]).contains(rcid) {
            return false
        }
        // 未然ヌ接続
        // cat cid.txt | grep 未然ヌ接続 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([27, 28, 47, 77, 78, 79, 100, 121, 122, 141, 391, 392, 448, 477, 604]).contains(rcid) {
            return false
        }
        // 体言接続特殊
        // cat cid.txt | grep 体言接続特殊 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([404, 564, 565, 574, 575, 600, 601, 620, 774, 775, 776, 777, 871, 887, 888, 898, 899, 908, 909, 921, 922, 1104, 1105, 1106, 1107, 1108, 1109, 1110, 1111, 1112, 1113, 1114, 1115, 1116, 1117, 1118, 1119, 1120, 1121, 1122, 1123, 1124, 1125, 1126, 1127, 1128, 1129]).contains(rcid) {
            return false
        }
        // 仮定形
        // cat cid.txt | grep 仮定形 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([13, 14, 40, 56, 57, 58, 93, 107, 108, 134, 369, 377, 378, 401, 410, 411, 433, 434, 441, 452, 470, 483, 489, 490, 527, 528, 537, 542, 548, 561, 571, 581, 590, 597, 611, 617, 626, 636, 638, 644, 650, 656, 662, 668, 675, 676, 691, 692, 707, 708, 721, 729, 736, 744, 752, 760, 768, 769, 790, 800, 801, 814, 815, 816, 835, 840, 845, 850, 855, 862, 868, 877, 884, 895, 905, 915, 916, 931, 941, 943, 944, 945, 946, 947, 983, 984, 985, 986, 1015, 1016, 1029, 1030, 1031, 1032, 1057, 1065, 1066, 1067, 1068, 1069, 1070, 1071, 1072, 1073, 1074, 1075, 1076, 1077, 1208, 1209, 1210, 1211, 1248, 1249, 1250, 1251, 1276]).contains(rcid) {
            return false
        }
        // 「食べよ」のような命令形も除外する
        // 命令ｙｏ
        // cat cid.txt | grep 命令ｙｏ | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([373, 553, 569, 579, 589, 596, 609, 624, 634, 642, 648, 654, 660, 666, 673, 860, 866, 875, 903, 913, 928, 929, 939]).contains(rcid) {
            return false
        }
        return true
    }

    // 学習を有効にする語彙を決める。
    @inlinable static func needWValueMemory(_ data: DicdataElement) -> Bool {
        // 助詞、助動詞
        if 147...554 ~= data.lcid {
            return false
        }
        // 接頭辞
        if 557...560 ~= data.lcid {
            return false
        }
        // 接尾名詞を除去
        if 1297...1305 ~= data.lcid {
            return false
        }
        // 記号を除去
        if 6...9 ~= data.lcid {
            return false
        }
        if 0 == data.lcid || 1316 == data.lcid {
            return false
        }

        return true
    }

    static let possibleNexts: [String: [String]] = [
        "x": ["ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ"],
        "l": ["ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ"],
        "xt": ["ッ"],
        "lt": ["ッ"],
        "xts": ["ッ"],
        "lts": ["ッ"],
        "xy": ["ャ", "ュ", "ョ"],
        "ly": ["ャ", "ュ", "ョ"],
        "xw": ["ヮ"],
        "lw": ["ヮ"],
        "v": ["ヴ"],
        "k": ["カ", "キ", "ク", "ケ", "コ"],
        "q": ["クァ", "クィ", "クゥ", "クェ", "クォ"],
        "qy": ["クャ", "クィ", "クュ", "クェ", "クョ"],
        "qw": ["クヮ", "クィ", "クゥ", "クェ", "クォ"],
        "ky": ["キャ", "キィ", "キュ", "キェ", "キョ"],
        "g": ["ガ", "ギ", "グ", "ゲ", "ゴ"],
        "gy": ["ギャ", "ギィ", "ギュ", "ギェ", "ギョ"],
        "s": ["サ", "シ", "ス", "セ", "ソ"],
        "sy": ["シャ", "シィ", "シュ", "シェ", "ショ"],
        "sh": ["シャ", "シィ", "シュ", "シェ", "ショ"],
        "z": ["ザ", "ジ", "ズ", "ゼ", "ゾ"],
        "zy": ["ジャ", "ジィ", "ジュ", "ジェ", "ジョ"],
        "j": ["ジ"],
        "t": ["タ", "チ", "ツ", "テ", "ト"],
        "ty": ["チャ", "チィ", "チュ", "チェ", "チョ"],
        "ts": ["ツ"],
        "th": ["テャ", "ティ", "テュ", "テェ", "テョ"],
        "tw": ["トァ", "トィ", "トゥ", "トェ", "トォ"],
        "cy": ["チャ", "チィ", "チュ", "チェ", "チョ"],
        "ch": ["チ"],
        "d": ["ダ", "ヂ", "ヅ", "デ", "ド"],
        "dy": ["ヂャ", "ヂィ", "ヂュ", "ヂェ", "ヂョ"],
        "dh": ["デャ", "ディ", "デュ", "デェ", "デョ"],
        "dw": ["ドァ", "ドィ", "ドゥ", "ドェ", "ドォ"],
        "n": ["ナ", "ニ", "ヌ", "ネ", "ノ", "ン"],
        "ny": ["ニャ", "ニィ", "ニュ", "ニェ", "ニョ"],
        "h": ["ハ", "ヒ", "フ", "ヘ", "ホ"],
        "hy": ["ヒャ", "ヒィ", "ヒュ", "ヒェ", "ヒョ"],
        "hw": ["ファ", "フィ", "フェ", "フォ"],
        "f": ["フ"],
        "b": ["バ", "ビ", "ブ", "ベ", "ボ"],
        "by": ["ビャ", "ビィ", "ビュ", "ビェ", "ビョ"],
        "p": ["パ", "ピ", "プ", "ペ", "ポ"],
        "py": ["ピャ", "ピィ", "ピュ", "ピェ", "ピョ"],
        "m": ["マ", "ミ", "ム", "メ", "モ"],
        "my": ["ミャ", "ミィ", "ミュ", "ミェ", "ミョ"],
        "y": ["ヤ", "ユ", "イェ", "ヨ"],
        "r": ["ラ", "リ", "ル", "レ", "ロ"],
        "ry": ["リャ", "リィ", "リュ", "リェ", "リョ"],
        "w": ["ワ", "ウィ", "ウェ", "ヲ"],
        "wy": ["ヰ", "ヱ"]
    ]
}
