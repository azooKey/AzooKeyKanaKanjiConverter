import Foundation
import Hub
import Tokenizers

public struct ZenzTokenizer {
    private let tokenizer: any Tokenizer
    public init() {
        let modelFolder = Bundle.module.resourceURL!.appendingPathComponent("tokenizer", isDirectory: true)
        let hubApi = HubApi.shared
        let tokenizerConfig = try! hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer_config.json"))
        let tokenizerData = try! hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer.json"))
        let tokenizer = try! AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
        self.tokenizer = tokenizer
    }
    public func encode(text: String) -> [Int] {
        self.tokenizer.encode(text: text)
    }
    public func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        self.tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    public func decode(tokens: [Int]) -> String {
        self.tokenizer.decode(tokens: tokens)
    }
    public var startTokenID: Int {
        self.tokenizer.bosTokenId!
    }
    public var endTokenID: Int {
        self.tokenizer.eosTokenId!
    }
    public var vocabSize: Int {
        // FIXME
        6000
    }
}
