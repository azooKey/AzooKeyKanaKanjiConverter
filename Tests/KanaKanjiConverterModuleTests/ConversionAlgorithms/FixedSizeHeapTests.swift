@testable import KanaKanjiConverterModule
import XCTest

final class FixedSizeHeapTests: XCTestCase {
    func testInsertIfPossibleKeepsTopKElements() {
        var heap = FixedSizeHeap<Int>(size: 3)
        XCTAssertTrue(heap.insertIfPossible(1))
        XCTAssertTrue(heap.insertIfPossible(3))
        XCTAssertTrue(heap.insertIfPossible(2))
        XCTAssertFalse(heap.insertIfPossible(0))
        XCTAssertTrue(heap.insertIfPossible(4))

        XCTAssertEqual(heap.min, 2)
        XCTAssertEqual(heap.max, 4)
        XCTAssertEqual(Set(heap.unordered), Set([2, 3, 4]))
    }

    func testInsertIfPossibleReturnValueWhenFull() {
        var heap = FixedSizeHeap<Int>(size: 2)
        XCTAssertTrue(heap.insertIfPossible(10))
        XCTAssertTrue(heap.insertIfPossible(20))
        XCTAssertFalse(heap.insertIfPossible(5))
        XCTAssertTrue(heap.insertIfPossible(30))

        XCTAssertEqual(Set(heap.unordered), Set([20, 30]))
    }
}
