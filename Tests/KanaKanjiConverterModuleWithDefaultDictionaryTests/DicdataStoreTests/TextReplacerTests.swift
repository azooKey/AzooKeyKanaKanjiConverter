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
        let emojiFileURL = emojiDictionaryURL.appendingPathComponent("emoji_all_E15.1.txt", isDirectory: false)
        XCTAssertEqual(try! String.init(contentsOf: emojiFileURL, encoding: .utf8).count, 0)

        let textReplacer = TextReplacer.withDefaultEmojiDictionary()
        XCTAssertFalse(textReplacer.isEmpty)
        let searchResult = textReplacer.getSearchResult(query: "カニ", target: [.emoji])
        XCTAssertEqual(searchResult.count, 1)
        XCTAssertEqual(searchResult[0], .init(query: "かに", text: "🦀️"))
    }
}
