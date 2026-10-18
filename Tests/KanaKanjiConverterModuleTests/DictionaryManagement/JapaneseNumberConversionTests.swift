//
//  JapaneseNumberConversionTests.swift
//  KanaKanjiConverterModuleTests
//
//  Created by ensan on 2023/04/18.
//  Copyright © 2023 ensan. All rights reserved.
//

@testable import KanaKanjiConverterModule
import XCTest

final class JapaneseNumberConversionTests: XCTestCase {
    func testJapaneseNumberConversion() throws {
        let dicdataStore = DicdataStore(dictionaryURL: URL(fileURLWithPath: ""))
        do {
            let result = dicdataStore.getJapaneseNumberDicdata(head: "イチマン")
            XCTAssertEqual(result.count, 2)
            XCTAssertTrue(result.contains(where: {$0.word == "一万"}))
            XCTAssertTrue(result.contains(where: {$0.word == "10000"}))
        }
        do {
            let result = dicdataStore.getJapaneseNumberDicdata(head: "ニオクロクセンヨンヒャクマンキュウ")
            XCTAssertEqual(result.count, 2)
            XCTAssertTrue(result.contains(where: {$0.word == "二億六千四百万九"}))
            XCTAssertTrue(result.contains(where: {$0.word == "264000009"}))
        }
        do {
            // 「シ」の先読みで後続文字を消費しないことと、「シチ」の分岐を確認する。
            for (reading, kanji, number) in [
                ("シ", "四", "4"),
                ("シチ", "七", "7"),
                ("シマル", "四〇", "40"),
                ("シジュウ", "四十", "40")
            ] {
                let result = dicdataStore.getJapaneseNumberDicdata(head: reading)
                XCTAssertEqual(result.map(\.word), [kanji, number], reading)
            }
            XCTAssertTrue(dicdataStore.getJapaneseNumberDicdata(head: "シマエル").isEmpty)
        }
        do {
            XCTAssertEqual(dicdataStore.getJapaneseNumberDicdata(head: "マルマン").count, 0)
            XCTAssertEqual(dicdataStore.getJapaneseNumberDicdata(head: "アマン").count, 0)
            XCTAssertEqual(dicdataStore.getJapaneseNumberDicdata(head: "イチリン").count, 0)
            XCTAssertEqual(dicdataStore.getJapaneseNumberDicdata(head: "ニムリョウタイスウサンガイ").count, 0)
        }
    }
}
