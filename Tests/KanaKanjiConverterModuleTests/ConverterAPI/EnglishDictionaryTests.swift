@testable import KanaKanjiConverterModule
import XCTest

final class EnglishDictionaryTests: XCTestCase {
    private func withDictionary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EnglishDictionary-\(UUID().uuidString)")
        let source = Bundle.module.resourceURL!.appendingPathComponent("DictionaryMock")
        try FileManager.default.copyItem(at: source, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let louds = url.appendingPathComponent("louds")
        let chars = try String(contentsOf: louds.appendingPathComponent("charID.chid"), encoding: .utf8)
        let map = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($0.element, UInt8($0.offset)) })
        let entries = [
            DicdataElement(word: "GitHub", ruby: "GitHub", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "GitLab", ruby: "GitLab", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10),
            DicdataElement(word: "github", ruby: "github", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -9),
            DicdataElement(word: "QzEnglishFixture", ruby: "QzEnglishFixture", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -1),
            // 同じ表記が複数エントリにあっても、候補はスコアの高い一件にする。
            DicdataElement(word: "GitHub", ruby: "GitHub", cid: CIDData.固有名詞.cid, mid: MIDData.組織.mid, value: -12),
            DicdataElement(word: "ギット", ruby: "Git", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -1)
        ]
        try DictionaryBuilder.exportDictionary(entries: entries, to: louds, baseName: "", shardByFirstCharacter: true, char2UInt8: map)
        try body(url)
    }

    func testCaseSensitivePrefixAndExactMatchPreserveSurfaceAndScore() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            let prefix = converter.getEnglishDictionaryCandidates(ruby: "Git", inputCount: 3, penalty: -5)
            XCTAssertEqual(prefix.map(\.text), ["GitHub", "GitLab"])
            XCTAssertEqual(prefix.first?.value, -13)
            XCTAssertEqual(prefix.first?.composingCount, .inputCount(3))
            XCTAssertEqual(prefix.first?.data.first?.ruby, "GitHub")
            XCTAssertEqual(prefix.first?.data.first?.value(), -8)
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "GitHub", inputCount: 6, penalty: -5).map(\.text), ["GitHub"])
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "git", inputCount: 3, penalty: -5).map(\.text), ["github"])
            XCTAssertTrue(converter.getEnglishDictionaryCandidates(ruby: "GIT", inputCount: 3, penalty: -5).isEmpty)
            for key in ["", "Git4", "ギット", "café"] {
                XCTAssertTrue(converter.getEnglishDictionaryCandidates(ruby: key, inputCount: key.count, penalty: -5).isEmpty)
            }
        }
    }

    private func options(at url: URL, english: ConvertRequestOptions.PredictionMode, roman: Bool) -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10, requireJapanesePrediction: .disabled, requireEnglishPrediction: english,
            keyboardLanguage: .en_US, englishCandidateInRoman2KanaInput: roman,
            learningType: .nothing, memoryDirectoryURL: url, sharedContainerURL: url,
            textReplacer: .empty, specialCandidateProviders: [], metadata: nil
        )
    }

    func testDictionaryCandidatesReachEnglishPredictionAndRespectDisabledMode() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            var input = ComposingText()
            input.insertAtCursorPosition("QzEng", inputStyle: .direct)
            let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
            XCTAssertTrue(result.englishPredictionResults.contains { $0.text == "QzEnglishFixture" })
            XCTAssertFalse(result.mainResults.contains { $0.text == "QzEnglishFixture" })
            let mixed = converter.requestCandidates(input, options: options(at: url, english: .autoMix, roman: false))
            XCTAssertTrue(mixed.englishPredictionResults.contains { $0.text == "QzEnglishFixture" })
            XCTAssertTrue(mixed.mainResults.contains { $0.text == "QzEnglishFixture" })
            let disabled = converter.requestCandidates(input, options: options(at: url, english: .disabled, roman: false))
            XCTAssertTrue(disabled.englishPredictionResults.isEmpty)
            XCTAssertFalse(disabled.mainResults.contains { $0.text == "QzEnglishFixture" })
        }
    }

    func testDictionaryCandidatesReachRomanInputMixing() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            var input = ComposingText()
            input.insertAtCursorPosition("QzEng", inputStyle: .roman2kana)
            var request = options(at: url, english: .disabled, roman: true)
            request.keyboardLanguage = .ja_JP
            let result = converter.requestCandidates(input, options: request)
            XCTAssertTrue(result.mainResults.contains { $0.text == "QzEnglishFixture" })
        }
    }
}
