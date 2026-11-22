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

    func testWholeInputRerankingRequiresRepeatedCorrectionsAcrossWordBoundaries() throws {
        let original = candidate([entry("史実", "シジツ"), entry("移住", "イジュウ")])
        let preferred = candidate([entry("指示", "シジ"), entry("追従", "ツイジュウ")])
        var store = ZenzaiChoiceLearning()
        for _ in 0..<4 {
            XCTAssertTrue(store.record(from: original, to: preferred))
        }
        XCTAssertEqual(store.preferences["シ"]?.first?.contrasts.first?.canRerankWholeInput, false)
        XCTAssertTrue(store.record(from: original, to: preferred))
        XCTAssertEqual(store.preferences["シ"]?.first?.contrasts.first?.canRerankWholeInput, true)
        XCTAssertTrue(store.record(from: preferred, to: original))
        XCTAssertEqual(store.preferences["シ"]?.first?.contrasts.first?.canRerankWholeInput, false)
    }

    func testWholeInputChoiceKeepsAnAlignedPhraseTogetherAfterReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let comparison = entry("比較", "ヒカク")
        let original = candidate([entry("アライ", "アライ"), comparison])
        let selected = candidate([entry("粗い", "アライ"), comparison])
        var store = ZenzaiChoiceLearning()
        XCTAssertTrue(store.configure(directory: directory))
        for _ in 0..<5 {
            XCTAssertTrue(store.recordWholeInput(from: original, to: selected))
        }
        XCTAssertTrue(store.preferences.isEmpty)
        XCTAssertEqual(store.wholeInputPreferences["アライヒカク"]?["アライ比較"]?.preferredText, "粗い比較")
        store.save()

        var reloaded = ZenzaiChoiceLearning()
        XCTAssertTrue(reloaded.configure(directory: directory))
        XCTAssertEqual(reloaded.wholeInputPreferences["アライヒカク"]?["アライ比較"]?.preferredText, "粗い比較")
        XCTAssertTrue(reloaded.recordWholeInput(from: selected, to: original, existingOnly: true))
        XCTAssertTrue(reloaded.wholeInputPreferences.isEmpty)
    }

    func testPrefixSelectionUsesTheSameReadingInTheFullCandidate() throws {
        let name = entry("アライ", "アライ")
        let honorific = entry("さん", "サン")
        let selected = candidate([entry("荒居", "アライ")])
        let original = candidate([name, honorific])
        var store = ZenzaiChoiceLearning()
        for _ in 0..<2 {
            XCTAssertTrue(store.record(from: original, to: selected))
        }
        let preference = try XCTUnwrap(store.preferences["ア"]?.first)
        XCTAssertEqual(preference.reading, "アライ")
        XCTAssertEqual(preference.preferredText, "荒居")
        XCTAssertEqual(preference.contrasts.map(\.rejected), ["アライ"])
    }

    func testPrefixSelectionCountsDistinctAlternativesOncePerSelection() throws {
        let honorific = entry("さん", "サン")
        let primary = candidate([entry("アライ", "アライ"), honorific])
        let alternative = candidate([entry("荒井", "アライ"), honorific])
        let samePrefix = candidate([entry("アライ", "アライ"), entry("サン", "サン")])
        let selected = candidate([entry("荒居", "アライ")])
        let alternatives = [primary, samePrefix, alternative, alternative]
        var store = ZenzaiChoiceLearning()
        XCTAssertTrue(store.record(from: alternatives, to: selected))
        XCTAssertTrue(store.preferences.isEmpty)
        XCTAssertTrue(store.record(from: alternatives, to: selected))
        let contrasts = try XCTUnwrap(store.preferences["ア"]?.first?.contrasts)
        XCTAssertEqual(Set(contrasts.map(\.rejected)), ["アライ", "荒井"])
        for contrast in contrasts {
            XCTAssertEqual(contrast.maximumLogitGap, logf(7.0 / 3.0), accuracy: 0.0001)
        }
    }

    func testPrefixSelectionRequiresABoundaryBeforeRecordingVotes() {
        let original = candidate([entry("は", "ハ"), entry("書かない", "カカナイ")])
        let selected = candidate([entry("葉", "ハ"), entry("可", "カ")])
        var store = ZenzaiChoiceLearning()
        XCTAssertFalse(store.record(from: original, to: selected))
        XCTAssertFalse(store.record(from: original, to: selected))
        XCTAssertTrue(store.preferences.isEmpty)
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

    func testSurnameLearningRespectsAnAttachedVerbEnding() throws {
        let dictionary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let connections = dictionary.appendingPathComponent("cb")
        try FileManager.default.createDirectory(at: connections, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dictionary) }

        let verbCID = 832
        let masuCID = 491
        let surnameCID = CIDData.人名姓.cid
        func saveConnections(from cid: Int, toMasu value: Float) throws {
            var entries: [(Int32, Float)] = [(-1, -5), (Int32(masuCID), value)]
            let data = entries.withUnsafeMutableBytes { Data($0) }
            try data.write(to: connections.appendingPathComponent("\(cid).binary"))
        }
        try saveConnections(from: verbCID, toMasu: -1)
        try saveConnections(from: surnameCID, toMasu: -12)

        let verb = DicdataElement(word: "洗い", ruby: "アライ", cid: verbCID, mid: MIDData.一般.mid, value: -5)
        let surname = DicdataElement(word: "荒居", ruby: "アライ", cid: surnameCID, mid: MIDData.一般.mid, value: -5)
        let masu = DicdataElement(word: "ます", ruby: "マス", cid: masuCID, mid: MIDData.一般.mid, value: -5)
        let honorific = DicdataElement(word: "さん", ruby: "サン", cid: 1302, mid: MIDData.一般.mid, value: -5)
        var store = ZenzaiChoiceLearning()
        for _ in 0..<8 {
            XCTAssertTrue(store.record(from: candidate([verb]), to: candidate([surname])))
        }
        let converter = Kana2Kanji(dicdataStore: .init(dictionaryURL: dictionary))
        let prefix = RegisteredNode(data: verb, registered: .BOSNode(), totalValue: 0, range: .surface(from: 0, to: 3))
        let verbPath = RegisteredNode(data: masu, registered: prefix, totalValue: 0, range: .surface(from: 3, to: 5))
        XCTAssertNil(converter.choiceDraft(from: verbPath, reading: "アライマス", preferences: store.preferences))
        let namePath = RegisteredNode(data: honorific, registered: prefix, totalValue: 0, range: .surface(from: 3, to: 5))
        let (preferred, _) = try XCTUnwrap(converter.choiceDraft(from: namePath, reading: "アライサン", preferences: store.preferences))
        XCTAssertEqual(preferred.getCandidateData().data.map(\.word), ["荒居", "さん"])
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
