import Foundation
@testable import KanaKanjiConverterModule
import XCTest

@MainActor
final class TemplateConversionTests: XCTestCase {
    func requestOptions() -> ConvertRequestOptions {
        .default
    }

    func testTemplateConversion() async throws {
        let converter = KanaKanjiConverter.withoutDictionary()
        let template = #"<date format="yyyy年MM月dd日" type="western" language="ja_JP" delta="0" deltaunit="1">"#
        converter.importDynamicUserDictionary([
            .init(word: template, ruby: "キョウ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 5)
        ])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年MM月dd日"
        formatter.calendar = Calendar(identifier: .gregorian)
        let todayString = formatter.string(from: Date())

        do {
            var c = ComposingText()
            c.insertAtCursorPosition("きょう", inputStyle: .direct)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertTrue(results.mainResults.contains(where: { $0.text == todayString}))
            XCTAssertFalse(results.mainResults.contains(where: { $0.text == template}))
            XCTAssertFalse(results.firstClauseResults.contains(where: { $0.text == template}))
            converter.stopComposition()
        }

        do {
            var c = ComposingText()
            c.insertAtCursorPosition("kyou", inputStyle: .roman2kana)
            let results = converter.requestCandidates(c, options: requestOptions())
            XCTAssertTrue(results.mainResults.contains(where: { $0.text == todayString}))
            XCTAssertFalse(results.mainResults.contains(where: { $0.text == template}))
            XCTAssertFalse(results.firstClauseResults.contains(where: { $0.text == template}))
            converter.stopComposition()
        }
    }
}
