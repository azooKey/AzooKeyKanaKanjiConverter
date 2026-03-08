import Foundation
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class AncoSessionCommandTests: XCTestCase {
    func testDecodingCommands() {
        XCTAssertEqual(AncoSessionCommand(decoding: ":q"), .quit)
        XCTAssertEqual(AncoSessionCommand(decoding: ":ctx 左"), .setContext("左"))
        XCTAssertEqual(
            AncoSessionCommand(decoding: ":ip 3 max_entropy=0.5 min_length=2"),
            .predictInput(count: 3, maxEntropy: 0.5, minLength: 2)
        )
        XCTAssertEqual(
            AncoSessionCommand(decoding: ":tc 3 beam=8 top_k=16"),
            .typoCorrection(.init(
                rawCommand: ":tc 3 beam=8 top_k=16",
                nBest: 3,
                beamSize: 8,
                topK: 16,
                maxSteps: nil,
                alpha: 2.0,
                beta: 3.0,
                gamma: 2.0
            ))
        )
        XCTAssertEqual(AncoSessionCommand(decoding: ":input eot"), .specialInput(.endOfText))
        XCTAssertEqual(AncoSessionCommand(decoding: ":cfg displayTopN=3"), .setConfig(key: "displayTopN", value: "3"))
        XCTAssertEqual(AncoSessionCommand(decoding: ":dump /tmp/history.txt"), .dumpHistory("/tmp/history.txt"))
        XCTAssertEqual(AncoSessionCommand(decoding: ":2"), .selectCandidate(2))
        XCTAssertEqual(AncoSessionCommand(decoding: "かな"), .input("かな"))
    }

    func testDecodingInvalidCommands() {
        XCTAssertNil(AncoSessionCommand(decoding: ":input unknown"))
        XCTAssertNil(AncoSessionCommand(decoding: ":invalid"))
        XCTAssertNil(AncoSessionCommand(decoding: ":cfg"))
        XCTAssertNil(AncoSessionCommand(decoding: ":cfg broken"))
    }

    func testEncodedCommandRoundTrip() {
        let commands: [AncoSessionCommand] = [
            .quit,
            .deleteBackward,
            .clearComposition,
            .nextPage,
            .save,
            .predictInput(count: 3, maxEntropy: 0.5, minLength: 2),
            .help,
            .typoCorrection(.init(
                rawCommand: ":tc 3 beam=8",
                nBest: 3,
                beamSize: 8,
                topK: 100,
                maxSteps: nil,
                alpha: 2.0,
                beta: 3.0,
                gamma: 2.0
            )),
            .setConfig(key: "displayTopN", value: "3"),
            .setContext("左"),
            .specialInput(.endOfText),
            .dumpHistory("/tmp/history.txt"),
            .dumpHistory(nil),
            .selectCandidate(2),
            .input("かな")
        ]

        for command in commands {
            XCTAssertEqual(AncoSessionCommand(decoding: command.encodedCommand), command)
        }
    }

    func testHelpTextContainsRegisteredCommands() {
        XCTAssertTrue(AncoSessionCommand.helpText.contains("== anco session commands =="))
        XCTAssertTrue(AncoSessionCommand.helpText.contains(":q, :quit - quit session"))
        XCTAssertTrue(AncoSessionCommand.helpText.contains(":tc [n] [beam=N] [top_k=N] [max_steps=N] [alpha=F] [beta=F] [gamma=F] - typo correction candidates (LM + channel)"))
        XCTAssertTrue(AncoSessionCommand.helpText.contains(":cfg key=value - update session config"))
        XCTAssertTrue(AncoSessionCommand.helpText.contains(":input %s - insert special characters to input"))
        XCTAssertTrue(AncoSessionCommand.helpText.contains("eot - end of text (for finalizing composition)"))
    }
}
