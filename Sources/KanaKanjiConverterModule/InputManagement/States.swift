//
//  States.swift
//
//
//  Created by ensan on 2023/04/30.
//

public enum KeyboardLanguage: String, Codable, Equatable, Sendable {
    case en_US
    case ja_JP
    case el_GR
    case none
}

public enum LearningType: Int, CaseIterable, Sendable {
    /// 学習情報は変換結果(output)に反映され、学習情報は更新(input)されます
    case inputAndOutput
    /// 学習情報は変換結果(output)に反映されるのみで、学習情報は更新されません
    case onlyOutput
    /// 学習情報は一切用いません
    case nothing

    package var needUpdateMemory: Bool {
        self == .inputAndOutput
    }

    var needUsingMemory: Bool {
        self != .nothing
    }
}

public enum ConverterBehaviorSemantics: Sendable {
    /// 標準的な日本語入力のように、変換する候補を選ぶパターン
    case conversion
    /// iOSの英語入力のように、確定は不要だが、左右の文字列の置き換え候補が出てくるパターン
    case replacement([ReplacementTarget])

    public enum ReplacementTarget: UInt8, Sendable {
        case emoji
    }
}
