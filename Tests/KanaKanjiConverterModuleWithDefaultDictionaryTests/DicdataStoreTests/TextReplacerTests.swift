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
        XCTAssertEqual(Bundle.module.resourceURL!.path(), "")
        XCTAssertFalse(try! FileManager.default.contentsOfDirectory(atPath: Bundle.module.resourceURL!.path()).isEmpty)
        XCTAssertTrue(try! FileManager.default.contentsOfDirectory(atPath: Bundle.module.resourceURL!.path()).isEmpty)

        let textReplacer = TextReplacer.withDefaultEmojiDictionary()
        XCTAssertFalse(textReplacer.isEmpty)
        let searchResult = textReplacer.getSearchResult(query: "カニ", target: [.emoji])
        XCTAssertEqual(searchResult.count, 1)
        XCTAssertEqual(searchResult[0], .init(query: "かに", text: "🦀️"))
    }
}
