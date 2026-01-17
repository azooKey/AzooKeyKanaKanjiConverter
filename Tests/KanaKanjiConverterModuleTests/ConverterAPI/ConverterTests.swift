//
//  ConversionTests.swift
//
//
//  Created by miwa on 2023/08/16.
//

@testable import KanaKanjiConverterModule
import XCTest

final class ConverterTests: XCTestCase {
    func dictionaryURL() -> URL {
        Bundle.module.resourceURL!.standardizedFileURL.appendingPathComponent("DictionaryMock", isDirectory: true)
    }
    func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 5,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )
    }

    // 変換されてはいけないケースを示す
    func testMustNotCases() async throws {
        do {
            // 改行文字に対して本当に改行が入ってしまうケース
            let converter = KanaKanjiConverter(dictionaryURL: dictionaryURL())
            var c = ComposingText()
            c.insertAtCursorPosition("\\n", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertFalse(results.mainResults.contains(where: {$0.text == "\n"}))
        }
    }

    private func tmpDir(_ name: String) throws -> URL {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let base = workspace.appendingPathComponent("TestsTmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("AzooKeyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadCharIDs(from dictURL: URL) throws -> [Character: UInt8] {
        let path = dictURL.appendingPathComponent("louds/charID.chid")
        let string = try String(contentsOf: path, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: string.enumerated().map { ($0.element, UInt8($0.offset)) })
    }

    func testUserShortcutsExactMatchConversion() throws {
        // 1) Export user_shortcuts using exportDictionary with system charID mapping
        let userDir = try tmpDir("user-shortcuts")
        defer {
            try? FileManager.default.removeItem(at: userDir)
        }

        let charMap = try loadCharIDs(from: dictionaryURL())
        let entries: [DicdataElement] = [
            DicdataElement(word: "よろしくお願いします", ruby: "ヨロ", lcid: CIDData.固有名詞.cid, rcid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        ]
        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: userDir,
            baseName: "user_shortcuts",
            shardByFirstCharacter: false,
            char2UInt8: charMap
        )

        // 2) Wire converter with DictionaryMock and point sharedContainerURL to userDir
        let converter = KanaKanjiConverter(dictionaryURL: dictionaryURL())
        var c = ComposingText()
        c.insertAtCursorPosition("よろ", inputStyle: .direct)

        let opts = ConvertRequestOptions(
            N_best: 5,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: userDir,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )

        do {
            let results = converter.requestCandidates(c, options: opts)
            XCTAssertTrue(results.mainResults.contains { $0.text == "よろしくお願いします" && $0.isLearningTarget == false })
        }
        do {
            // 「よろし」には反応させない
            c.insertAtCursorPosition("し", inputStyle: .direct)

            let results = converter.requestCandidates(c, options: opts)
            XCTAssertFalse(results.mainResults.contains { $0.text == "よろしくお願いします" && $0.isLearningTarget == false })
        }
    }
}
