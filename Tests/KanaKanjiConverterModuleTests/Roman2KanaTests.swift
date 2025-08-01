@testable import KanaKanjiConverterModule
import XCTest

final class Roman2KanaTests: XCTestCase {
    func toSurfacePieces(_ input: String) -> [SurfacePiece] {
        input.map { .character($0) }
    }

    func testToHiragana() throws {
        let table = InputStyleManager.shared.table(for: .defaultRomanToKana)
        // xtsu -> っ
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces(""), added: "x"), toSurfacePieces("x"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("x"), added: "t"), toSurfacePieces("xt"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("xt"), added: "s"), toSurfacePieces("xts"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("xts"), added: "u"), toSurfacePieces("っ"))

        // kanto -> かんと
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces(""), added: "k"), toSurfacePieces("k"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("k"), added: "a"), toSurfacePieces("か"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("か"), added: "n"), toSurfacePieces("かn"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("かn"), added: "t"), toSurfacePieces("かんt"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("かんt"), added: "o"), toSurfacePieces("かんと"))

        // zl -> →
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces(""), added: "z"), toSurfacePieces("z"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("z"), added: "l"), toSurfacePieces("→"))

        // TT -> TT
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("T"), added: "T"), toSurfacePieces("TT"))

        // n<any> -> ん<any>
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("n"), added: "。"), toSurfacePieces("ん。"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("n"), added: "+"), toSurfacePieces("ん+"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("n"), added: "N"), toSurfacePieces("んN"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("n"), added: .compositionSeparator), toSurfacePieces("ん"))

        // nyu
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("ny"), added: "u"), toSurfacePieces("にゅ"))
    }

    func testAny1Cases() throws {
        let table = InputTable(pieceHiraganaChanges: [
            [.any1, .any1]: [.piece(.character("😄"))],
            [.piece(.character("s")), .piece(.character("s"))]: [.piece(.character("ß"))],
            [.piece(.character("a")), .piece(.character("z")), .piece(.character("z"))]: [.piece(.character("Q"))],
            [.any1, .any1, .any1]: [.piece(.character("[")), .any1, .piece(.character("]"))],
            [.piece(.character("n")), .any1]: [.piece(.character("ん")), .any1]
        ])
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("a"), added: "b"), toSurfacePieces("ab"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("abc"), added: "d"), toSurfacePieces("abcd"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces(""), added: "z"), toSurfacePieces("z"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("z"), added: "z"), toSurfacePieces("😄"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("z"), added: "s"), toSurfacePieces("zs"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("s"), added: "s"), toSurfacePieces("ß"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("az"), added: "z"), toSurfacePieces("Q"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("ss"), added: "s"), toSurfacePieces("[s]"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("sr"), added: "s"), toSurfacePieces("srs"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("n"), added: "t"), toSurfacePieces("んt"))
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("n"), added: "n"), toSurfacePieces("んn"))
    }

    func testToggleInputMock() throws {
        let table = InputTable(pieceHiraganaChanges: [
            [.piece("あ")]: [.piece("あ")],
            [.piece("あ"), .piece("あ")]: [.piece("い")],
            [.piece("い"), .piece("あ")]: [.piece("う")],
            // compositionSeparatorが入ったら、そこで区切りを切る
            [.any1, .piece(.compositionSeparator)]: [.any1, .piece(.surfaceSeparator)],
            // @を巻き戻し記号と考える場合
        ])
        XCTAssertEqual(table.updateSurface(current: toSurfacePieces("あ"), added: "あ"), toSurfacePieces("い"))
        XCTAssertEqual(table.updateSurface(current: ["あ", .surfaceSeparator], added: "あ"), ["あ", .surfaceSeparator, "あ"])
    }
}
