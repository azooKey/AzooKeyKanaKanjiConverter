#if Zenzai || ZenzaiCPU
import llama
#endif

import EfficientNGram
import Foundation

/// typo correction から見た入力言語モデルの共通インターフェース。
/// 文字列の token 化、語彙の参照、次 token の対数確率分布の取得だけを抽象化する。
protocol ZenzCompatibleInputLanguageModelContext {
    var vocabSize: Int { get }
    func encodeRaw(_ text: String) -> [Int]
    func tokenToSingleCharacter(tokenID: Int) -> Character?
    func nextLogProbs(promptTokenIDs: [Int], emittedTokenIDs: [Int]) -> [Float]?
}

struct NGramContext: ZenzCompatibleInputLanguageModelContext {
    private let model: EfficientNGram
    private let tokenizer: ZenzTokenizer

    init(model: EfficientNGram, tokenizer: ZenzTokenizer = .init()) {
        self.model = model
        self.tokenizer = tokenizer
    }

    var vocabSize: Int {
        self.tokenizer.vocabSize
    }

    func encodeRaw(_ text: String) -> [Int] {
        self.tokenizer.encode(text: text)
    }

    func tokenToSingleCharacter(tokenID: Int) -> Character? {
        let text = self.tokenizer.decode(tokens: [tokenID])
        guard text.count == 1 else {
            return nil
        }
        return text.first
    }

    func nextLogProbs(promptTokenIDs: [Int], emittedTokenIDs: [Int]) -> [Float]? {
        let probs = self.model.bulkPredict(promptTokenIDs + emittedTokenIDs)
        guard probs.count == self.vocabSize else {
            return nil
        }
        return Self.normalizeLogProbs(probs.map { logf(max(Float($0), 1e-20)) })
    }

    private static func normalizeLogProbs(_ values: [Float]) -> [Float] {
        guard let maxLogProb = values.max() else {
            return values
        }
        var normalized = values
        var sumExp: Float = 0
        for value in normalized {
            sumExp += expf(value - maxLogProb)
        }
        let logSumExp = maxLogProb + logf(sumExp)
        for index in normalized.indices {
            normalized[index] -= logSumExp
        }
        return normalized
    }
}

extension ZenzContext: ZenzCompatibleInputLanguageModelContext {
    func encodeRaw(_ text: String) -> [Int] {
        self.encodeRaw(text, addBOS: false, addEOS: false).map(Int.init)
    }

    func tokenToSingleCharacter(tokenID: Int) -> Character? {
        let piece = self.tokenToPiece(token: llama_token(tokenID))
        let data = Data(piece.map { UInt8(bitPattern: $0) })
        guard let text = String(data: data, encoding: .utf8), text.count == 1 else {
            return nil
        }
        return text.first
    }

    func nextLogProbs(promptTokenIDs: [Int], emittedTokenIDs: [Int]) -> [Float]? {
        let fullTokenIDs = (promptTokenIDs + emittedTokenIDs).map { llama_token($0) }
        guard !fullTokenIDs.isEmpty else {
            return nil
        }
        let startOffset = fullTokenIDs.count - 1
        guard let logits = self.inputPredictionLogits(tokens: fullTokenIDs, startOffset: startOffset) else {
            return nil
        }
        var logitValues: [Float] = Array(repeating: 0, count: self.vocabSize)
        var maxLogit: Float = -.infinity
        for index in logitValues.indices {
            let value = logits[index]
            logitValues[index] = value
            if value > maxLogit {
                maxLogit = value
            }
        }
        var sumExp: Float = 0
        for value in logitValues {
            sumExp += expf(value - maxLogit)
        }
        let logSumExp = maxLogit + logf(sumExp)
        for index in logitValues.indices {
            logitValues[index] -= logSumExp
        }
        return logitValues
    }
}
