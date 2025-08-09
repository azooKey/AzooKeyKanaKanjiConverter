@testable import KanaKanjiConverterModule
import XCTest

final class TimeExpressionTests: XCTestCase {
    private func makeDirectInput(direct input: String) -> ComposingText {
        ComposingText(
            convertTargetCursorPosition: input.count,
            input: input.map {.init(character: $0, inputStyle: .direct)},
            convertTarget: input
        )
    }

    func testConvertToTimeExpression() async throws {
        let converter = await KanaKanjiConverter.withoutDictionary()

        let input1 = makeDirectInput(direct: "123")
        let input2 = makeDirectInput(direct: "1234")
        let input3 = makeDirectInput(direct: "999")
        let input4 = makeDirectInput(direct: "1260")
        let input5 = makeDirectInput(direct: "2440")
        let input6 = makeDirectInput(direct: "")
        let input7 = makeDirectInput(direct: "あいうえ")
        let input8 = makeDirectInput(direct: "13122")

        let candidates1 = await converter.convertToTimeExpression(input1)
        let candidates2 = await converter.convertToTimeExpression(input2)
        let candidates3 = await converter.convertToTimeExpression(input3)
        let candidates4 = await converter.convertToTimeExpression(input4)
        let candidates5 = await converter.convertToTimeExpression(input5)
        let candidates6 = await converter.convertToTimeExpression(input6)
        let candidates7 = await converter.convertToTimeExpression(input7)
        let candidates8 = await converter.convertToTimeExpression(input8)

        XCTAssertEqual(candidates1.count, 1)
        XCTAssertEqual(candidates1.first?.text, "1:23")

        XCTAssertEqual(candidates2.count, 1)
        XCTAssertEqual(candidates2.first?.text, "12:34")

        XCTAssertEqual(candidates3.count, 0)

        XCTAssertEqual(candidates4.count, 0)

        XCTAssertEqual(candidates5.count, 1)
        XCTAssertEqual(candidates5.first?.text, "24:40")

        XCTAssertEqual(candidates6.count, 0)

        XCTAssertEqual(candidates7.count, 0)

        XCTAssertEqual(candidates8.count, 0)
    }
}
