@testable import KanaKanjiConverterModule
import XCTest

final class Roman2KanaTests: XCTestCase {
    func testToHiragana() throws {
        let table = InputStyleManager.shared.table(for: .defaultRomanToKana)
        // xtsu -> っ
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("x")), Array("x"))
        XCTAssertEqual(table.applied(currentText: Array("x"), added: .character("t")), Array("xt"))
        XCTAssertEqual(table.applied(currentText: Array("xt"), added: .character("s")), Array("xts"))
        XCTAssertEqual(table.applied(currentText: Array("xts"), added: .character("u")), Array("っ"))

        // kanto -> かんと
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("k")), Array("k"))
        XCTAssertEqual(table.applied(currentText: Array("k"), added: .character("a")), Array("か"))
        XCTAssertEqual(table.applied(currentText: Array("か"), added: .character("n")), Array("かn"))
        XCTAssertEqual(table.applied(currentText: Array("かn"), added: .character("t")), Array("かんt"))
        XCTAssertEqual(table.applied(currentText: Array("かんt"), added: .character("o")), Array("かんと"))

        // zl -> →
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("z")), Array("z"))
        XCTAssertEqual(table.applied(currentText: Array("z"), added: .character("l")), Array("→"))

        // TT -> TT
        XCTAssertEqual(table.applied(currentText: Array("T"), added: .character("T")), Array("TT"))

        // n<any> -> ん<any>
        XCTAssertEqual(table.applied(currentText: Array("n"), added: .character("。")), Array("ん。"))
        XCTAssertEqual(table.applied(currentText: Array("n"), added: .character("+")), Array("ん+"))
        XCTAssertEqual(table.applied(currentText: Array("n"), added: .character("N")), Array("んN"))
        XCTAssertEqual(table.applied(currentText: Array("n"), added: .compositionSeparator), Array("ん"))

        // nyu
        XCTAssertEqual(table.applied(currentText: Array("ny"), added: .character("u")), Array("にゅ"))
    }

    func testAny1Cases() throws {
        let table = InputTable(baseMapping: [
            [.any1, .any1]: [.character("😄")],
            [.piece(.character("s")), .piece(.character("s"))]: [.character("ß")],
            [.piece(.character("a")), .piece(.character("z")), .piece(.character("z"))]: [.character("Q")],
            [.any1, .any1, .any1]: [.character("["), .any1, .character("]")],
            [.piece(.character("n")), .any1]: [.character("ん"), .any1]
        ] as Dictionary)
        XCTAssertEqual(table.applied(currentText: Array("a"), added: .character("b")), Array("ab"))
        XCTAssertEqual(table.applied(currentText: Array("abc"), added: .character("d")), Array("abcd"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("z")), Array("z"))
        XCTAssertEqual(table.applied(currentText: Array("z"), added: .character("z")), Array("😄"))
        XCTAssertEqual(table.applied(currentText: Array("z"), added: .character("s")), Array("zs"))
        XCTAssertEqual(table.applied(currentText: Array("s"), added: .character("s")), Array("ß"))
        XCTAssertEqual(table.applied(currentText: Array("az"), added: .character("z")), Array("Q"))
        XCTAssertEqual(table.applied(currentText: Array("ss"), added: .character("s")), Array("[s]"))
        XCTAssertEqual(table.applied(currentText: Array("sr"), added: .character("s")), Array("srs"))
        XCTAssertEqual(table.applied(currentText: Array("n"), added: .character("t")), Array("んt"))
        XCTAssertEqual(table.applied(currentText: Array("n"), added: .character("n")), Array("んn"))
    }

    func testKanaJIS() throws {
        let table = InputStyleManager.shared.table(for: .defaultKanaJIS)
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("q")), Array("た"))
        XCTAssertEqual(table.applied(currentText: Array("た"), added: .character("＠")), Array("だ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .key(intention: "0", input: "0", modifiers: [.shift])), Array("を"))
        XCTAssertEqual(table.applied(currentText: Array("た"), added: .key(intention: "＠", input: "@", modifiers: [])), Array("だ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .key(intention: "0", input: "0", modifiers: [.shift])), Array("を"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("Q")), Array("た"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("！")), Array("ぬ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("”")), Array("ふ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("〜")), Array("へ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("＊")), Array("け"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("＋")), Array("れ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("＝")), Array("ほ"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("｀")), Array("゛"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("｜")), Array("ー"))
    }

    func testKanaUS() throws {
        let table = InputStyleManager.shared.table(for: .defaultKanaUS)
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("t")), Array("か"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .character("T")), Array("か"))
    }

    func testDesktopRomanToKana() throws {
        let table = InputStyleManager.shared.table(for: .defaultRomanToKana)
        XCTAssertEqual(table.applied(currentText: Array("k"), added: .character("a")), Array("か"))
        XCTAssertEqual(table.applied(currentText: Array(""), added: .key(intention: "「", input: "[", modifiers: [])), Array("「"))
        XCTAssertEqual(table.applied(currentText: Array("ん"), added: .key(intention: "「", input: "[", modifiers: [])), Array("ん「"))
        XCTAssertEqual(table.applied(currentText: Array("ん"), added: .key(intention: "『", input: "{", modifiers: [])), Array("ん『"))
    }

    func testAZIKCompatibility() throws {
        let table = InputStyleManager.shared.table(for: .defaultAZIK)
        let mappings: [(String, String)] = [
            ("ji", "じ"),
            ("jk", "じん"),
            ("ci", "ち"),
            ("ck", "ちん"),
            ("jya", "じゃ"),
            ("lka", "ヵ"),
            ("lke", "ヶ"),
            ("lwa", "ゎ"),
            ("tgu", "とぅ"),
            ("km", "かも"),
        ]
        for (stroke, expected) in mappings {
            var text: [Character] = []
            for character in stroke {
                text = table.applied(currentText: text, added: .character(character))
            }
            XCTAssertEqual(String(text), expected, stroke)
        }
    }

    func testTableMerge() throws {
        let table1 = InputTable(baseMapping: [
            [.piece(.character("k")), .piece(.character("a"))]: [.character("か")],
            [.piece(.character("s")), .piece(.character("a"))]: [.character("さ")],
            [.piece(.character("t")), .piece(.character("a"))]: [.character("た")]
        ] as Dictionary)
        let table2 = InputTable(baseMapping: [
            [.piece(.character("s")), .piece(.character("a"))]: [.character("し")],
            [.piece(.character("t")), .piece(.character("a"))]: [.character("ち")]
        ] as Dictionary)
        let table3 = InputTable(baseMapping: [
            [.piece(.character("t")), .piece(.character("a"))]: [.character("つ")]
        ] as Dictionary)
        let table = InputTable(tables: [table1, table2, table3], order: .lastInputWins)
        XCTAssertEqual(table.applied(currentText: Array("k"), added: .character("a")), Array("か"))
        XCTAssertEqual(table.applied(currentText: Array("s"), added: .character("a")), Array("し"))
        XCTAssertEqual(table.applied(currentText: Array("t"), added: .character("a")), Array("つ"))
    }
}
