import XCTest

final class MozcCommandTests: XCTestCase {
    private typealias Command = ConverterTests.MozcCommand

    func testConversionCommandsAndRanks() throws {
        XCTAssertEqual(try Command("Conversion Match"), .conversionMatch)
        XCTAssertEqual(try Command("Conversion Not Match"), .conversionNotMatch)
        XCTAssertEqual(try Command("Conversion Expected"), .conversionExpected(within: 1))
        for rank in [2, 3, 5, 9, 12, 19, 99, 999] {
            let command = try Command("Conversion Expected \(rank)")
            XCTAssertEqual(command, .conversionExpected(within: rank))
            XCTAssertEqual(command.requiredCount, rank)
            XCTAssertTrue(command.isConversion)
        }
        XCTAssertTrue(try Command("Conversion Match").isConversion)
        XCTAssertTrue(try Command("Conversion Not Match").isConversion)
    }

    func testPredictionAndSuggestionAreRecognizedButExcludedFromConversion() throws {
        let command = try Command("Prediction Expected 2")
        XCTAssertEqual(command, .predictionExpected(within: 2))
        XCTAssertEqual(command.requiredCount, 2)
        XCTAssertFalse(command.isConversion)
        XCTAssertEqual(try Command("Prediction Expected"), .predictionExpected(within: 1))
        XCTAssertFalse(try Command("Suggestion Not Expected").isConversion)

        // スコア集計の対象は変換ケースだけ。予測ケースの追加で分母・比較対象を変えない。
        let commands = try ["Conversion Match", "Prediction Expected 2", "Conversion Expected 9", "Suggestion Not Expected"].map { try Command($0) }
        XCTAssertEqual(commands.filter(\.isConversion), [.conversionMatch, .conversionExpected(within: 9)])
    }

    func testUnknownCommandsThrowInsteadOfCrashingOrBeingSilentlySkipped() {
        for raw in ["", "Unknown Command", "Prediction Unexpected 2", "Conversion Expectedness", "Conversion Expected 2 extra"] {
            XCTAssertThrowsError(try Command(raw)) { error in
                XCTAssertEqual(error as? Command.ParseError, .unknownCommand(raw))
            }
        }
    }

    func testInvalidRanksThrowInsteadOfForceUnwrapping() {
        for raw in ["Conversion Expected x", "Conversion Expected 0", "Prediction Expected -1", "Conversion Expected ", "Conversion Expected 99999999999999999999999999"] {
            XCTAssertThrowsError(try Command(raw)) { error in
                XCTAssertEqual(error as? Command.ParseError, .invalidCount(raw))
            }
        }
    }
}
