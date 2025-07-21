import Foundation
import SwiftUtils

final class InputStyleManager {
    nonisolated(unsafe) static let shared = InputStyleManager()

    struct Table {
        internal init(hiraganaChanges: [[Character] : [Character]]) {
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

    enum TableID: Sendable, Equatable, Hashable {
        case `defaultRomanToKana`
        case custom(String)
    }

    private var customTables: [TableID: Table] = [:]

    private init() {
        // デフォルトのテーブルは最初から追加しておく
        self.customTables[.defaultRomanToKana] = Table(
            hiraganaChanges: Roman2KanaMaps.defaultRomanToKanaMap,
        )
        // `__azik__`は仮実装であるため、このような記述にしている。
        self.customTables[.custom("__azik__")] = Table(
            hiraganaChanges: Roman2KanaMaps.defaultRomanToKanaMap,
        )
    }

    func table(for tableID: TableID) -> Table {
        self.customTables[tableID, default: .empty]
    }
}
