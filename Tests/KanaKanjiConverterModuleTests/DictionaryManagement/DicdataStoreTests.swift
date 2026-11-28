@testable import KanaKanjiConverterModule
import SwiftUtils
import XCTest

final class DicdataStoreTests: XCTestCase {
    private func tmpDir(_ name: String) throws -> URL {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let base = workspace.appendingPathComponent("TestsTmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("AzooKeyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func charMap(_ chars: [Character]) -> [Character: UInt8] {
        var map: [Character: UInt8] = [:]
        var next: UInt8 = 1
        for c in chars {
            if map[c] == nil {
                map[c] = next
                next += 1
            }
        }
        return map
    }

    private func toIDs(_ s: String, _ map: [Character: UInt8]) -> [UInt8] {
        s.compactMap { map[$0] }
    }

    private var dictionaryMockURL: URL {
        Bundle.module.resourceURL!.appendingPathComponent("DictionaryMock", isDirectory: true)
    }

    func testExportUserDictionaryAndReadViaDicdataStore() throws {
        // 1) Prepare sample user entries and export via DictionaryBuilder.exportDictionary
        let userDir = try tmpDir("user-export")
        defer {
            try? FileManager.default.removeItem(at: userDir)
        }

        let entries: [DicdataElement] = [
            DicdataElement(word: "亜", ruby: "あ", lcid: 10, rcid: 10, mid: 1, value: -100),
            DicdataElement(word: "阿", ruby: "あ", lcid: 10, rcid: 10, mid: 2, value: -90),
            DicdataElement(word: "蚊", ruby: "か", lcid: 13, rcid: 13, mid: 6, value: -50)
        ]
        let chars: [Character] = Array(entries.flatMapSet { Array($0.ruby) }).sorted()
        let cmap = charMap(chars)

        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: userDir,
            baseName: "user",
            shardByFirstCharacter: false,
            char2UInt8: cmap
        )

        // 2) Wire DicdataStore with DictionaryMock as system dictionary, but point user URL to our export
        let store = DicdataStore(dictionaryURL: dictionaryMockURL)
        let state = store.prepareState()
        state.updateUserDictionaryURL(userDir, forceReload: false)

        // 3) Load LOUDS for user via store and get node index using the same char-map used to export
        guard let louds = store.loadLOUDS(query: "user", state: state) else {
            return XCTFail("Failed to load LOUDS for user")
        }
        // Perfect match for ruby "あ"
        let idsA = toIDs("あ", cmap)
        guard let indexA = louds.searchNodeIndex(chars: idsA) else {
            return XCTFail("searchNodeIndex failed for user ruby 'あ'")
        }

        // 4) Fetch dicdata via DicdataStore API and validate entries + metadata
        let got = store.getDicdataFromLoudstxt3(identifier: "user", indices: [indexA], state: state)
        let wordsA = Set(got.filter { $0.ruby == "あ" }.map { $0.word })
        XCTAssertTrue(wordsA.isSuperset(of: ["亜", "阿"]))
        // User dictionary entries should carry isFromUserDictionary metadata
        XCTAssertTrue(got.allSatisfy { $0.metadata.contains(.isFromUserDictionary) })

        // 5) Also check ruby "か"
        if let indexK = louds.searchNodeIndex(chars: toIDs("か", cmap)) {
            let v = store.getDicdataFromLoudstxt3(identifier: "user", indices: [indexK], state: state)
            XCTAssertTrue(v.contains { $0.ruby == "か" && $0.word == "蚊" })
        } else {
            XCTFail("searchNodeIndex failed for user ruby 'か'")
        }
    }
    /// A bound on the LOUDS cache must change memory only: lookups give the same answers as an
    /// unbounded store, while the cache stays within the bound and drops the least recently used.
    func testBoundedLOUDSCacheKeepsResultsAndStaysWithinBudget() throws {
        let dictionary = try tmpDir("bounded-cache")
        defer {
            try? FileManager.default.removeItem(at: dictionary)
        }
        let leads: [Character] = ["あ", "い", "う", "え", "お", "か"]
        let tails: [Character] = ["あ", "い", "う", "え", "お", "か", "き", "く"]
        let cmap = charMap(leads + tails)
        // `charID.chid` gives each character the id of its position, so position 0 is a placeholder.
        let chid = "★" + String(cmap.sorted { $0.value < $1.value }.map(\.key))
        var entries: [DicdataElement] = []
        for lead in leads {
            for a in tails {
                for b in tails {
                    entries.append(DicdataElement(word: "\(lead)\(a)\(b)語", ruby: "\(lead)\(a)\(b)", lcid: 10, rcid: 10, mid: 1, value: -50))
                }
            }
        }
        let loudsDirectory = dictionary.appendingPathComponent("louds", isDirectory: true)
        try FileManager.default.createDirectory(at: loudsDirectory, withIntermediateDirectories: true)
        try chid.write(to: loudsDirectory.appendingPathComponent("charID.chid"), atomically: true, encoding: .utf8)
        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: loudsDirectory,
            baseName: "",
            shardByFirstCharacter: true,
            char2UInt8: cmap
        )

        let unbounded = DicdataStore(dictionaryURL: dictionary)
        let unboundedState = unbounded.prepareState()
        let oneStructure = try XCTUnwrap(unbounded.loadLOUDS(query: "あ", state: unboundedState)).byteCount
        // Room for two of the six prefixes.
        let budget = oneStructure * 2 + oneStructure / 2
        let bounded = DicdataStore(dictionaryURL: dictionary, maxCachedLOUDSBytes: budget)
        let boundedState = bounded.prepareState()

        for _ in 0..<3 {
            for lead in leads {
                let ruby = "\(lead)\(tails[2])\(tails[5])"
                let ids = ruby.compactMap { cmap[$0] }
                let expected = unbounded.perfectMatchingSearch(query: String(lead), charIDs: ids, state: unboundedState)
                let got = bounded.perfectMatchingSearch(query: String(lead), charIDs: ids, state: boundedState)
                XCTAssertFalse(expected.isEmpty, "\(ruby) is in the dictionary")
                XCTAssertEqual(got, expected, "\(ruby)")
                XCTAssertLessThanOrEqual(bounded.currentCachedLOUDSBytes, budget)
                XCTAssertTrue(bounded.cachedLOUDSQueries.contains(String(lead)), "the prefix just used stays cached")
                XCTAssertLessThanOrEqual(bounded.cachedLOUDSQueries.count, 2)
            }
        }
        XCTAssertEqual(unbounded.cachedLOUDSQueries.count, leads.count, "without a bound everything stays cached")
    }
}
