@testable import KanaKanjiConverterModule
import XCTest

final class InputStyleManagerTests: XCTestCase {
    func testCustomTableLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom.tsv")
        try "a\tあ\nka\tか\n".write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        XCTAssertEqual(table.updateSurface(current: [], added: .character("a")), [.character("あ")])
        XCTAssertEqual(table.updateSurface(current: [.character("k")], added: .character("a")), [.character("か")])
    }

    func testCustomTableLoadingWithBlankLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom.tsv")
        try "a\tあ\n\n\nka\tか\n".write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        XCTAssertEqual(table.updateSurface(current: [], added: .character("a")), [.character("あ")])
        XCTAssertEqual(table.updateSurface(current: [.character("k")], added: .character("a")), [.character("か")])
    }

    func testCustomTableLoadingWithCommentLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom.tsv")
        try "a\tあ\n# here is comment\nka\tか\n".write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        XCTAssertEqual(table.updateSurface(current: [], added: .character("a")), [.character("あ")])
        XCTAssertEqual(table.updateSurface(current: [.character("k")], added: .character("a")), [.character("か")])
    }

    func testCustomTableLoadingWithSpecialTokens() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom_special.tsv")
        let lines = [
            "n{any character}\tん{any character}",
            "n{composition-separator}\tん",
            "{lbracket}{rbracket}\t{}"
        ].joined(separator: "\n")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        // n<any> -> ん<any>
        XCTAssertEqual(table.updateSurface(current: [.character("n")], added: .character("a")), [.character("ん"), .character("a")])
        // n followed by end-of-text -> ん
        XCTAssertEqual(table.updateSurface(current: [.character("n")], added: .compositionSeparator), [.character("ん")])
        // "{" then "}" -> "{}"
        XCTAssertEqual(table.updateSurface(current: [.character("{")], added: .character("}")), [.character("{"), .character("}")])
    }
}
