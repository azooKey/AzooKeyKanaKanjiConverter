//
//  WarekiConversionTests.swift
//  azooKeyTests
//
//  Created by ensan on 2022/12/22.
//  Copyright © 2022 ensan. All rights reserved.
//

@testable import KanaKanjiConverterModule
import XCTest

final class WarekiConversionTests: XCTestCase {
    private func makeDirectInput(direct input: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(input, inputStyle: .direct)
        return c
    }

    func testSeireki2Wareki() async throws {
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "2019ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertEqual(result.count, 2)
            if result.count == 2 {
                XCTAssertEqual(result[0].text, "令和元年")
                XCTAssertEqual(result[1].text, "平成31年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "2020ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "令和2年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "2001ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "平成13年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "1945ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "昭和20年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "9999ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "令和7981年")
            }
        }

        // invalid cases
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "せいれき2001ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertTrue(result.isEmpty)
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "1582ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertTrue(result.isEmpty)
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "10000ねん")
            let result = await converter.toWarekiCandidates(input)
            XCTAssertTrue(result.isEmpty)
        }

    }

    func testWareki2Seireki() async throws {
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "れいわがんねん")
            let result = await converter.toSeirekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "2019年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "れいわ1ねん")
            let result = await converter.toSeirekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "2019年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "しょうわ25ねん")
            let result = await converter.toSeirekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "1950年")
            }
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "めいじ9ねん")
            let result = await converter.toSeirekiCandidates(input)
            XCTAssertEqual(result.count, 1)
            if result.count == 1 {
                XCTAssertEqual(result[0].text, "1876年")
            }
        }

        // invalid cases
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "れいわ100ねん")
            let result = await converter.toSeirekiCandidates(input)
            XCTAssertTrue(result.isEmpty)
        }

        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "けいおう5ねん")
            let result = await converter.toSeirekiCandidates(input)
            XCTAssertTrue(result.isEmpty)
        }
    }
}
