//
//  ComposingText.swift
//  Keyboard
//
//  Created by ensan on 2022/09/21.
//  Copyright © 2022 ensan. All rights reserved.
//

import Foundation
import SwiftUtils

/// ユーザ入力、変換対象文字列、ディスプレイされる文字列、の3つを同時にハンドルするための構造体
///  - `input`: `[k, y, o, u, h, a, a, m, e]`
///  - `convertTarget`: `きょうはあめ`
/// のようになる。`
/// カーソルのポジションもこのクラスが管理する。
/// 設計方針として、inputStyleに関わる実装の違いは全てアップデート方法の違いとして吸収し、`input` / `delete` / `moveCursor` / `complete`時の違いとしては露出させないようにすることを目指した。
public struct ComposingText: Sendable {
    public init(convertTargetCursorPosition: Int = 0, input: [ComposingText.InputElement] = [], convertTarget: String = "") {
        self.convertTargetCursorPosition = convertTargetCursorPosition
        self.input = input
        self.convertTarget = convertTarget
    }

    /// カーソルの位置。0は左端（左から右に書く言語の場合）に対応する。
    public private(set) var convertTargetCursorPosition: Int = 0
    /// ユーザの入力シーケンス。historyとは異なり、変換対象文字列に対応するものを保持する。また、deleteやmove cursor等の操作履歴は保持しない。
    public private(set) var input: [InputElement] = []
    /// 変換対象文字列。
    public private(set) var convertTarget: String = ""

    /// ユーザ入力の単位
    public struct InputElement: Sendable {
        /// 入力された要素
        public var piece: InputPiece
        /// そのときの入力方式(ローマ字入力 / ダイレクト入力)
        public var inputStyle: InputStyle

        public init(piece: InputPiece, inputStyle: InputStyle) {
            self.piece = piece
            self.inputStyle = inputStyle
        }

        public init(character: Character, inputStyle: InputStyle) {
            self.init(piece: .character(character), inputStyle: inputStyle)
        }
    }

    /// 変換対象文字列が存在するか否か
    public var isEmpty: Bool {
        self.convertTarget.isEmpty
    }

    /// カーソルが右端に存在するか
    public var isAtEndIndex: Bool {
        self.convertTarget.count == self.convertTargetCursorPosition
    }

    /// カーソルが左端に存在するか
    public var isAtStartIndex: Bool {
        0 == self.convertTargetCursorPosition
    }

    /// カーソルより前の変換対象
    public var convertTargetBeforeCursor: some StringProtocol {
        self.convertTarget.prefix(self.convertTargetCursorPosition)
    }

    /// `targetSurfaceIndex`に対応するinputの位置を無理やり作り出す関数
    /// 例えば`input`が`[k, y, o, u]`で`targetSurfaceIndex`が`2`の場合を考える。
    /// この状態では`input`に対応するカーソル位置が存在しない。
    /// この場合、`input`を`[き, ょ, u]`と置き換えた上で、`き|`と考えて、`1`を返す。
    private mutating func forceGetInputCursorPosition(targetSurfaceIndex: Int) -> Int {
        debug(#function, self, targetSurfaceIndex)
        if targetSurfaceIndex <= 0 {
            return 0
        } else if targetSurfaceIndex >= self.convertTarget.count {
            return self.input.count
        }
        // 動作例1
        // input: `k, a, n, s, h, a` (全てroman2kana)
        // convertTarget: `か ん し| ゃ`
        // targetSurfaceIndex: 3
        // 動作
        // 1. character = "k"
        //    roman2kana = "k"
        //    independentSegment = [k]
        // 2. character = "a"
        //    roman2kana = "か"
        //    independentSegment = [ka]
        //    target.hasPrefix(roman2kana)がtrueなので、lastPrefixIndex = 2, lastPrefix = "か"
        // 3. character = "n"
        //    roman2kana = "かn"
        //    independentSegment = [ka, n]
        // 4. character = "s"
        //    roman2kana = "かんs"
        //    independentSegment = [ka, ns]
        // 5. character = "h"
        //    roman2kana = "かんsh"
        //    independentSegment = [ka, ns, h]
        // 6. character = "a"
        //    roman2kana = "かんしゃ"
        //    independentSegment = [ka, nsha]
        //    `か`,`んしゃ`はそれぞれを編集しても他方に影響を与える可能性がないセグメント;独立セグメント
        //    targetSurfaceIndex = 3なので、3文字めが含まれる独立セグメント`んしゃ`を削除
        //    input = [k, a]
        //    `nsha`がひらがなに変換され、`ん,し,ゃ`が追加される
        //    input = [k, a, ん, し, ゃ]

        // inputとsurfaceのインデックスの対応関係
        struct SegmentIndex {
            let inputIndex: Int
            let surfaceIndex: Int
        }

        // 独立なセグメントの境界を保持するリスト
        var independentSegmentBoundaries = [SegmentIndex(inputIndex: 0, surfaceIndex: 0)]

        var converting: [ConvertTargetElement] = []
        var convertedLength = 0

        // 独立なセグメントの境界リストを作成する
        for (currentInputIndex, element) in input.enumerated() {
            let deletedCount = Self.updateConvertTargetElementsWithDeletedCount(currentElements: &converting, newElement: element)
            // 今回の文字入力による変換が、前の暫定独立セグメントの文字を含むテーブルエントリによって行われた場合
            // 新セグメントは前のセグメントに依存しているので、ここで前のセグメントとの境界を消すことで、新しい独立セグメントをつくる
            while let lastIndependentSegment =  independentSegmentBoundaries.popLast() {
                // deletedCountは、現在の文字を入力した際に関連(依存)した文字列の長さ
                if lastIndependentSegment.surfaceIndex <= convertedLength - deletedCount {
                    // これ以上前のセグメントには依存していないので一度消した境界を戻す
                    independentSegmentBoundaries.append(lastIndependentSegment)
                    break
                }
            }
            // 現在の終端をセグメント境界と仮定する
            // 上のwhileループで依存関係が発覚した場合は削除される
            convertedLength = converting.reduce(0) { $0 + $1.string.count }
            independentSegmentBoundaries.append(
                SegmentIndex(inputIndex: currentInputIndex + 1, surfaceIndex: convertedLength)
            )
        }

        let convertedChars = converting.reduce(into: [Character]()) { $0 += $1.string }
        // カーソルが含まれるセグメントの始点と終点
        var cursorSegmentEnd = SegmentIndex(inputIndex: self.input.count, surfaceIndex: convertedChars.count)
        var cursorSegmentStart = SegmentIndex(inputIndex: 0, surfaceIndex: 0)

        // カーソルが含まれる独立セグメントを探す
        while let independentStart = independentSegmentBoundaries.popLast() {
            if independentStart.surfaceIndex == targetSurfaceIndex {
                // カーソルが独立セグメントの間にあり置換処理が必要ない
                return independentStart.inputIndex
            } else if independentStart.surfaceIndex < targetSurfaceIndex {
                // カーソルが含まれるセグメントを特定したらその始点を代入しておく
                // 終点は前のループ終了時に代入済み
                cursorSegmentStart = independentStart
                break
            }
            // 現在のセグメントの開始は次に処理するセグメントの終端になる
            cursorSegmentEnd = independentStart
        }

        // targetSurfaceIndexが含まれる独立セグメント全体をひらがなで置換する
        // この結果として生じるひらがなの文字は、`frozen`で処理する
        let cursorSegmentConvertedChars = convertedChars[cursorSegmentStart.surfaceIndex..<cursorSegmentEnd.surfaceIndex]
        let frozenElements = cursorSegmentConvertedChars.map {
            InputElement(piece: .character($0), inputStyle: .frozen)
        }
        self.input.removeSubrange(cursorSegmentStart.inputIndex..<cursorSegmentEnd.inputIndex)
        self.input.insert(contentsOf: frozenElements, at: cursorSegmentStart.inputIndex)

        // targetSurfaceIndexに相当するinputの位置を計算
        return targetSurfaceIndex - cursorSegmentStart.surfaceIndex + cursorSegmentStart.inputIndex
    }

    private func diff(from oldString: some StringProtocol, to newString: String) -> (delete: Int, input: String) {
        let common = oldString.commonPrefix(with: newString)
        return (oldString.count - common.count, String(newString.dropFirst(common.count)))
    }
    /// 現在のカーソル位置に文字を追加する関数
    public mutating func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.insertAtCursorPosition(string.map {InputElement(piece: .character($0), inputStyle: inputStyle)})
    }
    /// 現在のカーソル位置に文字を追加する関数
    public mutating func insertAtCursorPosition(_ elements: [InputElement]) {
        if elements.isEmpty {
            return
        }
        let inputCursorPosition = self.forceGetInputCursorPosition(targetSurfaceIndex: convertTargetCursorPosition)
        // input, convertTarget, convertTargetCursorPositionの3つを更新する
        // inputを更新
        self.input.insert(contentsOf: elements, at: inputCursorPosition)

        let oldConvertTarget = self.convertTarget.prefix(self.convertTargetCursorPosition)
        let newConvertTarget = Self.getConvertTarget(for: self.input.prefix(inputCursorPosition + elements.count))
        let diff = self.diff(from: oldConvertTarget, to: newConvertTarget)
        // convertTargetを更新
        self.convertTarget.removeFirst(convertTargetCursorPosition)
        self.convertTarget.insert(contentsOf: newConvertTarget, at: convertTarget.startIndex)
        // convertTargetCursorPositionを更新
        self.convertTargetCursorPosition -= diff.delete
        self.convertTargetCursorPosition += diff.input.count
    }

    /// 現在のカーソル位置から（左から右に書く言語では）右側の文字を削除する関数
    public mutating func deleteForwardFromCursorPosition(count: Int) {
        let count = min(convertTarget.count - convertTargetCursorPosition, count)
        if count == 0 {
            return
        }
        self.convertTargetCursorPosition += count
        self.deleteBackwardFromCursorPosition(count: count)
    }

    /// 現在のカーソル位置から（左から右に書く言語では）左側の文字を削除する関数
    /// エッジケースとして、`sha: しゃ|`の状態で1文字消すような場合がある。この場合、`[s, h, a]`を`[し, ゃ]`に変換した上で「ゃ」を削除する。
    public mutating func deleteBackwardFromCursorPosition(count: Int) {
        let count = min(convertTargetCursorPosition, count)

        if count == 0 {
            return
        }
        // 動作例1
        // convertTarget: かんしゃ|
        // input: [k, a, n, s, h, a]
        // count = 1
        // currentPrefix = かんしゃ
        // これから行く位置
        //  targetCursorPosition = forceGetInputCursorPosition(かんし) = 4
        //  副作用でinputは[k, a, ん, し, ゃ]
        // 現在の位置
        //  inputCursorPosition = forceGetInputCursorPosition(かんしゃ) = 5
        //  副作用でinputは[k, a, ん, し, ゃ]
        // inputを更新する
        //  input =   (input.prefix(targetCursorPosition) = [k, a, ん, し])
        //          + (input.suffix(input.count - inputCursorPosition) = [])
        //        =   [k, a, ん, し]

        // 動作例2
        // convertTarget: かんしゃ|
        // input: [k, a, n, s, h, a]
        // count = 2
        // currentPrefix = かんしゃ
        // これから行く位置
        //  targetCursorPosition = forceGetInputCursorPosition(かん) = 3
        //  副作用でinputは[k, a, ん, s, h, a]
        // 現在の位置
        //  inputCursorPosition = forceGetInputCursorPosition(かんしゃ) = 6
        //  副作用でinputは[k, a, ん, s, h, a]
        // inputを更新する
        //  input =   (input.prefix(targetCursorPosition) = [k, a, ん])
        //          + (input.suffix(input.count - inputCursorPosition) = [])
        //        =   [k, a, ん]

        // 今いる位置
        // let currentSurfaceCursorPosition = self.convertTargetBeforeCursor

        // この2つの値はこの順で計算する。
        // これから行く位置
        let targetCursorPosition = self.forceGetInputCursorPosition(targetSurfaceIndex: self.convertTargetCursorPosition - count)
        // 現在の位置
        let inputCursorPosition = self.forceGetInputCursorPosition(targetSurfaceIndex: self.convertTargetCursorPosition)

        // inputを更新する
        self.input.removeSubrange(targetCursorPosition ..< inputCursorPosition)
        // カーソルを更新する
        self.convertTargetCursorPosition -= count

        // convetTargetを更新する
        self.convertTarget = Self.getConvertTarget(for: self.input)
    }

    /// 現在のカーソル位置からカーソルを動かす関数
    /// - parameters:
    ///   - count: `convertTarget`において対応する文字数
    /// - returns: 実際に動かした文字数
    /// - note: 動かすことのできない文字数を指定した場合、返り値が変化する。
    public mutating func moveCursorFromCursorPosition(count: Int) -> Int {
        let count = max(min(self.convertTarget.count - self.convertTargetCursorPosition, count), -self.convertTargetCursorPosition)
        self.convertTargetCursorPosition += count
        return count
    }

    /// 文頭の方を確定させる関数
    ///  - parameters:
    ///   - correspondingCount: `input`において対応する文字数
    public mutating func prefixComplete(composingCount: ComposingCount) {
        switch composingCount {
        case .inputCount(let correspondingCount):
            let correspondingCount = min(correspondingCount, self.input.count)
            self.input.removeFirst(correspondingCount)
            // convetTargetを更新する
            let newConvertTarget = Self.getConvertTarget(for: self.input)
            // カーソルの位置は、消す文字数の分削除する
            let cursorDelta = self.convertTarget.count - newConvertTarget.count
            self.convertTarget = newConvertTarget
            self.convertTargetCursorPosition -= cursorDelta
            // もしも左端にカーソルが位置していたら、文頭に移動させる
            if self.convertTargetCursorPosition == 0 {
                self.convertTargetCursorPosition = self.convertTarget.count
            }
        case .surfaceCount(let correspondingCount):
            // 先頭correspondingCountを削除する操作に相当する
            // カーソルを移動する
            let index = self.forceGetInputCursorPosition(targetSurfaceIndex: correspondingCount)
            self.input = Array(self.input[index...])
            self.convertTarget = String(self.convertTarget.dropFirst(correspondingCount))
            self.convertTargetCursorPosition -= correspondingCount
            // もしも左端にカーソルが位置していたら、文頭に移動させる
            if self.convertTargetCursorPosition == 0 {
                self.convertTargetCursorPosition = self.convertTarget.count
            }

        case .composite(let left, let right):
            self.prefixComplete(composingCount: left)
            self.prefixComplete(composingCount: right)
        }
    }

    /// 現在のカーソル位置までの文字でComposingTextを作成し、返す
    public func prefixToCursorPosition() -> ComposingText {
        var text = self
        let index = text.forceGetInputCursorPosition(targetSurfaceIndex: text.convertTargetCursorPosition)
        text.input = Array(text.input.prefix(index))
        text.convertTarget = String(text.convertTarget.prefix(text.convertTargetCursorPosition))
        return text
    }

    public func inputIndexToSurfaceIndexMap() -> [Int: Int] {
        // i2c: input indexからconvert target indexへのmap
        // c2i: convert target indexからinput indexへのmap

        // 例1.
        // [k, y, o, u, h, a, i, i, t, e, n, k, i, d, a]
        // [き, ょ, う, は, い, い, て, ん, き, だ]
        // i2c: [0: 0, 3: 2(きょ), 4: 3(う), 6: 4(は), 7: 5(い), 8: 6(い), 10: 7(て), 13: 9(んき), 15: 10(だ)]

        var map: [Int: (surfaceIndex: Int, surface: String)] = [0: (0, "")]

        // 逐次更新用のバッファ
        var convertTargetElements: [ConvertTargetElement] = []

        for (idx, element) in self.input.enumerated() {
            // 要素を追加して表層文字列を更新
            Self.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
            // 表層側の長さを再計算
            let currentSurface = convertTargetElements.reduce(into: "") { $0 += $1.string }
            // idx 個の要素を処理し終えた直後（= 次の要素を処理する前）の
            // カーソル位置は idx + 1
            map[idx + 1] = (currentSurface.count, currentSurface)
        }
        // 最終的なサーフェスと一致したものだけ残す
        let finalSurface = convertTargetElements.reduce(into: "") { $0 += $1.string }
        return map
            .filter {
                finalSurface.hasPrefix($0.value.surface)
            }
            .mapValues {
                $0.surfaceIndex
            }
    }

    public mutating func stopComposition() {
        self.input = []
        self.convertTarget = ""
        self.convertTargetCursorPosition = 0
    }
}

// MARK: 部分領域の計算のためのAPI
// 例えば、「akafa」という入力があるとき、「aka」はvalidな部分領域だが、「kaf」はinvalidである。
// 難しいケースとして「itta」の「it」を「いっ」としてvalidな部分領域と見做したいというモチベーションがある。
extension ComposingText {
    static func getConvertTarget(for elements: some Sequence<InputElement>) -> String {
        var convertTargetElements: [ConvertTargetElement] = []
        for element in elements {
            updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
        }
        return convertTargetElements.reduce(into: "") {$0 += $1.string}
    }

    // inputStyleが同一であるような文字列を集積したもの
    // k, o, r, e, h, aまでをローマ字入力し、p, e, nをダイレクト入力、d, e, s, uをローマ字入力した場合、
    // originalInputに対して[ElementComposition(これは, roman2kana), ElementComposition(pen, direct), ElementComposition(です, roman2kana)]、のようになる。
    struct ConvertTargetElement {
        var string: [Character]
        var inputStyle: InputStyle
        // Cache the resolved table for non-direct styles to avoid repeated lookups
        var cachedTable: InputTable?
    }

    @inline(__always)
    static func updateConvertTargetElements(currentElements: inout [ConvertTargetElement], newElement: InputElement) {
        switch newElement.piece {
        case .character(let ch):
            if currentElements.isEmpty {
                let table: InputTable? = {
                    switch newElement.inputStyle {
                    case .direct: return nil
                    case .roman2kana: return InputStyleManager.shared.table(for: .defaultRomanToKana)
                    case .mapped(let id): return InputStyleManager.shared.table(for: id)
                    }
                }()
                let s = initializeConvertTarget(cachedTable: table, newCharacter: ch)
                currentElements.append(
                    ConvertTargetElement(string: s, inputStyle: newElement.inputStyle, cachedTable: table)
                )
                return
            }
            let lastIndex = currentElements.count - 1
            if currentElements[lastIndex].inputStyle == newElement.inputStyle {
                let table = currentElements[lastIndex].cachedTable
                updateConvertTarget(&currentElements[lastIndex].string, cachedTable: table, newCharacter: ch)
            } else {
                let table: InputTable? = {
                    switch newElement.inputStyle {
                    case .direct: return nil
                    case .roman2kana: return InputStyleManager.shared.table(for: .defaultRomanToKana)
                    case .mapped(let id): return InputStyleManager.shared.table(for: id)
                    }
                }()
                let s = initializeConvertTarget(cachedTable: table, newCharacter: ch)
                currentElements.append(
                    ConvertTargetElement(string: s, inputStyle: newElement.inputStyle, cachedTable: table)
                )
            }
        case .compositionSeparator:
            if currentElements.isEmpty {
                return
            }
            let lastIndex = currentElements.count - 1
            guard currentElements[lastIndex].inputStyle == newElement.inputStyle else { return }
            let table = currentElements[lastIndex].cachedTable
            updateConvertTarget(&currentElements[lastIndex].string, cachedTable: table, piece: .compositionSeparator)
        }
    }

    // convertTargetの更新するために削除された文字数を返す
    @inline(__always)
    static func updateConvertTargetElementsWithDeletedCount(currentElements: inout [ConvertTargetElement], newElement: InputElement) -> Int {
        switch newElement.piece {
        case .character(let ch):
            if currentElements.isEmpty {
                let table: InputTable? = {
                    switch newElement.inputStyle {
                    case .direct: return nil
                    case .roman2kana: return InputStyleManager.shared.table(for: .defaultRomanToKana)
                    case .mapped(let id): return InputStyleManager.shared.table(for: id)
                    }
                }()
                let s = initializeConvertTarget(cachedTable: table, newCharacter: ch)
                currentElements.append(
                    ConvertTargetElement(string: s, inputStyle: newElement.inputStyle, cachedTable: table)
                )
                return 0
            }
            let lastIndex = currentElements.count - 1
            if currentElements[lastIndex].inputStyle == newElement.inputStyle {
                let table = currentElements[lastIndex].cachedTable
                return updateConvertTargetWithDeletedCount(&currentElements[lastIndex].string, cachedTable: table, newCharacter: ch)
            } else {
                let table: InputTable? = {
                    switch newElement.inputStyle {
                    case .direct: return nil
                    case .roman2kana: return InputStyleManager.shared.table(for: .defaultRomanToKana)
                    case .mapped(let id): return InputStyleManager.shared.table(for: id)
                    }
                }()
                let s = initializeConvertTarget(cachedTable: table, newCharacter: ch)
                currentElements.append(
                    ConvertTargetElement(string: s, inputStyle: newElement.inputStyle, cachedTable: table)
                )
                return 0
            }
        case .compositionSeparator:
            if currentElements.isEmpty {
                return 0
            }
            let lastIndex = currentElements.count - 1
            guard currentElements[lastIndex].inputStyle == newElement.inputStyle else { return 0 }
            let table = currentElements[lastIndex].cachedTable
            updateConvertTarget(&currentElements[lastIndex].string, cachedTable: table, piece: .compositionSeparator)
            return 0
        }
    }

    static func initializeConvertTarget(cachedTable: borrowing InputTable?, newCharacter: Character) -> [Character] {
        if cachedTable != nil {
            var buf: [Character] = []
            cachedTable!.apply(to: &buf, added: .character(newCharacter))
            return buf
        } else {
            return [newCharacter]
        }
    }

    static func updateConvertTarget(_ convertTarget: inout [Character], cachedTable: borrowing InputTable?, newCharacter: Character) {
        if cachedTable != nil {
            cachedTable!.apply(to: &convertTarget, added: .character(newCharacter))
        } else {
            convertTarget.append(newCharacter)
        }
    }

    static func updateConvertTargetWithDeletedCount(_ convertTarget: inout [Character], cachedTable: borrowing InputTable?, newCharacter: Character) -> Int {
        if cachedTable != nil {
            return cachedTable!.applyWithDeletedCount(to: &convertTarget, added: .character(newCharacter))
        } else {
            convertTarget.append(newCharacter)
            return 0
        }
    }

    static func updateConvertTarget(_ convertTarget: inout [Character], cachedTable: borrowing InputTable?, piece: InputPiece) {
        switch piece {
        case .character(let ch):
            updateConvertTarget(&convertTarget, cachedTable: cachedTable, newCharacter: ch)
        case .compositionSeparator:
            cachedTable?.apply(to: &convertTarget, added: .compositionSeparator)
        }
    }
}

// Equatableにしておく
extension ComposingText: Equatable {}
extension ComposingText.InputElement: Equatable {}
extension ComposingText.ConvertTargetElement: Equatable {
    static func == (lhs: ComposingText.ConvertTargetElement, rhs: ComposingText.ConvertTargetElement) -> Bool {
        lhs.inputStyle == rhs.inputStyle && lhs.string == rhs.string
    }
}

// MARK: 差分計算用のAPI
extension ComposingText {
    /// 2つの`ComposingText`のデータを比較し、差分を計算する。
    /// `convertTarget`との整合性をとるため、`convertTarget`に合わせた上で比較する
    func differenceSuffix(to previousData: ComposingText) -> (deletedInput: Int, addedInput: Int, deletedSurface: Int, addedSurface: Int) {
        // k→か、sh→しゃ、のような場合、差分は全てx ... lastの範囲に現れるので、差分計算が問題なく動作する
        // かn → かんs、のような場合、「かんs、んs、s」のようなものは現れるが、「かん」が生成できない
        // 本質的にこれはポリシーの問題であり、「は|しゃ」の変換で「はし」が部分変換として現れないことと同根の問題である。
        // 解決のためには、inputの段階で「ん」をdirectで扱うべきである。
        // 差分を計算する
        let common = self.input.commonPrefix(with: previousData.input)
        let deleted = previousData.input.count - common.count
        let added = self.input.dropFirst(common.count).count

        let commonSurface = self.convertTarget.commonPrefix(with: previousData.convertTarget)
        let deletedSurface = previousData.convertTarget.count - commonSurface.count
        let addedSurface = self.convertTarget.count - commonSurface.count
        return (deleted, added, deletedSurface, addedSurface)
    }

    func inputHasSuffix(inputOf suffix: ComposingText) -> Bool {
        self.input.hasSuffix(suffix.input)
    }
}

#if DEBUG
extension ComposingText.InputElement: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self.inputStyle {
        case .direct:
            if case let .character(ch) = piece { "direct(\(ch))" } else { "direct(<eot>)" }
        case .roman2kana:
            if case let .character(ch) = piece { "roman2kana(\(ch))" } else { "roman2kana(<eot>)" }
        case .mapped(let id):
            if case let .character(ch) = piece { "mapped(\(id); \(ch))" } else { "mapped(\(id); <eot>)" }
        }
    }
}

extension ComposingText.ConvertTargetElement: CustomDebugStringConvertible {
    var debugDescription: String {
        "ConvertTargetElement(string: \"\(string)\", inputStyle: \(inputStyle)"
    }
}
extension InputStyle: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .direct:
            ".direct"
        case .roman2kana:
            ".roman2kana"
        case .mapped(let id):
            ".mapped(\(id))"
        }
    }
}
#endif
