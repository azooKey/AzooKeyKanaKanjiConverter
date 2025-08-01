import Foundation
import SwiftUtils

final class InputStyleManager {
    nonisolated(unsafe) static let shared = InputStyleManager()

    private var tables: [InputTableID: InputTable] = [:]

    private init() {
        // デフォルトのテーブルは最初から追加しておく
        let defaultRomanToKana = InputTable(pieceHiraganaChanges: Roman2KanaMaps.defaultRomanToKanaPieceMap)
        let defaultAZIK = InputTable(pieceHiraganaChanges: Roman2KanaMaps.defaultAzikPieceMap)
        self.tables = [
            .empty: .empty,
            .defaultRomanToKana: defaultRomanToKana,
            .defaultAZIK: defaultAZIK
        ]
    }

    func table(for id: InputTableID) -> InputTable {
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

    private static func parseKey(_ str: Substring) -> [InputTable.KeyElement] {
        var result: [InputTable.KeyElement] = []
        var i = str.startIndex
        while i < str.endIndex {
            if str[i] == "{",
               let end = str[i...].firstIndex(of: "}") {
                let token = String(str[str.index(after: i)..<end])
                switch token {
                case "composition-separator":
                    result.append(.piece(.compositionSeparator))
                    i = str.index(after: end)
                    continue
                case "any character":
                    result.append(.any1)
                    i = str.index(after: end)
                    continue
                case "lbracket":
                    result.append(.piece(.character("{")))
                    i = str.index(after: end)
                    continue
                case "rbracket":
                    result.append(.piece(.character("}")))
                    i = str.index(after: end)
                    continue
                default:
                    break
                }
            }
            result.append(.piece(.character(str[i])))
            i = str.index(after: i)
        }
        return result
    }

    private static func parseValue(_ str: Substring) -> [InputTable.ValueElement] {
        var result: [InputTable.ValueElement] = []
        var i = str.startIndex
        while i < str.endIndex {
            if str[i] == "{",
               let end = str[i...].firstIndex(of: "}") {
                let token = String(str[str.index(after: i)..<end])
                switch token {
                case "any character":
                    result.append(.any1)
                    i = str.index(after: end)
                    continue
                case "lbracket":
                    result.append(.piece(.character("{")))
                    i = str.index(after: end)
                    continue
                case "rbracket":
                    result.append(.piece(.character("}")))
                    i = str.index(after: end)
                    continue
                default:
                    break
                }
            }
            result.append(.piece(.character(str[i])))
            i = str.index(after: i)
        }
        return result
    }

    private static func loadTable(from url: URL) throws -> InputTable {
        let content = try String(contentsOf: url, encoding: .utf8)
        var map: [[InputTable.KeyElement]: [InputTable.ValueElement]] = [:]
        for line in content.components(separatedBy: .newlines) {
            // 空行は無視
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // `# `で始まる行はコメントとして明示的に無視
            guard !line.hasPrefix("# ") else { continue }
            let cols = line.split(separator: "\t")
            // 要素の無い行は無視
            guard cols.count >= 2 else { continue }
            let key = parseKey(cols[0])
            let value = parseValue(cols[1])
            map[key] = value
        }
        return InputTable(pieceHiraganaChanges: map)
    }
}
