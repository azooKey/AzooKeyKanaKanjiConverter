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
        /// 入力された文字
        public var character: Character
        /// そのときの入力方式(ローマ字入力 / ダイレクト入力)
        public var inputStyle: InputStyle
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

    /// `input`でのカーソル位置を無理やり作り出す関数
    /// `target`が左側に来るようなカーソルの位置を返す。
    /// 例えば`input`が`[k, y, o, u]`で`target`が`き|`の場合を考える。
    /// この状態では`input`に対応するカーソル位置が存在しない。
    /// この場合、`input`を`[き, ょ, u]`と置き換えた上で、`き|`と考えて、`1`を返す。
    private mutating func forceGetInputCursorPosition(target: some StringProtocol) -> Int {
        debug("ComposingText forceGetInputCursorPosition", self, target)
        if target.isEmpty {
            return 0
        }
        // 動作例1
        // input: `k, a, n, s, h, a` (全てroman2kana)
        // convetTarget: `か ん し| ゃ`
        // convertTargetCursorPosition: 3
        // target: かんし
        // 動作
        // 1. character = "k"
        //    roman2kana = "k"
        //    count = 1
        // 2. character = "a"
        //    roman2kana = "か"
        //    count = 2
        //    target.hasPrefix(roman2kana)がtrueなので、lastPrefixIndex = 2, lastPrefix = "か"
        // 3. character = "n"
        //    roman2kana = "かn"
        //    count = 3
        // 4. character = "s"
        //    roman2kana = "かんs"
        //    count = 4
        // 5. character = "h"
        //    roman2kana = "かんsh"
        //    count = 5
        // 6. character = "a"
        //    roman2kana = "かんしゃ"
        //    count = 6
        //    roman2kana.hasPrefix(target)がtrueなので、変換しすぎているとみなして調整の実行
        //    replaceCountは6-2 = 4、したがって`n, s, h, a`が消去される
        //    input = [k, a]
        //    count = 2
        //    roman2kana.count == 4, lastPrefix.count = 1なので、3文字分のsuffix`ん,し,ゃ`が追加される
        //    input = [k, a, ん, し, ゃ]
        //    count = 5
        //    while
        //       1. roman2kana = かんし
        //          count = 4
        //       break
        // return count = 4
        //
        // 動作例2
        // input: `k, a, n, s, h, a` (全てroman2kana)
        // convetTarget: `か ん し| ゃ`
        // convertTargetCursorPosition: 2
        // target: かん
        // 動作
        // 1. character = "k"
        //    roman2kana = "k"
        //    count = 1
        // 2. character = "a"
        //    roman2kana = "か"
        //    count = 2
        //    target.hasPrefix(roman2kana)がtrueなので、lastPrefixIndex = 2, lastPrefix = "か"
        // 3. character = "n"
        //    roman2kana = "かn"
        //    count = 3
        // 4. character = "s"
        //    roman2kana = "かんs"
        //    count = 4
        //    roman2kana.hasPrefix(target)がtrueなので、変換しすぎているとみなして調整の実行
        //    replaceCountは4-2 = 2、したがって`n, s`が消去される
        //    input = [k, a] ... [h, a]
        //    count = 2
        //    roman2kana.count == 3, lastPrefix.count = 1なので、2文字分のsuffix`ん,s`が追加される
        //    input = [k, a, ん, s]
        //    count = 4
        //    while
        //       1. roman2kana = かん
        //          count = 3
        //       break
        // return count = 3
        //
        // 動作例3
        // input: `i, t, t, a` (全てroman2kana)
        // convetTarget: `い っ| た`
        // convertTargetCursorPosition: 2
        // target: いっ
        // 動作
        // 1. character = "i"
        //    roman2kana = "い"
        //    count = 1
        //    target.hasPrefix(roman2kana)がtrueなので、lastPrefixIndex = 1, lastPrefix = "い"
        // 2. character = "t"
        //    roman2kana = "いt"
        //    count = 2
        // 3. character = "t"
        //    roman2kana = "いっt"
        //    count = 3
        //    roman2kana.hasPrefix(target)がtrueなので、変換しすぎているとみなして調整の実行
        //    replaceCountは3-1 = 2、したがって`t, t`が消去される
        //    input = [i] ... [a]
        //    count = 1
        //    roman2kana.count == 3, lastPrefix.count = 1なので、2文字分のsuffix`っ,t`が追加される
        //    input = [i, っ, t, a]
        //    count = 3
        //    while
        //       1. roman2kana = いっ
        //          count = 2
        //       break
        // return count = 2

        var count = 0
        var lastPrefixIndex = 0
        var lastPrefix = ""
        var converting: [ConvertTargetElement] = []

        for element in input {
            Self.updateConvertTargetElements(currentElements: &converting, newElement: element)
            var converted = converting.reduce(into: "") {$0 += $1.string}
            count += 1

            // 一致していたらその時点のカウントを返す
            if converted == target {
                return count
            }
            // 一致ではないのにhasPrefixが成立する場合、変換しすぎている
            // この場合、inputの変換が必要になる。
            // 例えばcovnertTargetが「あき|ょ」で、`[a, k, y, o]`まで見て「あきょ」になってしまった場合、「あき」がprefixとなる。
            // この場合、lastPrefix=1なので、1番目から現在までの入力をひらがな(suffix)で置き換える
            else if converted.hasPrefix(target) {
                // lastPrefixIndex: 「あ」までなので1
                // count: 「あきょ」までなので4
                // replaceCount: 3
                let replaceCount = count - lastPrefixIndex
                // suffix: 「あきょ」から「あ」を落とした分なので、「きょ」
                let suffix = converted.suffix(converted.count - lastPrefix.count)
                // lastPrefixIndexから現在のカウントまでをReplace
                self.input.removeSubrange(count - replaceCount ..< count)
                // suffix1文字ずつを入力に追加する
                // この結果として生じる文字列については、`frozen`で処理する
                self.input.insert(contentsOf: suffix.map {InputElement(character: $0, inputStyle: .frozen)}, at: count - replaceCount)

                count -= replaceCount
                count += suffix.count
                while converted != target {
                    _ = converted.popLast()
                    count -= 1
                }
                break
            }
            // prefixになっている場合は更新する
            else if target.hasPrefix(converted) {
                lastPrefixIndex = count
                lastPrefix = converted
            }

        }
        return count
    }

    private func diff(from oldString: some StringProtocol, to newString: String) -> (delete: Int, input: String) {
        let common = oldString.commonPrefix(with: newString)
        return (oldString.count - common.count, String(newString.dropFirst(common.count)))
    }

    /// 現在のカーソル位置に文字を追加する関数
    public mutating func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        if string.isEmpty {
            return
        }
        let inputCursorPosition = self.forceGetInputCursorPosition(target: self.convertTarget.prefix(convertTargetCursorPosition))
        // input, convertTarget, convertTargetCursorPositionの3つを更新する
        // inputを更新
        self.input.insert(contentsOf: string.map {InputElement(character: $0, inputStyle: inputStyle)}, at: inputCursorPosition)

        let oldConvertTarget = self.convertTarget.prefix(self.convertTargetCursorPosition)
        let newConvertTarget = Self.getConvertTarget(for: self.input.prefix(inputCursorPosition + string.count))
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
        let currentPrefix = self.convertTargetBeforeCursor

        // この2つの値はこの順で計算する。
        // これから行く位置
        let targetCursorPosition = self.forceGetInputCursorPosition(target: currentPrefix.dropLast(count))
        // 現在の位置
        let inputCursorPosition = self.forceGetInputCursorPosition(target: currentPrefix)

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
            let prefix = self.convertTarget.prefix(correspondingCount)
            let index = self.forceGetInputCursorPosition(target: prefix)
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
        let index = text.forceGetInputCursorPosition(target: text.convertTarget.prefix(text.convertTargetCursorPosition))
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
    }

    static func updateConvertTargetElements(currentElements: inout [ConvertTargetElement], newElement: InputElement) {
        // currentElementsが空の場合、および
        // 直前のElementの入力方式が同じでない場合は、新たなConvertTargetElementを作成して追加する
        if currentElements.last?.inputStyle != newElement.inputStyle {
            currentElements.append(ConvertTargetElement(string: updateConvertTarget(current: [], inputStyle: newElement.inputStyle, newCharacter: newElement.character), inputStyle: newElement.inputStyle))
            return
        }
        // 末尾のエレメントの文字列を更新する
        updateConvertTarget(&currentElements[currentElements.endIndex - 1].string, inputStyle: newElement.inputStyle, newCharacter: newElement.character)
    }

    static func updateConvertTarget(current: [Character], inputStyle: InputStyle, newCharacter: Character) -> [Character] {
        switch inputStyle {
        case .direct:
            return current + [newCharacter]
        case .roman2kana:
            return InputStyleManager.shared.table(for: .defaultRomanToKana).toHiragana(currentText: current, added: newCharacter)
        case .mapped(let id):
            return InputStyleManager.shared.table(for: id).toHiragana(currentText: current, added: newCharacter)
        }
    }

    static func updateConvertTarget(_ convertTarget: inout [Character], inputStyle: InputStyle, newCharacter: Character) {
        switch inputStyle {
        case .direct:
            convertTarget.append(newCharacter)
        case .roman2kana:
            convertTarget = InputStyleManager.shared.table(for: .defaultRomanToKana).toHiragana(currentText: convertTarget, added: newCharacter)
        case .mapped(let id):
            convertTarget = InputStyleManager.shared.table(for: id).toHiragana(currentText: convertTarget, added: newCharacter)
        }
    }

}

// Equatableにしておく
extension ComposingText: Equatable {}
extension ComposingText.InputElement: Equatable {}
extension ComposingText.ConvertTargetElement: Equatable {}

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
            "direct(\(character))"
        case .roman2kana:
            "roman2kana(\(character))"
        case .mapped(let id):
            "mapped(\(id); \(character))"
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
