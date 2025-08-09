@testable import KanaKanjiConverterModule
import XCTest

final class CommaSeparatedNumberTests: XCTestCase {
    private func makeDirectInput(direct input: String) -> ComposingText {
        ComposingText(
            convertTargetCursorPosition: input.count,
            input: input.map { .init(character: $0, inputStyle: .direct) },
            convertTarget: input
        )
    }

    func testCommaSeparatedNumberCandidates() async throws {
        let converter = await KanaKanjiConverter.withoutDictionary()

        func result(_ text: String) async -> [Candidate] {
            await converter.commaSeparatedNumberCandidates(makeDirectInput(direct: text))
        }

        let r1 = await result("49000")
        XCTAssertEqual(r1.first?.text, "49,000")

        let r2 = await result("109428081")
        XCTAssertEqual(r2.first?.text, "109,428,081")

        let r3 = await result("2129.49")
        XCTAssertEqual(r3.first?.text, "2,129.49")

        let r4 = await result("-13932")
        XCTAssertEqual(r4.first?.text, "-13,932")

        let r5 = await result("12")
        XCTAssertTrue(r5.isEmpty)

        let r6 = await result("1A9B")
        XCTAssertTrue(r6.isEmpty)

        let r7 = await result("１２３")
        XCTAssertTrue(r7.isEmpty)
    }
}
