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
        XCTAssertFalse(try! FileManager.default.contentsOfDirectory(atPath: String(Bundle.module.resourceURL!.path().dropFirst())).isEmpty)
        XCTAssertTrue(try! FileManager.default.contentsOfDirectory(atPath:String(Bundle.module.resourceURL!.path().dropFirst())).isEmpty)

        let textReplacer = TextReplacer.withDefaultEmojiDictionary()
        XCTAssertFalse(textReplacer.isEmpty)
        let searchResult = textReplacer.getSearchResult(query: "カニ", target: [.emoji])
        XCTAssertEqual(searchResult.count, 1)
        XCTAssertEqual(searchResult[0], .init(query: "かに", text: "🦀️"))
    }
}
