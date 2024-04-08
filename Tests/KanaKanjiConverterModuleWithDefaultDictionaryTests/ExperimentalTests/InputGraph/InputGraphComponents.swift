//
//  InputGraph.swift
//
//
//  Created by miwa on 2024/02/21.
//

import Foundation
import DequeModule

@testable import KanaKanjiConverterModule
import XCTest

enum InputGraphRange: Equatable, Sendable {
    case unknown
    case startIndex(Int)
    case endIndex(Int)
    case range(Int, Int)

    init(startIndex: Int?, endIndex: Int?) {
        self = switch (startIndex, endIndex) {
        case let (s?, e?): .range(s, e)
        case (let s?, nil): .startIndex(s)
        case (nil, let e?): .endIndex(e)
        case (nil, nil): .unknown
        }
    }

    var startIndex: Int? {
        switch self {
        case .unknown, .endIndex: nil
        case .startIndex(let index), .range(let index, _): index
        }
    }

    var endIndex: Int? {
        switch self {
        case .unknown, .startIndex: nil
        case .endIndex(let index), .range(_, let index): index
        }
    }
}

struct InputGraphInputStyle: Identifiable {
    init(from deprecatedInputStyle: KanaKanjiConverterModule.InputStyle) {
        switch deprecatedInputStyle {
        case .direct:
            self = .systemFlickDirect
        case .roman2kana:
            self = .systemRomanKana
        }
    }

    init(from id: InputGraphInputStyle.ID) {
        self = switch id {
        case .all: .all
        case .systemFlickDirect: .systemFlickDirect
        case .systemRomanKana: .systemRomanKana
        case .none: .none
        default: fatalError("Unimplemented")
        }
    }

    private init(id: InputGraphInputStyle.ID, replaceSuffixTree: ReplaceSuffixTree.Node, correctSuffixTree: CorrectSuffixTree.Node) {
        self.id = id
        self.replaceSuffixTree = replaceSuffixTree
        self.correctSuffixTree = correctSuffixTree
    }

    struct ID: Equatable, Hashable, Sendable, CustomStringConvertible {
        init(id: UInt8) {
            self.id = id
        }
        init(from deprecatedInputStyle: KanaKanjiConverterModule.InputStyle) {
            switch deprecatedInputStyle {
            case .direct:
                self = .systemFlickDirect
            case .roman2kana:
                self = .systemRomanKana
            }
        }
        static let none = Self(id: 0x00)
        static let all = Self(id: 0xFF)
        static let systemFlickDirect = Self(id: 0x01)
        static let systemRomanKana = Self(id: 0x02)
        var id: UInt8

        func isCompatible(with id: ID) -> Bool {
            if self == .all {
                true
            } else {
                self == id
            }
        }
        var description: String {
            "ID(\(id))"
        }
    }
    static let none: Self = Self(
        id: .none,
        replaceSuffixTree: ReplaceSuffixTree.Node(),
        correctSuffixTree: CorrectSuffixTree.Node()
    )
    static let all: Self = Self(
        id: .all,
        replaceSuffixTree: ReplaceSuffixTree.Node(),
        correctSuffixTree: CorrectSuffixTree.Node()
    )
    static let systemFlickDirect: Self = Self(
        id: .systemFlickDirect,
        replaceSuffixTree: ReplaceSuffixTree.direct,
        correctSuffixTree: CorrectSuffixTree.direct
    )
    static let systemRomanKana: Self = Self(
        id: .systemRomanKana,
        replaceSuffixTree: ReplaceSuffixTree.roman2kana,
        correctSuffixTree: CorrectSuffixTree.roman2kana
    )

    /// `id` for the input style.
    ///  - warning: value `0x00-0x7F` is reserved for system space.
    var id: ID
    var replaceSuffixTree: ReplaceSuffixTree.Node
    var correctSuffixTree: CorrectSuffixTree.Node
}
