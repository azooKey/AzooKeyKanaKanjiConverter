@testable import KanaKanjiConverterModule
import XCTest

final class InputTableFormatTests: XCTestCase {
    func testFullyValid() throws {
        let content = [
            "a\tあ",
            "k{shift 0}\tか",
            "n{any character}\tん{any character}",
            "{lbracket}{rbracket}\t[]"
        ].joined(separator: "\n")
        let rep = InputStyleManager.checkFormat(content: content)
        if case .invalidLines(let errs) = rep {
            XCTFail("Unexpected errors: \(errs)")
        }
    }

    func testInvalidTabCount() throws {
        let content = "a\t\tあ" // tabが2個
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertTrue(errs.contains(.init(line: 0, error: .invalidTabCount(found: 2))))
    }

    func testUnknownBraceTokenKey() throws {
        let content = "{unknown}\tあ"
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertTrue(errs.contains(.init(line: 0, error: .unknownBraceToken(token: "unknown", side: .key))))
    }

    func testUnknownBraceTokenValue() throws {
        let content = "a\t{unknown}"
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertTrue(errs.contains(.init(line: 0, error: .unknownBraceToken(token: "unknown", side: .value))))
    }

    func testUnclosedBrace() throws {
        let content = "{shift 0\tか" // 未閉鎖
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertTrue(errs.contains(.init(line: 0, error: .unclosedBrace)))
    }

    func testShiftNotAtTail() throws {
        let content = "a{shift 0}b\tX"
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertTrue(errs.contains(.init(line: 0, error: .shiftTokenNotAtTail(token: "shift 0"))))
    }

    func testLineNumberWithFormerComment() throws {
        let content = "#comment\na{shift 0}b\tX"
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertTrue(errs.contains(.init(line: 0, error: .invalidTabCount(found: 0))))
        XCTAssertTrue(errs.contains(.init(line: 1, error: .shiftTokenNotAtTail(token: "shift 0"))))
    }

    func testDuplicateDifferentValue() throws {
        let content = [
            "ka\tか",
            "ka\tカ"
        ].joined(separator: "\n")
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertEqual(errs.count, 1)
        XCTAssertEqual(.init(line: 1, error: .duplicateRule(firstDefinedAt: 0)), errs[0])
    }

    func testDuplicateSameValue() throws {
        let content = [
            "ka\tか",
            "ka\tか"
        ].joined(separator: "\n")
        let rep = InputStyleManager.checkFormat(content: content)
        guard case .invalidLines(let errs) = rep else {
            XCTFail("Expected invalidLines")
            return
        }
        XCTAssertEqual(errs.count, 1)
        XCTAssertEqual(.init(line: 1, error: .duplicateRule(firstDefinedAt: 0)), errs[0])
    }
}
