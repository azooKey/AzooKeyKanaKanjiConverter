import Foundation
import SwiftUtils

public final class InputStyleManager {
    nonisolated(unsafe) static let shared = InputStyleManager()

    private var tables: [InputTableID: InputTable] = [:]

    private init() {
        // デフォルトのテーブルは最初から追加しておく
        let defaultRomanToKana = InputTable(pieceHiraganaChanges: InputTables.defaultRomanToKanaPieceMap)
        let defaultAZIK = InputTable(pieceHiraganaChanges: InputTables.defaultAzikPieceMap)
        let defaultKanaJIS = InputTable(pieceHiraganaChanges: InputTables.defaultKanaJISPieceMap)
        let defaultKanaUS = InputTable(pieceHiraganaChanges: InputTables.defaultKanaUSPieceMap)
        self.tables = [
            .empty: .empty,
            .defaultRomanToKana: defaultRomanToKana,
            .defaultAZIK: defaultAZIK,
            .defaultKanaJIS: defaultKanaJIS,
            .defaultKanaUS: defaultKanaUS
        ]
    }

    func table(for id: InputTableID) -> InputTable {
        switch id {
        case .defaultRomanToKana, .defaultAZIK, .defaultKanaUS, .defaultKanaJIS, .empty:
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
                case "shift 0":
                    result.append(.piece(.key(intention: "0", modifiers: [.shift])))
                    i = str.index(after: end)
                    continue
                case "shift _":
                    result.append(.piece(.key(intention: "_", modifiers: [.shift])))
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
                    result.append(.character("{"))
                    i = str.index(after: end)
                    continue
                case "rbracket":
                    result.append(.character("}"))
                    i = str.index(after: end)
                    continue
                default:
                    break
                }
            }
            result.append(.character(str[i]))
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
            // `#`で始まる行はコメントとして無視
            guard !line.hasPrefix("#") else { continue }
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

public extension InputStyleManager {
    enum FormatReport: Sendable, Equatable, Hashable {
        case fullyValid
        case invalidLines([FormatError])
    }

    struct FormatError: Sendable, Equatable, Hashable {
        /// 0-indexed line number
        var line: Int
        /// found error
        var error: FormatErrorCase
    }

    enum FormatErrorCase: Sendable, Equatable, Hashable {
        public enum Side: Sendable, Equatable {
            case key
            case value
        }
        case invalidTabCount(found: Int)
        case unknownBraceToken(token: String, side: Side)
        case unclosedBrace
        case shiftTokenNotAtTail(token: String)
        case duplicateRule(firstDefinedAt: Int)
    }

    /// Validate custom input table content and report format issues for users.
    static func checkFormat(content: String) -> FormatReport {
        var errors: [FormatError] = []

        // Known tokens per side
        let knownKeyTokens: Set<String> = [
            "composition-separator", "any character", "lbracket", "rbracket",
            "shift 0", "shift _"
        ]
        let knownValueTokens: Set<String> = [
            "any character", "lbracket", "rbracket"
        ]

        // Helper: scan braces and validate tokens
        func scanBraces(_ s: Substring, side: FormatErrorCase.Side, lineIndex: Int) -> (allShiftAtTail: Bool, encounteredShift: Bool) {
            var i = s.startIndex
            var allShiftAtTail = true
            var encounteredShift = false
            while i < s.endIndex {
                if s[i] == "{" {
                    // find matching '}'
                    guard let end = s[i...].firstIndex(of: "}") else {
                        errors.append(.init(line: lineIndex, error: .unclosedBrace))
                        break
                    }
                    let token = String(s[s.index(after: i)..<end])
                    // detect nested '{' inside token
                    if token.contains("{") {
                        errors.append(.init(line: lineIndex, error: .unclosedBrace))
                    } else {
                        let known = (side == .key ? knownKeyTokens : knownValueTokens)
                        if !known.contains(token) {
                            errors.append(.init(line: lineIndex, error: .unknownBraceToken(token: token, side: side)))
                        }
                        if side == .key && (token == "shift 0" || token == "shift _") {
                            encounteredShift = true
                            // valid only if this token is at end of the substring
                            if s.index(after: end) != s.endIndex {
                                allShiftAtTail = false
                            }
                        }
                    }
                    i = s.index(after: end)
                } else {
                    i = s.index(after: i)
                }
            }
            return (allShiftAtTail, encounteredShift)
        }

        // Duplicate detection map
        var firstSeen: [[InputTable.KeyElement]: (line: Int, value: [InputTable.ValueElement]) ] = [:]

        let lines = content.components(separatedBy: .newlines)
        for (idx0, rawLine) in lines.enumerated() {
            let lineNo = idx0 // 0-indexed
            let line = rawLine
            // Skip empty
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            // Skip comment lines beginning with '#'
            if line.hasPrefix("#") {
                continue
            }

            // Tab count check: exactly 1 expected
            let tabCount = line.filter { $0 == "\t" }.count
            if tabCount != 1 {
                errors.append(.init(line: lineNo, error: .invalidTabCount(found: tabCount)))
                // we can still attempt further checks on best-effort basis
            }

            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let keyStr = parts[0]
            let valueStr = parts[1]

            // Brace/token checks
            let (allShiftAtTail, encounteredShift) = scanBraces(keyStr, side: .key, lineIndex: lineNo)
            _ = scanBraces(valueStr, side: .value, lineIndex: lineNo)
            if encounteredShift && !allShiftAtTail {
                // Key has {shift 0}/{shift _} but not at tail
                // Determine which occurred first for message clarity
                if keyStr.contains("{shift 0}") {
                    errors.append(.init(line: lineNo, error: .shiftTokenNotAtTail(token: "shift 0")))
                } else if keyStr.contains("{shift _}") {
                    errors.append(.init(line: lineNo, error: .shiftTokenNotAtTail(token: "shift _")))
                } else {
                    errors.append(.init(line: lineNo, error: .shiftTokenNotAtTail(token: "shift")))
                }
            }

            // Duplicate check using normalized parsed key/value
            let parsedKey = Self.parseKey(keyStr)
            let parsedValue = Self.parseValue(valueStr)
            if let (firstLine, firstValue) = firstSeen[parsedKey] {
                // Duplicate regardless of same/different value
                _ = firstValue // currently unused but kept for clarity
                errors.append(.init(line: lineNo, error: .duplicateRule(firstDefinedAt: firstLine)))
            } else {
                firstSeen[parsedKey] = (lineNo, parsedValue)
            }
        }

        return errors.isEmpty ? .fullyValid : .invalidLines(errors)
    }
}
