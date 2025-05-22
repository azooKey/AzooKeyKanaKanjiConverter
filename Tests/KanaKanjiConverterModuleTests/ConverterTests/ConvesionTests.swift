//
//  ConversionTests.swift
//  
//
//  Created by miwa on 2023/08/16.
//

import XCTest
@testable import KanaKanjiConverterModule

final class ConverterTests: XCTestCase {
    func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 5,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            typographyLetterCandidate: false,
            unicodeCandidate: true,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            dictionaryResourceURL: Bundle(for: type(of: self)).bundleURL.appendingPathComponent("DictionaryMock", isDirectory: true),
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            metadata: nil
        )
    }

    // 変換されてはいけないケースを示す
    func testMustNotCases() async throws {
        do {
            // 改行文字に対して本当に改行が入ってしまうケース
            let converter = KanaKanjiConverter()
            var c = ComposingText()
            c.insertAtCursorPosition("\\n", inputStyle: .direct)
            let results = await converter.requestCandidatesAsync(c, options: requestOptions())
            XCTAssertFalse(results.mainResults.contains(where: {$0.text == "\n"}))
        }
    }

}
