@testable import KanaKanjiConverterModule
import XCTest

final class InputStyleManagerTests: XCTestCase {
    func testCustomTableLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom.tsv")
        try "a\tあ\nka\tか\n".write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        XCTAssertEqual(table.toHiragana(currentText: [], added: "a"), Array("あ"))
        XCTAssertEqual(table.toHiragana(currentText: ["k"], added: "a"), Array("か"))
    }

    func testCustomTableLoadingWithBlankLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom.tsv")
        try "a\tあ\n\n\nka\tか\n".write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        XCTAssertEqual(table.toHiragana(currentText: [], added: "a"), Array("あ"))
        XCTAssertEqual(table.toHiragana(currentText: ["k"], added: "a"), Array("か"))
    }

    func testCustomTableLoadingWithCommentLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custom.tsv")
        try "a\tあ\n# here is comment\nka\tか\n".write(to: url, atomically: true, encoding: .utf8)
        let table = InputStyleManager.shared.table(for: .custom(url))
        XCTAssertEqual(table.toHiragana(currentText: [], added: "a"), Array("あ"))
        XCTAssertEqual(table.toHiragana(currentText: ["k"], added: "a"), Array("か"))
    }
}
