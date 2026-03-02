@testable import KanaKanjiConverterModule
import XCTest

final class LearningMemoryTests: XCTestCase {
    static let resourceURL = Bundle.module.resourceURL!.appendingPathComponent("DictionaryMock", isDirectory: true)

    private func getConfigForMemoryTest(memoryURL: URL) -> LearningConfig {
        .init(learningType: .inputAndOutput, maxMemoryCount: 32, memoryURL: memoryURL)
    }

    func testPauseFileIsClearedOnInit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let manager = LearningManager(dictionaryURL: Self.resourceURL)
        _ = manager.updateConfig(config)

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        manager.update(data: [element])
        manager.save()

        // ポーズファイルを設置
        let pauseURL = dir.appendingPathComponent(".pause", isDirectory: false)
        FileManager.default.createFile(atPath: pauseURL.path, contents: Data())
        XCTAssertTrue(LongTermLearningMemory.memoryCollapsed(directoryURL: dir))

        // ここで副作用が発生
        _ = manager.updateConfig(config)

        // 学習の破壊状態が回復されていることを確認
        XCTAssertFalse(LongTermLearningMemory.memoryCollapsed(directoryURL: dir))
        try? FileManager.default.removeItem(at: pauseURL)
    }

    func testMemoryFilesCreateAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let manager = LearningManager(dictionaryURL: Self.resourceURL)
        _ = manager.updateConfig(config)

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        manager.update(data: [element])
        manager.save()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "memory.louds" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "memory.loudschars2" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "memory.memorymetadata" })
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".loudstxt3") })

        manager.resetMemory()
        let filesAfter = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(filesAfter.isEmpty)
    }

    func testForgetMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningManagerPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)
        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        state.learningMemoryManager.save()

        let charIDs = "テスト".map { dicdataStore.character2charId($0) }
        let indices = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices, state: state)
        XCTAssertFalse(dicdata.isEmpty)
        XCTAssertTrue(dicdata.contains { $0.word == element.word && $0.ruby == element.ruby })

        state.forgetMemory(
            Candidate(
                text: element.word,
                value: element.value(),
                composingCount: .inputCount(3),
                lastMid: element.mid,
                data: [element]
            )
        )
        let indices2 = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata2 = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices2, state: state)
        XCTAssertFalse(dicdata2.contains { $0.word == element.word && $0.ruby == element.ruby })
    }

    func testCoarseForgetMemory() throws {
        // ForgetMemoryは「粗い」チェックを行うため、品詞が異なっていても同時に忘却される
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningManagerPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)
        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        let differentCidElement = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [differentCidElement])
        state.learningMemoryManager.save()

        let charIDs = "テスト".map { dicdataStore.character2charId($0) }
        let indices = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices, state: state)
        XCTAssertFalse(dicdata.isEmpty)
        XCTAssertEqual(dicdata.count { $0.word == element.word && $0.ruby == element.ruby }, 2)

        state.forgetMemory(
            Candidate(
                text: element.word,
                value: element.value(),
                composingCount: .inputCount(3),
                lastMid: element.mid,
                data: [element]
            )
        )

        let indices2 = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata2 = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices2, state: state)
        XCTAssertFalse(dicdata2.contains { $0.word == element.word && $0.ruby == element.ruby })
    }

    func testMergeWithTruncatedMetadata() throws {
        // metadataファイルが途中で途切れたケース
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTruncatedMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        state.learningMemoryManager.save()

        let metadataURL = dir.appendingPathComponent("memory.memorymetadata", isDirectory: false)
        var metadata = try Data(contentsOf: metadataURL)
        XCTAssertGreaterThanOrEqual(metadata.count, 4)
        // 末尾を削除して不完全な状態にする
        metadata.removeLast()
        let truncatedMetadata = metadata
        try metadata.write(to: metadataURL)

        // クラッシュが発生しないことを確認
        try LongTermLearningMemory.merge(
            tempTrie: TemporalLearningMemoryTrie(),
            directoryURL: dir,
            maxMemoryCount: state.learningMemoryManager.config.maxMemoryCount,
            char2UInt8: state.learningMemoryManager.char2UInt8
        )
        // 新しいmetadataファイルが生成されている
        let newMetadata = try Data(contentsOf: metadataURL)
        XCTAssertGreaterThanOrEqual(newMetadata.count, 4)
        XCTAssertNotEqual(newMetadata, truncatedMetadata)
    }

    func testMergeMissingMetadataHeader() throws {
        // metadataファイルのヘッダが存在しないケース
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryShortMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)
        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        state.learningMemoryManager.save()

        let metadataURL = dir.appendingPathComponent("memory.memorymetadata", isDirectory: false)
        try Data([0x00, 0x01]).write(to: metadataURL)

        // クラッシュが発生しないことを確認
        try LongTermLearningMemory.merge(
            tempTrie: TemporalLearningMemoryTrie(),
            directoryURL: dir,
            maxMemoryCount: state.learningMemoryManager.config.maxMemoryCount,
            char2UInt8: state.learningMemoryManager.char2UInt8
        )

        // 新しいmetadataファイルが生成されている
        let newMetadata = try Data(contentsOf: metadataURL)
        XCTAssertGreaterThanOrEqual(newMetadata.count, 4)
    }

    func testMergeMissingLoudstxtHeader() throws {
        // loudstxt3ファイルのヘッダが存在しないケース
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryShortLOUDS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)
        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        state.learningMemoryManager.save()

        let loudstxtURL = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".loudstxt3") }!
        try Data([0xFF]).write(to: loudstxtURL)

        // クラッシュが発生しないことを確認
        try LongTermLearningMemory.merge(
            tempTrie: TemporalLearningMemoryTrie(),
            directoryURL: dir,
            maxMemoryCount: state.learningMemoryManager.config.maxMemoryCount,
            char2UInt8: state.learningMemoryManager.char2UInt8
        )

        // 新しいloudstxt3ファイルが生成されている
        let newLoudstxtData = try Data(contentsOf: loudstxtURL)
        XCTAssertNotEqual(newLoudstxtData, Data([0xFF]))
    }

    func testLearningManagerCharIDOverflow() throws {
        let dictionaryDir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryCharID-\(UUID().uuidString)", isDirectory: true)
        let loudsDir = dictionaryDir.appendingPathComponent("louds", isDirectory: true)
        try FileManager.default.createDirectory(at: loudsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dictionaryDir) }

        let overCapacityScalars = (0 ..< 300).compactMap { UnicodeScalar(0x4E00 + $0) }
        let overCapacityString = String(overCapacityScalars.map(Character.init))
        let chidURL = loudsDir.appendingPathComponent("charID.chid", isDirectory: false)
        try overCapacityString.write(to: chidURL, atomically: true, encoding: .utf8)

        let manager = LearningManager(dictionaryURL: dictionaryDir)
        // 256文字を超えるcharIDが存在する場合、上限の256文字までしか読み込まれない
        XCTAssertEqual(manager.char2UInt8.count, 256)
    }
}
