@testable import KanaKanjiConverterModule
import XCTest

final class Roman2KanaTests: XCTestCase {
    func testToHiragana() throws {
        let table = InputStyleManager.shared.table(for: .defaultRomanToKana)
        // xtsu -> っ
        XCTAssertEqual(table.toHiragana(currentText: Array(""), added: "x"), Array("x"))
        XCTAssertEqual(table.toHiragana(currentText: Array("x"), added: "t"), Array("xt"))
        XCTAssertEqual(table.toHiragana(currentText: Array("xt"), added: "s"), Array("xts"))
        XCTAssertEqual(table.toHiragana(currentText: Array("xts"), added: "u"), Array("っ"))

        // kanto -> かんと
        XCTAssertEqual(table.toHiragana(currentText: Array(""), added: "k"), Array("k"))
        XCTAssertEqual(table.toHiragana(currentText: Array("k"), added: "a"), Array("か"))
        XCTAssertEqual(table.toHiragana(currentText: Array("か"), added: "n"), Array("かn"))
        XCTAssertEqual(table.toHiragana(currentText: Array("かn"), added: "t"), Array("かんt"))
        XCTAssertEqual(table.toHiragana(currentText: Array("かんt"), added: "o"), Array("かんと"))

        // zl -> →
        XCTAssertEqual(table.toHiragana(currentText: Array(""), added: "z"), Array("z"))
        XCTAssertEqual(table.toHiragana(currentText: Array("z"), added: "l"), Array("→"))

        // TT -> TT
        XCTAssertEqual(table.toHiragana(currentText: Array("T"), added: "T"), Array("TT"))
    }
}
