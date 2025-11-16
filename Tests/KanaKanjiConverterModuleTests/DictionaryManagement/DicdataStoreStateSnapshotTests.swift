@testable import KanaKanjiConverterModule
import XCTest

final class DicdataStoreStateSnapshotTests: XCTestCase {
    func testSnapshotRoundTripPreservesDynamicDictionaries() {
        let state = DicdataStoreState(dictionaryURL: URL(fileURLWithPath: "/tmp"))
        state.updateKeyboardLanguage(.ja_JP)
        let customEntry = DicdataElement(word: "雨", ruby: "あめ", lcid: CIDData.一般名詞.cid, rcid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -5)
        state.importDynamicUserDictionary([customEntry], shortcuts: [])
        let snapshot = state.snapshot()
        let restored = DicdataStoreState(snapshot: snapshot)
        XCTAssertEqual(restored.keyboardLanguage, .ja_JP)
        XCTAssertEqual(restored.dynamicUserDictionary.first?.word, customEntry.word)
        XCTAssertEqual(restored.dynamicUserDictionary.first?.metadata, [.isFromUserDictionary])
    }
}
