import Foundation
import Hub
import Tokenizers

/// Fast-path cache state for `ZenzTokenizer`.
/// This state is intentionally non-thread-safe and is expected to be used
/// from a single thread (thread-local tokenizer instance).
private final class FastTokenizerPathState {
    private var scalarTokenCache: [UInt32: [Int]]
    private var isEnabled: Bool

    init(isEnabled: Bool) {
        self.scalarTokenCache = [:]
        self.isEnabled = isEnabled
    }

    func getCachedTokenIDs(for scalarValue: UInt32) -> [Int]? {
        return scalarTokenCache[scalarValue]
    }

    func setCachedTokenIDsIfAbsent(_ tokenIDs: [Int], for scalarValue: UInt32) {
        if scalarTokenCache[scalarValue] == nil {
            scalarTokenCache[scalarValue] = tokenIDs
        }
    }

    func shouldUseFastPath() -> Bool {
        return isEnabled
    }
}

public struct ZenzTokenizer {
    private let tokenizer: any Tokenizer
    private let fastPathState: FastTokenizerPathState

    public init() {
        self.init(enableFastTokenizerPath: true)
    }

    public init(enableFastTokenizerPath: Bool) {
        let modelFolder = Bundle.module.resourceURL!.appendingPathComponent("tokenizer", isDirectory: true)
        let hubApi = HubApi.shared
        let tokenizerConfig = try! hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer_config.json"))
        let tokenizerData = try! hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer.json"))
        let tokenizer = try! AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
        self.tokenizer = tokenizer
        self.fastPathState = .init(isEnabled: enableFastTokenizerPath)
    }

    func encode(text: String) -> [Int] {
        guard self.fastPathState.shouldUseFastPath() else {
            return self.encodeSlow(text: text)
        }
        return self.encodeFastByUnicodeScalar(text: text)
    }

    func encodeSlow(text: String) -> [Int] {
        self.tokenizer.encode(text: text)
    }

    private func encodeFastByUnicodeScalar(text: String) -> [Int] {
        var output: [Int] = []
        output.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let scalarValue = scalar.value
            if let cached = self.fastPathState.getCachedTokenIDs(for: scalarValue) {
                output.append(contentsOf: cached)
                continue
            }
            let scalarText = String(scalar)
            let encoded = self.encodeSlow(text: scalarText)
            self.fastPathState.setCachedTokenIDsIfAbsent(encoded, for: scalarValue)
            output.append(contentsOf: encoded)
        }
        return output
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
