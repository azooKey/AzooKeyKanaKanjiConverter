//
//  CorrectSuffixTree.swift
//  
//
//  Created by miwa on 2024/02/23.
//

import Foundation

@testable import KanaKanjiConverterModule
import XCTest

/// 誤字訂正のためのsuffix tree
enum CorrectSuffixTree {
    final class Node {
        init(_ children: [Character: Node] = [:], value: [String] = []) {
            self.children = children
            self.value = value
        }

        static func terminal(_ value: [String]) -> Node {
            Node(value: value)
        }

        static func terminal(_ value: String) -> Node {
            Node(value: [value])
        }

        var children: [Character: Node] = [:]
        var value: [String]
        func find(key: Character) -> Node? {
            return children[key]
        }
    }

    static let roman2kana: Node = {
        Node([
            "s": Node([
                "g": .terminal("ga"),
                "m": .terminal("ma"),
                "t": .terminal("ta"),
                "y": .terminal("ya")
            ]),
            "q": Node([
                "g": .terminal("ga"),
                "m": .terminal("ma"),
                "t": .terminal("ta"),
                "y": .terminal("ya")
            ]),
            "d": Node([
                "g": .terminal("ge"),
                "m": .terminal("me"),
                "t": .terminal("te"),
                "y": .terminal("ya")
            ]),
            "r": Node([
                "g": .terminal("ge"),
                "m": .terminal("me"),
                "t": .terminal("te"),
                "y": .terminal("ya")
            ]),
            "w": Node([
                "g": .terminal("ge"),
                "m": .terminal("me"),
                "t": .terminal("te"),
                "y": .terminal("ya")
            ]),
            "k": Node([
                "g": .terminal("gi"),
                "m": .terminal("mi"),
                "t": .terminal("ti"),
                "y": .terminal("ya")
            ]),
            "l": Node([
                "g": .terminal("go"),
                "m": .terminal("mo"),
                "t": .terminal("to"),
                "y": .terminal("ya")
            ]),
            "p": Node([
                "g": .terminal("go"),
                "m": .terminal("mo"),
                "t": .terminal("to"),
                "y": .terminal("ya")
            ]),
            "j": Node([
                "g": .terminal("gu"),
                "m": .terminal("mu"),
                "t": .terminal("tu"),
                "y": .terminal("ya")
            ])
        ])
    }()

    static let direct: Node = {
        Node([
            "か": .terminal(["が"]),
            "た": .terminal(["だ"]),
            "は": .terminal(["ば", "ぱ"])
        ])
    }()
}
