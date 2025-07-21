import SwiftUtils

struct TypoCorrectionGenerator: Sendable {
    init(inputs: [ComposingText.InputElement], range: ProcessRange, needTypoCorrection: Bool) {
        self.maxPenalty = needTypoCorrection ? 3.5 * 3 : 0
        self.inputs = inputs
        self.range = range

        let count = self.range.rightIndexRange.endIndex - range.leftIndex
        self.count = count
        self.nodes = (0..<count).map {(i: Int) in
            Self.lengths.flatMap {(k: Int) -> [TypoCandidate] in
                let j = i + k
                if count <= j {
                    return []
                }
                return Self.getTypo(inputs[range.leftIndex + i ... range.leftIndex + j], frozen: !needTypoCorrection)
            }
        }
        // 深さ優先で列挙する
        var leftConvertTargetElements: [ComposingText.ConvertTargetElement] = []
        for element in inputs[0 ..< range.leftIndex] {
            ComposingText.updateConvertTargetElements(currentElements: &leftConvertTargetElements, newElement: element)
        }
        let actualLeftConvertTarget = leftConvertTargetElements.reduce(into: "") { $0 += $1.string}

        self.stack = nodes[0].compactMap { typoCandidate in
            guard let firstElement = typoCandidate.inputElements.first else {
                return nil
            }
            var convertTargetElements = [ComposingText.ConvertTargetElement]()
            var leftElements = leftConvertTargetElements
            for element in typoCandidate.inputElements {
                ComposingText.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
                ComposingText.updateConvertTargetElements(currentElements: &leftElements, newElement: element)
            }
            let newFullConvertTarget = leftElements.reduce(into: "") { $0 += $1.string}
            let convertTarget = convertTargetElements.reduce(into: "") { $0 += $1.string}

            return if newFullConvertTarget == actualLeftConvertTarget + convertTarget {
                (convertTargetElements, typoCandidate.inputElements.last!, typoCandidate.inputElements.count, typoCandidate.weight)
            } else {
                nil
            }
        }
    }

    let maxPenalty: PValue
    let inputs: [ComposingText.InputElement]
    let range: ProcessRange
    let nodes: [[TypoCandidate]]
    let count: Int

    struct ProcessRange: Sendable, Equatable {
        var leftIndex: Int
        var rightIndexRange: Range<Int>
    }

    var stack: [(convertTargetElements: [ComposingText.ConvertTargetElement], lastElement: ComposingText.InputElement, count: Int, penalty: PValue)]

    /// `target`で始まる場合は到達不可能であることを知らせる
    mutating func setUnreachablePath(target: some Collection<Character>) {
        self.stack = self.stack.filter { (convertTargetElements, lastElement, count, penalty) in
            var stablePrefix: [Character] = []
            loop: for item in convertTargetElements {
                switch item.inputStyle {
                case .direct:
                    stablePrefix.append(contentsOf: item.string)
                case .roman2kana:
                    var stableIndex = item.string.endIndex
                    for suffix in Roman2Kana.unstableSuffixes {
                        if item.string.hasSuffix(suffix) {
                            stableIndex = min(stableIndex, item.string.endIndex - suffix.count)
                        }
                    }
                    if stableIndex == item.string.endIndex {
                        stablePrefix.append(contentsOf: item.string)
                    } else {
                        // 全体が安定でない場合は、そこでbreakする
                        stablePrefix.append(contentsOf: item.string[0 ..< stableIndex])
                        break loop
                    }
                }
                // 安定なprefixがtargetをprefixに持つ場合、このstack内のアイテムについてもunreachableであることが分かるので、除去する
                if stablePrefix.hasPrefix(target) {
                    return false
                }
            }
            return true
        }
    }

    mutating func next() -> ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))? {
        while let (convertTargetElements, lastElement, count, penalty) = self.stack.popLast() {
            var result: ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))? = nil
            if self.range.rightIndexRange.contains(count + self.range.leftIndex - 1) {
                if let convertTarget = ComposingText.getConvertTargetIfRightSideIsValid(lastElement: lastElement, of: inputs, to: count + self.range.leftIndex, convertTargetElements: convertTargetElements)?.map({$0.toKatakana()}) {
                    result = (convertTarget, (.input(count + self.range.leftIndex - 1), penalty))
                }
            }
            // エスケープ
            if self.nodes.endIndex <= count {
                if let result {
                    return result
                } else {
                    continue
                }
            }
            // 訂正数上限(3個)
            if penalty >= maxPenalty {
                var convertTargetElements = convertTargetElements
                let correct = [inputs[self.range.leftIndex + count]].map {ComposingText.InputElement(character: $0.character.toKatakana(), inputStyle: $0.inputStyle)}
                if count + correct.count > self.nodes.endIndex {
                    if let result {
                        return result
                    } else {
                        continue
                    }
                }
                for element in correct {
                    ComposingText.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
                }
                stack.append((convertTargetElements, correct.last!, count + correct.count, penalty))
            } else {
                stack.append(contentsOf: self.nodes[count].compactMap {
                    if count + $0.inputElements.count > self.nodes.endIndex {
                        return nil
                    }
                    var convertTargetElements = convertTargetElements
                    for element in $0.inputElements {
                        ComposingText.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
                    }
                    return (
                        convertTargetElements: convertTargetElements,
                        lastElement: $0.inputElements.last!,
                        count: count + $0.inputElements.count,
                        penalty: penalty + $0.weight
                    )
                })
            }
            // このループで出力すべきものがある場合は出力する（yield）
            if let result {
                return result
            }
        }
        return nil
    }

    fileprivate static func getTypo(_ elements: some Collection<ComposingText.InputElement>, frozen: Bool = false) -> [TypoCandidate] {
        let key = elements.reduce(into: "") {$0.append($1.character.toKatakana())}

        if (elements.allSatisfy {$0.inputStyle == .direct}) {
            let dictionary: [String: [TypoCandidate]] = frozen ? [:] : Self.directPossibleTypo
            if key.count > 1 {
                return dictionary[key, default: []]
            } else if key.count == 1 {
                var result = dictionary[key, default: []]
                // そのまま
                result.append(TypoCandidate(inputElements: key.map {ComposingText.InputElement(character: $0, inputStyle: .direct)}, weight: 0))
                return result
            }
        }
        if (elements.allSatisfy {$0.inputStyle == .roman2kana}) {
            let dictionary: [String: [TypoCandidate]] = frozen ? [:] : Self.roman2KanaPossibleTypo
            if key.count > 1 {
                return dictionary[key, default: []]
            } else if key.count == 1 {
                var result = dictionary[key, default: []]
                // そのまま
                result.append(
                    TypoCandidate(inputElements: key.map {ComposingText.InputElement(character: $0, inputStyle: .roman2kana)}, weight: 0)
                )
                return result
            }
        }
        return []
    }

    fileprivate static let lengths = [0, 1]

    private struct TypoUnit: Equatable {
        var value: String
        var weight: PValue

        init(_ value: String, weight: PValue = 3.5) {
            self.value = value
            self.weight = weight
        }
    }

    struct TypoCandidate: Sendable, Equatable {
        var inputElements: [ComposingText.InputElement]
        var weight: PValue
    }

    /// ダイレクト入力用
    private static let directPossibleTypo: [String: [TypoCandidate]] = [
        "カ": [TypoUnit("ガ", weight: 7.0)],
        "キ": [TypoUnit("ギ")],
        "ク": [TypoUnit("グ")],
        "ケ": [TypoUnit("ゲ")],
        "コ": [TypoUnit("ゴ")],
        "サ": [TypoUnit("ザ")],
        "シ": [TypoUnit("ジ")],
        "ス": [TypoUnit("ズ")],
        "セ": [TypoUnit("ゼ")],
        "ソ": [TypoUnit("ゾ")],
        "タ": [TypoUnit("ダ", weight: 6.0)],
        "チ": [TypoUnit("ヂ")],
        "ツ": [TypoUnit("ッ", weight: 6.0), TypoUnit("ヅ", weight: 4.5)],
        "テ": [TypoUnit("デ", weight: 6.0)],
        "ト": [TypoUnit("ド", weight: 4.5)],
        "ハ": [TypoUnit("バ", weight: 4.5), TypoUnit("パ", weight: 6.0)],
        "ヒ": [TypoUnit("ビ"), TypoUnit("ピ", weight: 4.5)],
        "フ": [TypoUnit("ブ"), TypoUnit("プ", weight: 4.5)],
        "ヘ": [TypoUnit("ベ"), TypoUnit("ペ", weight: 4.5)],
        "ホ": [TypoUnit("ボ"), TypoUnit("ポ", weight: 4.5)],
        "バ": [TypoUnit("パ")],
        "ビ": [TypoUnit("ピ")],
        "ブ": [TypoUnit("プ")],
        "ベ": [TypoUnit("ペ")],
        "ボ": [TypoUnit("ポ")],
        "ヤ": [TypoUnit("ャ")],
        "ユ": [TypoUnit("ュ")],
        "ヨ": [TypoUnit("ョ")]
    ].mapValues {
        $0.map {
            TypoCandidate(
                inputElements: $0.value.map {ComposingText.InputElement(character: $0, inputStyle: .direct)},
                weight: $0.weight
            )
        }
    }

    private static let roman2KanaPossibleTypo: [String: [TypoCandidate]] = [
        "bs": ["ba"],
        "no": ["bo"],
        "li": ["ki"],
        "lo": ["ko"],
        "lu": ["ku"],
        "my": ["mu"],
        "tp": ["to"],
        "ts": ["ta"],
        "wi": ["wo"],
        "pu": ["ou"]
    ].mapValues {
        $0.map {
            TypoCandidate(
                inputElements: $0.map {ComposingText.InputElement(character: $0, inputStyle: .roman2kana)},
                weight: 3.5
            )
        }
    }
}
