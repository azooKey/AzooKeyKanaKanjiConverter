//
//  UnicodeConversionTests.swift
//  azooKeyTests
//
//  Created by ensan on 2022/12/29.
//  Copyright © 2022 ensan. All rights reserved.
//

@testable import KanaKanjiConverterModule
import XCTest

final class UnicodeConversionTests: XCTestCase {
    private func makeDirectInput(direct input: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(input, inputStyle: .direct)
        return c
    }

    func testFromUnicode() async throws {
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "U+3042")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "あ")
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "U+1F607")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "😇")
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "u+3042")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "あ")
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "U3042")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "あ")
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "u3042")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "あ")
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "U+61")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "a")
        }
        do {
            let converter = await KanaKanjiConverter()
            let input = makeDirectInput(direct: "U+189")
            let result = await converter.unicodeCandidates(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "Ɖ")
        }
    }

}
