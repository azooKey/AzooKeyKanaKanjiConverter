import Tokenizers
import Hub
import Foundation

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
    func encode(text: String) -> [Int] {
        return self.tokenizer.encode(text: text)
    }
    func decode(tokens: [Int]) -> String {
        return self.tokenizer.decode(tokens: tokens)
    }
    var startTokenID: Int {
        self.tokenizer.bosTokenId!
    }
    var endTokenID: Int {
        self.tokenizer.eosTokenId!
    }
    var vocabSize: Int {
        // FIXME
        6000
    }
}
