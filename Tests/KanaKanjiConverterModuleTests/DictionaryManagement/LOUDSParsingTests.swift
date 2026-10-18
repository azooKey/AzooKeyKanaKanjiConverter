import Foundation
@testable import KanaKanjiConverterModule
import XCTest

final class LOUDSParsingTests: XCTestCase {
    private func payload(count: UInt16 = 2, text: String = "ヨミ\t表記\t") -> Data {
        var data = Data([UInt8(count & 0xff), UInt8(count >> 8)])
        for _ in 0 ..< count {
            data.append(contentsOf: [1, 0, 2, 0, 3, 0, 0, 0, 128, 191])
        }
        data.append(contentsOf: text.utf8)
        return data
    }

    private func shard(_ payloads: [Data]) -> Data {
        let count = payloads.count
        var data = Data([UInt8(count & 0xff), UInt8(count >> 8)])
        var offset = UInt32(2 + count * 4)
        for payload in payloads {
            var littleEndian = offset.littleEndian
            data.append(Data(bytes: &littleEndian, count: 4))
            offset += UInt32(payload.count)
        }
        for payload in payloads { data.append(payload) }
        return data
    }

    func testValidFieldsAndTrailingOmittedWordInDataSlice() {
        var data = Data([255, 255, 255])
        data.append(payload())
        let parsed = LOUDS.parseBinary(binary: data.dropFirst(3))
        XCTAssertEqual(parsed.map { $0.word }, ["表記", "ヨミ"])
        XCTAssertEqual(parsed.map { $0.ruby }, ["ヨミ", "ヨミ"])
        XCTAssertEqual(parsed.map { $0.lcid }, [1, 1])
        XCTAssertEqual(parsed.map { $0.rcid }, [2, 2])
        XCTAssertEqual(parsed.map { $0.mid }, [3, 3])
        XCTAssertEqual(parsed.map { $0.baseValue }, [-1, -1])
    }

    func testTruncatedNumericRowsAreRejected() {
        let data = payload()
        for length in 0 ..< 22 {
            XCTAssertTrue(LOUDS.parseBinary(binary: Data(data.prefix(length))).isEmpty, "length: \(length)")
        }
        XCTAssertTrue(LOUDS.parseBinary(binary: Data([255, 255])).isEmpty)
        XCTAssertTrue(LOUDS.parseBinary(binary: Data([0, 0])).isEmpty)
    }

    func testFieldCountMismatchRejectsWholeRubyGroup() {
        for text in ["", "ヨミ", "ヨミ\t表記", "ヨミ\tA\tB\tC", "ヨ\tミ\tA\tB", "ヨミ\tA\t\t", "\tA\tB"] {
            XCTAssertTrue(LOUDS.parseBinary(binary: payload(text: text)).isEmpty, "text: \(text.debugDescription)")
        }
    }

    func testInvalidUTF8RejectsWholeRubyGroup() {
        var data = payload(count: 1, text: "ヨミ\t")
        data.append(255)
        XCTAssertTrue(LOUDS.parseBinary(binary: data).isEmpty)
    }

    func testMalformedEntryDoesNotDiscardOtherEntries() {
        for invalid in [Data([1, 0]), payload(text: "ヨミ\tA\tB\tC")] {
            var data = Data([255, 255, 255])
            data.append(shard([invalid, payload()]))
            let parsed = LOUDS.parseLoudstxt3Binary(binary: data.dropFirst(3), indices: [-1, 0, 1, 2, Int.max])
            XCTAssertEqual(parsed.map { $0.word }, ["表記", "ヨミ"])
        }
    }

    func testInvalidHeadersAndOffsetsAreRejected() {
        let invalidFiles: [[UInt8]] = [
            [], [1], [1, 0], [1, 0, 6, 0, 0],
            [1, 0, 0, 0, 0, 0],
            [1, 0, 255, 255, 255, 255],
            [1, 0, 6, 0, 0, 0],
            [2, 0, 12, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0]
        ]
        for bytes in invalidFiles {
            XCTAssertTrue(LOUDS.parseLoudstxt3Binary(binary: Data(bytes), indices: [-1, 0, 1, Int.max]).isEmpty)
        }
    }
}
