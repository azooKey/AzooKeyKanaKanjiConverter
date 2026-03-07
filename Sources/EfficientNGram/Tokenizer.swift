import Foundation
#if canImport(Hub) && canImport(Tokenizers) && NGram
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
    func encode(text: String) -> [Int] {
        self.tokenizer.encode(text: text)
    }
    func decode(tokens: [Int]) -> String {
        self.tokenizer.decode(tokens: tokens)
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
#else
public struct ZenzTokenizer {
    public init() {}
    func encode(text _: String) -> [Int] { [] }
    func decode(tokens _: [Int]) -> String { "" }
    var startTokenID: Int { 0 }
    var endTokenID: Int { 0 }
    var vocabSize: Int { 6000 }
}
#endif
