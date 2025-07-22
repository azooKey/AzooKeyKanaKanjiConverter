import Foundation
import SwiftUtils

final class InputStyleManager {
    nonisolated(unsafe) static let shared = InputStyleManager()

    struct Table {
        init(hiraganaChanges: [[Character] : [Character]]) {
            self.hiraganaChanges = hiraganaChanges
            self.unstableSuffixes = hiraganaChanges.keys.flatMapSet { characters in
                characters.indices.map { i in
                    Array(characters[...i])
                }
            }
            let katakanaChanges = Dictionary(uniqueKeysWithValues: hiraganaChanges.map { (String($0.key), String($0.value).toKatakana()) })
            self.katakanaChanges = katakanaChanges
            self.maxKeyCount = hiraganaChanges.lazy.map { $0.key.count }.max() ?? 0
            self.possibleNexts = {
                var results: [String: [String]] = [:]
                for (key, value) in katakanaChanges {
                    for prefixCount in 0 ..< key.count where 0 < prefixCount {
                        let prefix = String(key.prefix(prefixCount))
                        results[prefix, default: []].append(value)
                    }
                }
                return results
            }()
        }
        
        let unstableSuffixes: Set<[Character]>
        let katakanaChanges: [String: String]
        let hiraganaChanges: [[Character]: [Character]]
        let maxKeyCount: Int
        let possibleNexts: [String: [String]]

        static let empty = Table(hiraganaChanges: [:])

        func toHiragana(currentText: [Character], added: Character) -> [Character] {
            for n in (0 ..< self.maxKeyCount).reversed() {
                if n == 0 {
                    if let kana = self.hiraganaChanges[[added]] {
                        return currentText + kana
                    }
                } else {
                    let last = currentText.suffix(n)
                    if let kana = self.hiraganaChanges[last + [added]] {
                        return currentText.prefix(currentText.count - last.count) + kana
                    }
                }
            }
            return currentText + [added]
        }
    }

    private var tables: [InputTableID: Table] = [:]

    private init() {
        // デフォルトのテーブルは最初から追加しておく
        let defaultRomanToKana = Table(hiraganaChanges: Roman2KanaMaps.defaultRomanToKanaMap)
        let defaultAZIK = Table(hiraganaChanges: Roman2KanaMaps.defaultAzikMap)
        self.tables = [
            .empty: .empty,
            .defaultRomanToKana: defaultRomanToKana,
            .defaultAZIK: defaultAZIK
        ]
    }

    func table(for id: InputTableID) -> Table {
        switch id {
        case .defaultRomanToKana, .defaultAZIK, .empty:
            return self.tables[id]!
        case .custom(let url):
            if let table = self.tables[id] {
                return table
            } else if let table = try? Self.loadTable(from: url) {
                self.tables[id] = table
                return table
            } else {
                return .empty
            }
        }
    }

    private static func loadTable(from url: URL) throws -> Table {
        let content = try String(contentsOf: url, encoding: .utf8)
        var map: [[Character]: [Character]] = [:]
        for line in content.components(separatedBy: .newlines) {
            // 空行は無視
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // `# `で始まる行はコメントとして明示的に無視
            guard !line.hasPrefix("# ") else { continue }
            let cols = line.split(separator: "\t")
            // 要素の無い行は無視
            guard cols.count >= 2 else { continue }
            let key = Array(String(cols[0]))
            let value = Array(String(cols[1]))
            map[key] = value
        }
        return Table(hiraganaChanges: map)
    }
}
