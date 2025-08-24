@testable import KanaKanjiConverterModule
import SwiftUtils
import XCTest

final class DictionaryBuilderTests: XCTestCase {
    // Simple, obvious helpers/consts for clarity
    private let rowBytes = 10
    private func shardComponents(_ nodeIndex: Int) -> (shard: Int, local: Int) {
        let per = DictionaryBuilder.entriesPerShard
        return (nodeIndex / per, nodeIndex % per)
    }

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
        var next: UInt8 = 1 // 0 is reserved in LOUDS
        for c in chars {
            if map[c] == nil {
                map[c] = next; next &+= 1
            }
        }
        return map
    }

    private func toIDs(_ s: String, _ map: [Character: UInt8]) -> [UInt8] {
        s.compactMap { map[$0] }
    }

    private func sampleEntries() -> [DicdataElement] {
        [
            // あ
            DicdataElement(word: "亜", ruby: "あ", lcid: 10, rcid: 10, mid: 1, value: -100),
            DicdataElement(word: "阿", ruby: "あ", lcid: 10, rcid: 10, mid: 2, value: -90),
            // あい
            DicdataElement(word: "愛", ruby: "あい", lcid: 11, rcid: 11, mid: 3, value: -80),
            DicdataElement(word: "藍", ruby: "あい", lcid: 11, rcid: 11, mid: 4, value: -70),
            // い
            DicdataElement(word: "胃", ruby: "い", lcid: 12, rcid: 12, mid: 5, value: -60),
            // か
            DicdataElement(word: "蚊", ruby: "か", lcid: 13, rcid: 13, mid: 6, value: -50)
        ]
    }

    // loudstxt3 header helpers
    private func headerCount(_ data: Data) -> Int {
        Int(data[data.startIndex]) | (Int(data[data.startIndex + 1]) << 8)
    }

    private func headerOffsets(_ data: Data) -> [Int] {
        let count = headerCount(data)
        var out: [Int] = []
        out.reserveCapacity(count)
        let base = data.startIndex + 2
        for i in 0 ..< count {
            let b0 = Int(data[base + i * 4 + 0])
            let b1 = Int(data[base + i * 4 + 1])
            let b2 = Int(data[base + i * 4 + 2])
            let b3 = Int(data[base + i * 4 + 3])
            out.append(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
        }
        return out
    }

    private func entrySlice(_ data: Data, _ i: Int) -> Data {
        let offs = headerOffsets(data)
        let start = offs[i]
        let end = (i == offs.count - 1) ? data.count : offs[i + 1]
        return data[start..<end]
    }

    private func assertExists(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing file: \(url.path)", file: file, line: line)
    }

    func testExportAndLoadUserDictionary_RoundTrip() throws {
        let dir = try tmpDir("userdict")
        defer {
            try? FileManager.default.removeItem(at: dir)
        }

        let entries = sampleEntries()
        let chars: [Character] = Array(entries.flatMapSet { Array($0.ruby) }).sorted()
        let cmap = charMap(chars)

        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: dir,
            baseName: "user",
            shardByFirstCharacter: false,
            char2UInt8: cmap
        )

        // LOUDS
        guard let louds = LOUDS.loadUserDictionary(userDictionaryURL: dir) else {
            XCTFail("Failed to load exported user LOUDS")
            return
        }

        // Verify each ruby is searchable and its shard contains expected words
        for ruby in ["あ", "あい", "い", "か"] {
            let ids = toIDs(ruby, cmap)
            guard let nodeIndex = louds.searchNodeIndex(chars: ids) else {
                XCTFail("searchNodeIndex failed for \(ruby)")
                continue
            }
            let (shard, local) = shardComponents(nodeIndex)
            let dic = LOUDS.getUserDictionaryDataForLoudstxt3("user\(shard)", indices: [local], userDictionaryURL: dir)
            let words = dic.filter { $0.ruby == ruby }.map { $0.word }
            XCTAssertFalse(words.isEmpty, "No words for ruby \(ruby)")
        }
    }

    func testExportShardByFirstChar_RoundTrip() throws {
        // Create a parent dir with nested "louds" to match LOUDS.load expectations
        let parent = try tmpDir("default-sharded")
        defer {
            try? FileManager.default.removeItem(at: parent)
        }
        let loudsDir = parent.appendingPathComponent("louds", isDirectory: true)
        try FileManager.default.createDirectory(at: loudsDir, withIntermediateDirectories: true)

        let entries = sampleEntries()
        let chars: [Character] = Array(entries.flatMapSet { Array($0.ruby) }).sorted()
        let cmap = charMap(chars)

        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: loudsDir,
            baseName: "ignored",
            shardByFirstCharacter: true,
            char2UInt8: cmap
        )

        // Only test first-character shard "あ" which should exist
        // Filenames are escaped; load via escaped identifier (UTF-16 hex chunks)
        let escapedA = DictionaryBuilder.escapedIdentifier("あ")
        XCTAssertEqual(escapedA, "[3042]")
        guard let loudsA = LOUDS.load(escapedA, dictionaryURL: parent) else {
            XCTFail("Failed to load sharded LOUDS for あ")
            return
        }
        // Search あい and verify candidates
        let ids = toIDs("あい", cmap)
        guard let nodeIndex = loudsA.searchNodeIndex(chars: ids) else {
            XCTFail("searchNodeIndex failed for あい")
            return
        }
        let (shard, local) = shardComponents(nodeIndex)
        let dic = LOUDS.getDataForLoudstxt3("\(escapedA)\(shard)", indices: [local], dictionaryURL: parent)
        let words = dic.filter { $0.ruby == "あい" }.map { $0.word }
        XCTAssertTrue(Set(words).isSuperset(of: ["愛", "藍"]))
    }

    func testLoudstxt3BuilderBinaryParseConsistency() throws {
        // Directly exercise Loudstxt3Builder.makeBinary + LOUDS.parseBinary
        let groups: [(ruby: String, rows: [Loudstxt3Builder.Row])] = [
            (ruby: "か", rows: [
                .init(word: "蚊", lcid: 1, rcid: 1, mid: 1, score: -1),
                .init(word: "課", lcid: 2, rcid: 2, mid: 2, score: -2)
            ]),
            (ruby: "き", rows: [
                .init(word: "木", lcid: 3, rcid: 3, mid: 3, score: -3)
            ])
        ]
        let data = Loudstxt3Builder.makeBinary(entries: groups)
        XCTAssertEqual(headerCount(data), groups.count)
        for i in groups.indices {
            let slice = entrySlice(data, i)
            let parsed = LOUDS.parseBinary(binary: slice)
            // parseBinary yields exactly rows.count elements, each with ruby set from the first field
            XCTAssertEqual(parsed.count, groups[i].rows.count)
            XCTAssertTrue(parsed.allSatisfy { $0.ruby == groups[i].ruby })
            XCTAssertEqual(Set(parsed.map { $0.word }), Set(groups[i].rows.map { $0.word }))
        }
    }

    func testWordOmissionExactMatchOnly() throws {
        // When word == ruby (exact), writer should omit the word (empty field).
        // When word == ruby.toKatakana(), current behavior should NOT omit.
        let groups: [(ruby: String, rows: [Loudstxt3Builder.Row])] = [
            (ruby: "あい", rows: [
                .init(word: "あい", lcid: 1, rcid: 1, mid: 1, score: -1), // exact match -> omitted
                .init(word: "アイ", lcid: 2, rcid: 2, mid: 2, score: -2)  // katakana, not omitted
            ]),
            (ruby: "か", rows: [
                .init(word: "カ", lcid: 3, rcid: 3, mid: 3, score: -3)    // katakana, not omitted
            ])
        ]
        let data = Loudstxt3Builder.makeBinary(entries: groups)

        // Entry 0: ruby "あい", rows: ["あい", "アイ"]
        do {
            let slice = entrySlice(data, 0)
            // numeric area = 2 + 10*rowCount bytes (relative to slice)
            let bodyOffset = 2 + rowBytes * groups[0].rows.count
            XCTAssertGreaterThanOrEqual(slice.count, bodyOffset)
            let start = slice.index(slice.startIndex, offsetBy: bodyOffset)
            let text = String(decoding: slice[start ..< slice.endIndex], as: UTF8.self)
            XCTAssertEqual(text, "あい\t\tアイ")
            // Parse consistency
            let parsed = LOUDS.parseBinary(binary: slice)
            XCTAssertEqual(Set(parsed.map { $0.word }), ["あい", "アイ"])
            XCTAssertTrue(parsed.allSatisfy { $0.ruby == "あい" })
        }

        // Entry 1: ruby "か", rows: ["カ"]
        do {
            let slice = entrySlice(data, 1)
            let bodyOffset = 2 + rowBytes * groups[1].rows.count
            XCTAssertGreaterThanOrEqual(slice.count, bodyOffset)
            let start = slice.index(slice.startIndex, offsetBy: bodyOffset)
            let text = String(decoding: slice[start ..< slice.endIndex], as: UTF8.self)
            XCTAssertEqual(text, "か\tカ")
            // Parse consistency
            let parsed = LOUDS.parseBinary(binary: slice)
            XCTAssertEqual(parsed.count, 1)
            XCTAssertEqual(parsed.first?.ruby, "か")
            XCTAssertEqual(parsed.first?.word, "カ")
        }
    }

    func testEscapedIdentifierFilenames() throws {
        // Verify that shards for special first characters are escaped in filenames
        // and that loading via DicdataStore with the raw character succeeds.
        let parent = try tmpDir("escaped-id")
        defer {
            try? FileManager.default.removeItem(at: parent)
        }
        let loudsDir = parent.appendingPathComponent("louds", isDirectory: true)
        try FileManager.default.createDirectory(at: loudsDir, withIntermediateDirectories: true)

        let entries: [DicdataElement] = [
            DicdataElement(word: "スペース", ruby: " ", lcid: 10, rcid: 10, mid: 1, value: -10),
            DicdataElement(word: "スラッシュ", ruby: "/", lcid: 11, rcid: 11, mid: 2, value: -11)
        ]
        let chars: [Character] = Array(entries.flatMapSet { Array($0.ruby) }).sorted()
        let cmap = charMap(chars)

        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: loudsDir,
            baseName: "ignored",
            shardByFirstCharacter: true,
            char2UInt8: cmap
        )

        // Files exist with escaped identifiers
        let escapedSpace = DictionaryBuilder.escapedIdentifier(" ") // [0020]
        let escapedSlash = DictionaryBuilder.escapedIdentifier("/") // [002F]
        assertExists(loudsDir.appendingPathComponent("\(escapedSpace).louds"))
        assertExists(loudsDir.appendingPathComponent("\(escapedSlash).louds"))
        // At least shard 0 should exist for both
        assertExists(loudsDir.appendingPathComponent("\(escapedSpace)0.loudstxt3"))
        assertExists(loudsDir.appendingPathComponent("\(escapedSlash)0.loudstxt3"))

        // Loading via DicdataStore with raw identifiers should resolve using escape mapping
        let store = DicdataStore(dictionaryURL: parent)
        let state = store.prepareState()
        guard let loudsSpace = store.loadLOUDS(query: " ", state: state) else {
            return XCTFail("Failed to load LOUDS for space via DicdataStore")
        }
        guard let loudsSlash = store.loadLOUDS(query: "/", state: state) else {
            return XCTFail("Failed to load LOUDS for slash via DicdataStore")
        }

        // Search both entries
        if let idx = loudsSpace.searchNodeIndex(chars: toIDs(" ", cmap)) {
            let (shard, local) = shardComponents(idx)
            let dic = LOUDS.getDataForLoudstxt3("\(escapedSpace)\(shard)", indices: [local], dictionaryURL: parent)
            XCTAssertTrue(dic.contains { $0.word == "スペース" && $0.ruby == " " })
        } else {
            XCTFail("space ruby not found in LOUDS")
        }
        if let idx = loudsSlash.searchNodeIndex(chars: toIDs("/", cmap)) {
            let (shard, local) = shardComponents(idx)
            let dic = LOUDS.getDataForLoudstxt3("\(escapedSlash)\(shard)", indices: [local], dictionaryURL: parent)
            XCTAssertTrue(dic.contains { $0.word == "スラッシュ" && $0.ruby == "/" })
        } else {
            XCTFail("slash ruby not found in LOUDS")
        }
    }

    func testAligned2048EmptySlotsAreParsable() throws {
        // Build a shard with sparse items and ensure empty slots are valid (2-byte zero header)
        let dir = try tmpDir("aligned-2048")
        defer {
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("shard.loudstxt3")

        let items: [(local: Int, ruby: String, rows: [Loudstxt3Builder.Row])] = [
            (local: 5, ruby: "あ", rows: [ .init(word: "亜", lcid: 1, rcid: 1, mid: 1, score: -1) ]),
            (local: 300, ruby: "か", rows: [ .init(word: "蚊", lcid: 2, rcid: 2, mid: 2, score: -2), .init(word: "課", lcid: 3, rcid: 3, mid: 3, score: -3) ])
        ]
        try Loudstxt3Builder.writeAligned2048(items: items, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(headerCount(data), DictionaryBuilder.entriesPerShard)

        // Empty slot should produce a slice with at least 2 bytes and parse to empty
        for emptyIdx in [0, 1, 2, 10] where !items.contains(where: { $0.local == emptyIdx }) {
            let slice = entrySlice(data, emptyIdx)
            XCTAssertGreaterThanOrEqual(slice.count, 2)
            let parsed = LOUDS.parseBinary(binary: slice)
            XCTAssertEqual(parsed.count, 0)
        }

        // Non-empty slots should round-trip
        do {
            let slice = entrySlice(data, 5)
            let parsed = LOUDS.parseBinary(binary: slice)
            XCTAssertEqual(parsed.count, 1)
            XCTAssertEqual(parsed.first?.ruby, "あ")
            XCTAssertEqual(parsed.first?.word, "亜")
        }
        do {
            let slice = entrySlice(data, 300)
            let parsed = LOUDS.parseBinary(binary: slice)
            XCTAssertEqual(Set(parsed.map { $0.word }), ["蚊", "課"])
            XCTAssertTrue(parsed.allSatisfy { $0.ruby == "か" })
        }
    }

    func testExportWithCustomShardShiftWritesAlignedFiles() throws {
        // Use shardShift=10 (entriesPerShard=1024) just for writing, and verify file shape and content.
        let dir = try tmpDir("custom-shardshift")
        defer { try? FileManager.default.removeItem(at: dir) }

        let entries: [DicdataElement] = [
            DicdataElement(word: "亜", ruby: "あ", lcid: 10, rcid: 10, mid: 1, value: -10),
            DicdataElement(word: "蚊", ruby: "か", lcid: 13, rcid: 13, mid: 6, value: -12)
        ]
        let chars: [Character] = Array(entries.flatMapSet { Array($0.ruby) }).sorted()
        let cmap = charMap(chars)

        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: dir,
            baseName: "user",
            shardByFirstCharacter: false,
            char2UInt8: cmap,
            shardShift: 10
        )

        // Load LOUDS to compute node indices (independent of shardShift).
        guard let louds = LOUDS.loadUserDictionary(userDictionaryURL: dir) else {
            return XCTFail("Failed to load exported user LOUDS")
        }
        func check(_ ruby: String, expected: String) throws {
            let ids = toIDs(ruby, cmap)
            guard let idx = louds.searchNodeIndex(chars: ids) else { return XCTFail("index missing for \(ruby)") }
            let shard = idx / 1024
            let local = idx % 1024
            // Verify header count of the written file is 1024
            let url = dir.appendingPathComponent("user\(shard).loudstxt3")
            let data = try Data(contentsOf: url)
            XCTAssertEqual(headerCount(data), 1024)
            // Parse by helper (matches writer’s alignment)
            let slice = entrySlice(data, local)
            let parsed = LOUDS.parseBinary(binary: slice)
            XCTAssertTrue(parsed.contains { $0.ruby == ruby && $0.word == expected })
        }
        try check("あ", expected: "亜")
        try check("か", expected: "蚊")
    }

    // MARK: - escapedIdentifier tests (migrated from EscapedIdentifierTests)
    func testEscapedIdentifierAsciiLetters() {
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("a"), "[0061]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("A"), "[0041]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("z"), "[007A]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("Z"), "[005A]")
    }

    func testEscapedIdentifierAsciiSymbolsAndSpace() {
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier(" "), "[0020]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("/"), "[002F]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("\\"), "[005C]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("\n"), "[000A]")
    }

    func testEscapedIdentifierHiraganaKatakanaKanji() {
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("あ"), "[3042]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("ア"), "[30A2]")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("漢"), "[6F22]")
    }

    func testEscapedIdentifierMultiScalarEmojiFlag() {
        // 🇯🇵 = U+1F1EF U+1F1F5 -> UTF-16: D83C DDEF D83C DDF5
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("🇯🇵"), "[D83C_DDEF_D83C_DDF5]")
    }

    func testEscapedIdentifierReservedIdentifiersRemainUnchanged() {
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("user"), "user")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("memory"), "memory")
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier("user_shortcuts"), "user_shortcuts")
    }

    func testEscapedIdentifierEmptyString() {
        XCTAssertEqual(DictionaryBuilder.escapedIdentifier(""), "[]")
    }
}
