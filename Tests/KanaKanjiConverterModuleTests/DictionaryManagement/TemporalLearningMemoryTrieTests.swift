@testable import KanaKanjiConverterModule
import XCTest

final class TemporalLearningMemoryTrieTests: XCTestCase {
    static let resourceURL = Bundle.module.resourceURL!.appendingPathComponent("DictionaryMock", isDirectory: true)

    static func loadCharMap() -> [Character: UInt8] {
        let chidURL = resourceURL.appendingPathComponent("louds/charID.chid", isDirectory: false)
        let string = try! String(contentsOf: chidURL, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: string.enumerated().map { ($0.element, UInt8($0.offset)) })
    }

    func chars(for string: String) -> [UInt8] {
        LearningManager.keyToChars(string, char2UInt8: Self.loadCharMap())!
    }

    func testMemorizeRejectsUnrepresentableText() {
        var trie = TemporalLearningMemoryTrie()
        for (ruby, word) in [("テスト", "テ\tスト"), ("テ\tスト", "テスト"), ("", "テスト")] {
            let element = DicdataElement(word: word, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
            // Supply IDs even for tab so rejection does not depend on the character map.
            trie.memorize(dicdataElement: element, chars: [1, 2, 3])
            XCTAssertTrue(trie.isEmpty)
            XCTAssertTrue(trie.perfectMatch(chars: [1, 2, 3]).isEmpty)
        }
    }

    func testMemorizeAndMatch() throws {
        var trie = TemporalLearningMemoryTrie()
        let element1 = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        let element2 = DicdataElement(word: "テスター", ruby: "テスター", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -12)

        trie.memorize(dicdataElement: element1, chars: chars(for: element1.ruby))
        trie.memorize(dicdataElement: element2, chars: chars(for: element2.ruby))

        let result1 = trie.perfectMatch(chars: chars(for: element1.ruby))
        XCTAssertEqual(result1.count, 1)
        XCTAssertEqual(result1.first?.word, element1.word)
        XCTAssertTrue(result1.first?.metadata.contains(.isLearned) ?? false)

        let result2 = trie.movingTowardPrefixSearch(chars: chars(for: element2.ruby), depth: (element2.ruby.count - 1)..<element2.ruby.count).dicdata.flatMap { $0.value }
        XCTAssertEqual(result2.map { $0.word }, [element2.word])

        let prefixResult = trie.prefixMatch(chars: chars(for: "テス"))
        XCTAssertEqual(Set(prefixResult.map { $0.word }), Set([element1.word, element2.word]))
    }

    func testMemorizeTwice() throws {
        var trie = TemporalLearningMemoryTrie()
        let element1 = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        trie.memorize(dicdataElement: element1, chars: chars(for: element1.ruby))

        let element2 = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10, adjust: 1.5)
        trie.memorize(dicdataElement: element2, chars: chars(for: element2.ruby))

        let result1 = trie.perfectMatch(chars: chars(for: element1.ruby))
        XCTAssertEqual(result1.count, 1)
        XCTAssertEqual(result1.first?.word, element1.word)
        XCTAssertTrue(result1.first?.metadata.contains(.isLearned) ?? false)
    }

    func testMemorizeUpdateCountAndForget() throws {
        var trie = TemporalLearningMemoryTrie()
        let element = DicdataElement(word: "テスター", ruby: "テスター", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        let charIDs = chars(for: element.ruby)

        trie.memorize(dicdataElement: element, chars: charIDs)
        var stored = trie.perfectMatch(chars: charIDs).first!
        let adjust1 = stored.adjust

        trie.memorize(dicdataElement: element, chars: charIDs)
        stored = trie.perfectMatch(chars: charIDs).first!
        let adjust2 = stored.adjust

        XCTAssertGreaterThan(adjust2, adjust1)
        XCTAssertEqual(trie.perfectMatch(chars: charIDs).count, 1)

        XCTAssertTrue(trie.forget(dicdataElement: stored, chars: charIDs))
        XCTAssertTrue(trie.perfectMatch(chars: charIDs).isEmpty)
    }

    func testCoarseForget() throws {
        var trie = TemporalLearningMemoryTrie()
        let element1 = DicdataElement(word: "テスター", ruby: "テスター", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        let element2 = DicdataElement(word: "テスター", ruby: "テスター", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
        let charIDs = chars(for: "テスター")

        trie.memorize(dicdataElement: element1, chars: charIDs)
        trie.memorize(dicdataElement: element2, chars: charIDs)

        // 単語としては2種類存在
        XCTAssertEqual(trie.perfectMatch(chars: charIDs).count, 2)

        // forgetする場合、両方が同時に削除される（表層形の一致で判断＝粗い一致）
        XCTAssertTrue(trie.forget(dicdataElement: element1, chars: charIDs))
        XCTAssertTrue(trie.perfectMatch(chars: charIDs).isEmpty)
    }
}
