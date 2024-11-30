//
//  File.swift
//  AzooKeyKanakanjiConverter
//
//  Created by MiwaKeita on 2024/10/26.
//

@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class TextReplacerTests: XCTestCase {
    func testEmojiTextReplacer() throws {
        // For debugging
        XCTAssertEqual(Bundle.module.resourceURL, nil)
        let resourcesURL = Bundle.module.resourceURL!
        let emojiDictionaryURL = resourcesURL.appendingPathComponent("EmojiDictionary", isDirectory: true)
        XCTAssertEqual(try! FileManager.default.contentsOfDirectory(at: emojiDictionaryURL, includingPropertiesForKeys: nil), [])
        XCTAssertNotEqual(try! FileManager.default.contentsOfDirectory(at: emojiDictionaryURL, includingPropertiesForKeys: nil), [])
        XCTAssertEqual(try! FileManager.default.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: nil), [])

        let textReplacer = TextReplacer.withDefaultEmojiDictionary()
        XCTAssertFalse(textReplacer.isEmpty)
        let searchResult = textReplacer.getSearchResult(query: "カニ", target: [.emoji])
        XCTAssertEqual(searchResult.count, 1)
        XCTAssertEqual(searchResult[0], .init(query: "かに", text: "🦀️"))
    }
}
