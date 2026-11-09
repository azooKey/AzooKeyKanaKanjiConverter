import Foundation
@testable import KanaKanjiConverterModule
import XCTest

final class ZenzaiChoiceLearningTests: XCTestCase {
    private func entry(_ word: String, _ ruby: String) -> DicdataElement {
        .init(word: word, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    }

    private func candidate(_ data: [DicdataElement]) -> Candidate {
        .init(text: data.map(\.word).joined(), value: 0, composingCount: .surfaceCount(data.map(\.ruby).joined().count),
              lastMid: MIDData.一般.mid, data: data)
    }

    func testMultipleCorrectionsComposeOnANewReading() throws {
        let first = entry("斎藤", "サイトウ")
        let firstChoice = [entry("齋", "サイ"), entry("藤", "トウ")]
        let second = entry("高橋", "タカハシ")
        let secondChoice = entry("髙橋", "タカハシ")
        let separator = entry("と", "ト")
        var store = ZenzaiChoiceLearning()
        for _ in 0..<2 {
            XCTAssertTrue(store.record(from: candidate([first, separator]), to: candidate(firstChoice + [separator])))
            XCTAssertTrue(store.record(from: candidate([second]), to: candidate([secondChoice])))
        }
        let standardPath = [first, separator, second]
        let reading = standardPath.map(\.ruby).joined()
        var offset = 0
        let draft = standardPath.reduce(RegisteredNode.BOSNode()) { node, element in
            let start = offset
            offset += element.ruby.count
            return RegisteredNode(data: element, registered: node, totalValue: 0, range: .input(from: start, to: offset))
        }
        let converter = Kana2Kanji(dicdataStore: .init(dictionaryURL: URL(fileURLWithPath: "/dev/null")))
        let (preferred, edits) = try XCTUnwrap(converter.choiceDraft(from: draft, reading: reading, preferences: store.preferences))
        XCTAssertEqual(preferred.getCandidateData().data.map(\.word), ["齋", "藤", "と", "髙橋"])
        XCTAssertEqual(edits.flatMap(\.contrasts).map(\.rejected), ["斎藤", "高橋"])
        XCTAssertEqual(edits.map(\.range), [0..<6, 9..<15])
    }

    func testEqualEvidenceCancelsAndOneSelectionCannotVoteTwice() {
        let standard = entry("斎藤", "サイトウ")
        let variant = entry("齋藤", "サイトウ")
        var store = ZenzaiChoiceLearning()
        XCTAssertTrue(store.record(from: candidate([standard, standard]), to: candidate([variant, variant])))
        XCTAssertTrue(store.preferences.isEmpty)
        XCTAssertTrue(store.record(from: candidate([standard]), to: candidate([variant])))
        XCTAssertEqual(store.preferences["サ"]?.first?.contrasts.count, 1)
        XCTAssertTrue(store.record(from: candidate([variant]), to: candidate([standard])))
        XCTAssertTrue(store.preferences.isEmpty)
    }

    func testSameSurfaceKeepsTheVotesAgainstEachAlternative() throws {
        let first = candidate([entry("新井", "アライ")])
        let second = candidate([entry("荒井", "アライ")])
        let preferred = candidate([entry("荒居", "アライ")])
        var store = ZenzaiChoiceLearning()
        for _ in 0..<3 {
            XCTAssertTrue(store.record(from: first, to: preferred))
        }
        for _ in 0..<5 {
            XCTAssertTrue(store.record(from: second, to: preferred))
        }
        let preferences = try XCTUnwrap(store.preferences["ア"])
        XCTAssertEqual(preferences.count, 1)
        XCTAssertEqual(preferences[0].preferredText, "荒居")
        let gaps = Dictionary(uniqueKeysWithValues: preferences[0].contrasts.map { ($0.rejected, $0.maximumLogitGap) })
        XCTAssertEqual(try XCTUnwrap(gaps["新井"]), logf(4), accuracy: 0.0001)
        XCTAssertEqual(gaps["荒井"], .infinity)
        XCTAssertLessThan(ZenzaiChoiceLearning.Contrast.maximumLogitGap(votes: 4), 5.33)
    }

    func testAReadingPrefixDoesNotMatchAnUnobservedAlternative() {
        let rejected = entry("は書", "ハカ")
        let preferred = entry("は可", "ハカ")
        var store = ZenzaiChoiceLearning()
        for _ in 0..<8 {
            XCTAssertTrue(store.record(from: candidate([rejected]), to: candidate([preferred])))
        }
        let particle = entry("は", "ハ")
        let verb = entry("書かない", "カカナイ")
        let head = RegisteredNode(data: particle, registered: .BOSNode(), totalValue: 0, range: .input(from: 0, to: 1))
        let path = RegisteredNode(data: verb, registered: head, totalValue: 0, range: .input(from: 1, to: 5))
        let converter = Kana2Kanji(dicdataStore: .init(dictionaryURL: URL(fileURLWithPath: "/dev/null")))
        XCTAssertNil(converter.choiceDraft(from: path, reading: "ハカカナイ", preferences: store.preferences))
    }

    func testPersistenceAndForget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let standard = candidate([entry("斎藤", "サイトウ")])
        let preferred = candidate([entry("齋藤", "サイトウ")])
        var store = ZenzaiChoiceLearning()
        XCTAssertTrue(store.configure(directory: directory))
        for _ in 0..<2 {
            XCTAssertTrue(store.record(from: standard, to: preferred))
        }
        store.save()

        var reloaded = ZenzaiChoiceLearning()
        XCTAssertTrue(reloaded.configure(directory: directory))
        XCTAssertEqual(reloaded.preferences["サ"]?.first?.contrasts.first?.rejected, "斎藤")
        reloaded.forget(preferred)
        XCTAssertTrue(reloaded.preferences.isEmpty)
        var afterForget = ZenzaiChoiceLearning()
        XCTAssertTrue(afterForget.configure(directory: directory))
        XCTAssertTrue(afterForget.preferences.isEmpty)
    }
}
