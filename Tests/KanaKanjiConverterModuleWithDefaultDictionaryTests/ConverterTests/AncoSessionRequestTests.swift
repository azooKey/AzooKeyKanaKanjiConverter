import Foundation
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class AncoSessionRequestTests: XCTestCase {
    func testDecodingCommands() {
        XCTAssertEqual(AncoSessionRequest(decoding: ":q"), .quit)
        XCTAssertEqual(AncoSessionRequest(decoding: ":ctx 左"), .setContext("左"))
        XCTAssertEqual(
            AncoSessionRequest(decoding: ":ip 3 max_entropy=0.5 min_length=2"),
            .predictInput(count: 3, maxEntropy: 0.5, minLength: 2)
        )
        XCTAssertEqual(
            AncoSessionRequest(decoding: ":tc 3 beam=8 top_k=16"),
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
        XCTAssertEqual(AncoSessionRequest(decoding: ":input eot"), .specialInput(.endOfText))
        XCTAssertEqual(AncoSessionRequest(decoding: ":cfg displayTopN=3"), .setConfig(key: "displayTopN", value: "3"))
        XCTAssertEqual(AncoSessionRequest(decoding: ":dump /tmp/history.txt"), .dumpHistory("/tmp/history.txt"))
        XCTAssertEqual(AncoSessionRequest(decoding: ":2"), .selectCandidate(2))
        XCTAssertEqual(AncoSessionRequest(decoding: "かな"), .input("かな"))
    }

    func testDecodingInvalidCommands() {
        XCTAssertNil(AncoSessionRequest(decoding: ":input unknown"))
        XCTAssertNil(AncoSessionRequest(decoding: ":invalid"))
        XCTAssertNil(AncoSessionRequest(decoding: ":cfg"))
        XCTAssertNil(AncoSessionRequest(decoding: ":cfg broken"))
    }

    func testEncodedCommandRoundTrip() {
        let commands: [AncoSessionRequest] = [
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
            XCTAssertEqual(AncoSessionRequest(decoding: command.encodedCommand), command)
        }
    }
}
