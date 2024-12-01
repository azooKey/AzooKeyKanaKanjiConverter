//
//  TextReplacer.swift
//  Keyboard
//
//  Created by ensan on 2023/03/17.
//  Copyright © 2023 ensan. All rights reserved.
//

import Foundation
import SwiftUtils

/// `TextReplacer`は前後の文脈に基づいて、現在のカーソル位置の語の置き換えを提案するためのモジュールである。
/// 例えば、「tha|nk」と入力があるとき、「think」や「thanks」などを候補として表示することが考えられる。
///
/// 現在の機能は「絵文字」のバリエーションを表示することに限定する。
public struct TextReplacer: Sendable {
    // TODO: prefix trieなどの方が便利だと思う
    private var emojiSearchDict: [String: [String]] = [:]
    private var emojiGroups: [EmojiGroup] = []
    private var nonBaseEmojis: Set<String> = []

    /// データを正しく持てているかを確認するためのプロパティ
    var isEmpty: Bool {
        emojiSearchDict.isEmpty && emojiGroups.isEmpty && nonBaseEmojis.isEmpty
    }

    public init(emojiDataProvider: () -> URL) {
        var emojiSearchDict: [String: [String]] = [:]
        var emojiGroups: [EmojiGroup] = []
        do {
            let string = try String(contentsOf: emojiDataProvider(), encoding: .utf8)
            let lines = string.components(separatedBy: .newlines)
            for line in lines {
                if line.isEmpty {
                    continue
                }
                let splited = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard splited.count == 3 else {
                    debug("error", line)
                    self.emojiSearchDict = emojiSearchDict
                    self.emojiGroups = emojiGroups
                    return
                }
                let base = String(splited[0])
                let variations = splited[2].split(separator: ",").map(String.init)
                // 検索クエリを登録
                for query in splited[1].split(separator: ",") {
                    emojiSearchDict[String(query), default: []].append(base)
                    emojiSearchDict[String(query), default: []].append(contentsOf: variations)
                }
                nonBaseEmojis.formUnion(variations)
                emojiGroups.append(EmojiGroup(base: base, variations: variations))
            }
            self.emojiGroups = emojiGroups
            self.emojiSearchDict = emojiSearchDict
        } catch {
            debug("Error: 絵文字データを読み込めませんでした。このエラーは深刻ではありません。 Description: \(error.localizedDescription)")
            self.emojiSearchDict = emojiSearchDict
            self.emojiGroups = emojiGroups
            return
        }
    }

    /// 動作しない`TextReplacer`を構築するためのイニシャライザ
    /// - parameters:
    ///   - isEmpty: 入力
    private init(isEmpty: Bool) {
        assert(isEmpty)
    }

    public static var empty: Self {
        Self(isEmpty: true)
    }

    @available(*, deprecated, renamed: "init(emojiDataProvider:)", message: "it be removed in AzooKeyKanaKanjiConverter v1.0")
    public init() {
        self.init {
            if #available(iOS 16.4, *) {
                Bundle.main.bundleURL.appendingPathComponent("emoji_all_E15.0.txt.gen", isDirectory: false)
            } else if #available(iOS 15.4, *) {
                Bundle.main.bundleURL.appendingPathComponent("emoji_all_E14.0.txt.gen", isDirectory: false)
            } else {
                Bundle.main.bundleURL.appendingPathComponent("emoji_all_E13.1.txt.gen", isDirectory: false)
            }
        }
    }

    public func getSearchResult(query: String, target: [ConverterBehaviorSemantics.ReplacementTarget], ignoreNonBaseEmoji: Bool = false) -> [SearchResultItem] {
        // 正規化する
        let query = query.lowercased().toHiragana()
        var results: [SearchResultItem] = []
        if target.contains(.emoji) {
            if let candidates = self.emojiSearchDict[query] {
                for candidate in candidates {
                    results.append(SearchResultItem(query: query, text: candidate))
                }
            }
        }
        if ignoreNonBaseEmoji {
            return results.filter { !self.nonBaseEmojis.contains($0.text) }
        } else {
            return results
        }
    }

    public struct SearchResultItem: Sendable, Equatable, Hashable {
        public var query: String
        public var text: String
        public var inputable: Bool {
            true
        }
        public func getDebugInformation() -> String {
            "SearchResultItem(\(text))"
        }
    }

    public func getReplacementCandidate(left: String, center: String, right: String, target: [ConverterBehaviorSemantics.ReplacementTarget]) -> [ReplacementCandidate] {
        var results: [ReplacementCandidate] = []
        if target.contains(.emoji) {
            if center.count == 1, let item = self.emojiGroups.first(where: {$0.all.contains(center)}) {
                // 選択部分の置換
                for emoji in item.all where emoji != center {
                    results.append(ReplacementCandidate(target: center, replace: emoji, base: item.base, targetType: .emoji))
                }
            } else if let last = left.last.map(String.init), let item = self.emojiGroups.first(where: {$0.all.contains(last)}) {
                // 左側の置換
                for emoji in item.all where emoji != last {
                    results.append(ReplacementCandidate(target: last, replace: emoji, base: item.base, targetType: .emoji))
                }
            }
        }
        return results
    }

    /// 「同一」の絵文字のグループ
    private struct EmojiGroup: Sendable {
        var base: String
        var variations: [String]
        var all: [String] {
            [base] + variations
        }
    }
}

public struct ReplacementCandidate: Sendable {
    public var target: String
    public var replace: String
    public var base: String
    public var targetType: ConverterBehaviorSemantics.ReplacementTarget

    public var text: String {
        replace
    }
    public var inputable: Bool {
        true
    }

    public func getDebugInformation() -> String {
        "ReplacementCandidate(\(target)->\(replace))"
    }
}
