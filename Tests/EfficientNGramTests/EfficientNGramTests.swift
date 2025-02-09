import XCTest
@testable import EfficientNGram
import Tokenizers

class SwiftNGramTests: XCTestCase {
#if canImport(SwiftyMarisa)
    func testTokenizers() throws {
        let tokenizer = ZenzTokenizer()
        let inputIds = tokenizer.encode(text: "これは日本語です")
        XCTAssertEqual(inputIds, [268, 262, 253, 304, 358, 698, 246, 255])
        XCTAssertEqual(tokenizer.decode(tokens: inputIds), "これは日本語です")
    }
#endif
}
