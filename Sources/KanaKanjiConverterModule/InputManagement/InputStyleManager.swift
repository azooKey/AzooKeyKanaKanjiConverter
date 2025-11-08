public import Foundation
import OrderedCollections
import SwiftUtils

public final class InputStyleManager {
    nonisolated(unsafe) static let shared = InputStyleManager()

    private var tables: [InputTableID: InputTable] = [:]

    private init() {
        self.tables = [
            .empty: .empty,
            .defaultRomanToKana: .defaultRomanToKana,
            .defaultAZIK: .defaultAZIK,
            .defaultKanaJIS: .defaultKanaJIS,
            .defaultKanaUS: .defaultKanaUS
        ]
    }

    func table(for id: InputTableID) -> InputTable {
        switch id {
        case .defaultRomanToKana, .defaultAZIK, .defaultKanaUS, .defaultKanaJIS, .empty:
            return self.tables[id]!
        case .tableName(let name):
            guard let table = self.tables[id] else {
                print("Warning: Input table \(name) not found. Register the table with `InputStyleManager.registerInputStyle` first.")
                return .empty
            }
            return table
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
                    // Treat token as key with input '0' and intention '0'
                    result.append(.piece(.key(intention: "0", input: "0", modifiers: [.shift])))
                    i = str.index(after: end)
                    continue
                case "shift _":
                    // Treat token as key with input '_' and intention '_'
                    result.append(.piece(.key(intention: "_", input: "_", modifiers: [.shift])))
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

    public static func loadTable(from url: URL) throws -> InputTable {
        let content = try String(contentsOf: url, encoding: .utf8)
        var map: OrderedDictionary<[InputTable.KeyElement], [InputTable.ValueElement]> = [:]
        for line in content.components(separatedBy: .newlines) {
            // 空行は無視
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let cols = line.split(separator: "\t")
            // 要素の無い行は無視
            guard cols.count >= 2 else { continue }
            let key = parseKey(cols[0])
            let value = parseValue(cols[1])
            map[key] = value
        }
        return InputTable(baseMapping: map)
    }

    public enum ExportError: Error {
        case unsupportedKeyElement(InputTable.KeyElement)
    }

    public static func exportTable(_ table: InputTable) throws(ExportError) -> String {
        func encodeCharacter(_ character: Character) -> String {
            switch character {
            case "{": "{lbracket}"
            case "}": "{rbracket}"
            default: String(character)
            }
        }

        func encodeKeyElement(_ element: InputTable.KeyElement) throws(ExportError) -> String {
            switch element {
            case .piece(let inputPiece):
                switch inputPiece {
                case .character(let character): encodeCharacter(character)
                case .compositionSeparator: "{composition-separator}"
                case .key(let intention, let input, let modifiers):
                    switch (intention, input, modifiers) {
                    case ("0", "0", [.shift]): "{shift 0}"
                    case ("_", "_", [.shift]): "{shift _}"
                    default: throw .unsupportedKeyElement(element)
                    }
                }
            case .any1: "{any character}"
            }
        }

        func encodeValueElement(_ element: InputTable.ValueElement) -> String {
            switch element {
            case .character(let character): encodeCharacter(character)
            case .any1: "{any character}"
            }
        }

        var lines: [String] = []
        for (key, value) in table.baseMapping {
            let encodedKeys = try key.map(encodeKeyElement).joined()
            let encodedValues = value.map(encodeValueElement).joined()
            lines.append("\(encodedKeys)\t\(encodedValues)")
        }
        return lines.joined(separator: "\n")
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

public extension InputStyleManager {
    static func registerInputStyle(table: InputTable, for name: String) {
        Self.shared.tables[.tableName(name)] = table
    }
}
