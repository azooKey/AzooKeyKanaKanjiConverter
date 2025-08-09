@testable import KanaKanjiConverterModule
import XCTest

final class EmailAddressConversionTests: XCTestCase {
    func makeDirectInput(direct input: String) -> ComposingText {
        ComposingText(
            convertTargetCursorPosition: input.count,
            input: input.map {.init(character: $0, inputStyle: .direct)},
            convertTarget: input
        )
    }

    func testtoEmailAddressCandidates() async throws {
        do {
            let converter = await KanaKanjiConverter.withoutDictionary()
            let input = makeDirectInput(direct: "azooKey@")
            let result = await converter.toEmailAddressCandidates(input)
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@gmail.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@icloud.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@yahoo.co.jp"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@i.softbank.jp"}))
        }

        do {
            let converter = await KanaKanjiConverter.withoutDictionary()
            let input = makeDirectInput(direct: "my.dev_az@")
            let result = await converter.toEmailAddressCandidates(input)
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.contains(where: {$0.text == "my.dev_az@gmail.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "my.dev_az@icloud.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "my.dev_az@yahoo.co.jp"}))
            XCTAssertTrue(result.contains(where: {$0.text == "my.dev_az@i.softbank.jp"}))
        }

        do {
            let converter = await KanaKanjiConverter.withoutDictionary()
            let input = makeDirectInput(direct: "@")
            let result = await converter.toEmailAddressCandidates(input)
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.contains(where: {$0.text == "@gmail.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "@icloud.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "@yahoo.co.jp"}))
            XCTAssertTrue(result.contains(where: {$0.text == "@i.softbank.jp"}))
        }

        // New tests for partial domain inputs
        do {
            let converter = await KanaKanjiConverter.withoutDictionary()
            let input = makeDirectInput(direct: "azooKey@g")
            let result = await converter.toEmailAddressCandidates(input)
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@gmail.com"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@googlemail.com"}))
            XCTAssertFalse(result.contains(where: {$0.text == "azooKey@yahoo.co.jp"}))
        }

        do {
            let converter = await KanaKanjiConverter.withoutDictionary()
            let input = makeDirectInput(direct: "azooKey@y")
            let result = await converter.toEmailAddressCandidates(input)
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@yahoo.co.jp"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@yahoo.ne.jp"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@ybb.ne.jp"}))
            XCTAssertTrue(result.contains(where: {$0.text == "azooKey@ymobile.ne.jp"}))
            XCTAssertFalse(result.contains(where: {$0.text == "azooKey@gmail.com"}))
        }
    }
}
