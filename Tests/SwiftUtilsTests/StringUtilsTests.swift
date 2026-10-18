//
//  StringUtilsTests.swift
//  KanaKanjiConverterModuleTests
//
//  Created by ensan on 2022/12/18.
//  Copyright © 2022 ensan. All rights reserved.
//

@testable import SwiftUtils
import XCTest

final class StringTests: XCTestCase {
    func testEnglishDictionaryWordsAndPrefixes() {
        for word in ["GitHub", "gpt4", "GPT-4", "Wi-Fi", "3M", "A-1-B", "a1b2", "don't", "don’t", "I'm", "O'Reilly", "dogs'", "dogs’", "AT&T", "R&D", "U.S.", "Node.js", "v1.2", "New York", "new york", "GPT 4", "U.S. Army", "dogs' food", "AT&T Inc.", "3M Company", "Area 51", "Yahoo!", "Who?", "Hello, World", "Key:Value", "Steins;Gate", "key=value", "Hello,", "Note:", "End;", "Key=", "Ready! Go", "Why? Not", "Data; Next", "Key= Value", "-GPT", "GPT-", "GPT--4", "'word", "’word", "&word", ".word", "word&", "word..x", "word&&x", "word''x", "word’’x", "word.-x", "word.&x", "word’&x", " New York", "New York ", "New  York", "New- York", "New &York", "New .York", "!Word", "Word!!", "Word!?", "Word::Value", "Word==Value", "Word,  Next", ".NET", "=LOVE", "Yahoo!!", "!?Word", " Word ", "  Word  ", "& Word", "R & D"] {
            XCTAssertTrue(word.isEnglishDictionaryWord, word)
            XCTAssertTrue(word.isEnglishDictionaryPrefix, word)
        }
        for word in ["", "123", "123-456", "3.14", "café", "ＧＰＴ", "GPT−4", "GPT_4", "日本", "GPT-4\n", "&", "'", "’", ".", "...", "New\tYork", "New\nYork", "New\u{00a0}York", "New　York", "123 456", " ", "!", "?", ",", ":", ";", "=", "123!", "Word！", "Word？", "Word，", "Word：", "Word；", "Word＝", "Word;\tNext"] {
            XCTAssertFalse(word.isEnglishDictionaryWord, word)
        }
        for prefix in ["3", "123-", "gpt-", "don'", "AT&", "new ", "=", ".", "!", " ", "  ", "!?", "Word=="] {
            XCTAssertTrue(prefix.isEnglishDictionaryPrefix, prefix)
        }
        for prefix in ["", "café", "Word_", "New\tYork", "New\nYork", "New　York"] {
            XCTAssertFalse(prefix.isEnglishDictionaryPrefix, prefix)
        }
    }

    func testIsKana() throws {
        XCTAssertTrue("あ".isKana)
        XCTAssertTrue("ぁ".isKana)
        XCTAssertTrue("ン".isKana)
        XCTAssertTrue("ァ".isKana)
        XCTAssertTrue("が".isKana)
        XCTAssertTrue("ゔ".isKana)

        XCTAssertFalse("k".isKana)
        XCTAssertFalse("@".isKana)
        XCTAssertFalse("ｶ".isKana)  // 半角カタカナはカナ扱いしない
    }

    func testOnlyRomanAlphabetOrNumber() throws {
        XCTAssertTrue("and13".onlyRomanAlphabetOrNumber)
        XCTAssertTrue("vmaoNFIU".onlyRomanAlphabetOrNumber)
        XCTAssertTrue("1332".onlyRomanAlphabetOrNumber)

        // 文字がない場合はfalse
        XCTAssertFalse("".onlyRomanAlphabetOrNumber)
        XCTAssertFalse("and 13".onlyRomanAlphabetOrNumber)
        XCTAssertFalse("can't".onlyRomanAlphabetOrNumber)
        XCTAssertFalse("Mt.".onlyRomanAlphabetOrNumber)
    }

    func testOnlyRomanAlphabet() throws {
        XCTAssertTrue("vmaoNFIU".onlyRomanAlphabet)
        XCTAssertTrue("NAO".onlyRomanAlphabet)

        // 文字がない場合はfalse
        XCTAssertFalse("".onlyRomanAlphabet)
        XCTAssertFalse("and 13".onlyRomanAlphabet)
        XCTAssertFalse("can't".onlyRomanAlphabet)
        XCTAssertFalse("Mt.".onlyRomanAlphabet)
        XCTAssertFalse("and13".onlyRomanAlphabet)
        XCTAssertFalse("vmaoNFIU83942".onlyRomanAlphabet)
    }

    func testContainsRomanAlphabet() throws {
        XCTAssertTrue("vmaoNFIU".containsRomanAlphabet)
        XCTAssertTrue("変数x".containsRomanAlphabet)
        XCTAssertTrue("and 13".containsRomanAlphabet)
        XCTAssertTrue("can't".containsRomanAlphabet)
        XCTAssertTrue("Mt.".containsRomanAlphabet)
        XCTAssertTrue("(^v^)".containsRomanAlphabet)

        // 文字がない場合はfalse
        XCTAssertFalse("".containsRomanAlphabet)
        XCTAssertFalse("!?!?".containsRomanAlphabet)
        XCTAssertFalse("(^_^)".containsRomanAlphabet)
        XCTAssertFalse("問題ア".containsRomanAlphabet)
    }

    func testIsEnglishSentence() throws {
        XCTAssertTrue("Is this an English sentence?".isEnglishSentence)
        XCTAssertTrue("English sentences can include symbols like '!?/\\=-+^`{}()[].".isEnglishSentence)

        // 文字がない場合はfalse
        XCTAssertFalse("".isEnglishSentence)
        XCTAssertFalse("The word '変数' is not an English word.".isEnglishSentence)
        XCTAssertFalse("これは完全に日本語の文章です".isEnglishSentence)
    }

    func testToKatakana() throws {
        XCTAssertEqual("あいうえお".toKatakana(), "アイウエオ")
        XCTAssertEqual("これは日本語の文章です".toKatakana(), "コレハ日本語ノ文章デス")
        XCTAssertEqual("えモじ😇".toKatakana(), "エモジ😇")
    }

    func testToHiragana() throws {
        XCTAssertEqual("アイウエオ".toHiragana(), "あいうえお")
        XCTAssertEqual("僕はロボットです".toHiragana(), "僕はろぼっとです")
        XCTAssertEqual("えモじ😇".toHiragana(), "えもじ😇")
    }

    func testPerformanceExample() throws {
    }
}
