//
//  ZenzCoreMLStateful.swift
//  AzooKeyKanaKanjiConverter
//
//  Created by Buseong Kim on 11/16/25.
//

@preconcurrency import CoreML
import Foundation
import Tokenizers

@available(iOS 18.0, macOS 15.0, *)
private final class MLModelBox: @unchecked Sendable {
    let model: MLModel

    init(model: MLModel) {
        self.model = model
    }
}

@available(iOS 18.0, macOS 15.0, *)
public enum ZenzCoreMLError: Error {
    case modelNotFound
    case tokenizerNotFound
    case tokenizerLoadFailed(String)
    case missingLogits
    case multiArrayCreationFailed
}

@available(iOS 18.0, macOS 15.0, *)
public enum ZenzCoreMLComputeUnits {
    case cpuOnly
    case cpuAndGPU
    case all

    fileprivate var coreMLValue: MLComputeUnits {
        switch self {
        case .cpuOnly:
            return .cpuOnly
        case .cpuAndGPU:
            return .cpuAndGPU
        case .all:
            return .all
        }
    }
}

/// Actor wrapping the zenz-v3.1 stateful 8-bit Core ML model.
/// The actor serializes access to the internal `MLState` so repeated predictions
/// advance the cached KV state safely across await suspension points.
@available(iOS 18.0, macOS 15.0, *)
public struct ZenzCoreMLLogits: Sendable {
    public let values: [Float]
    public let vocabSize: Int
    public let timeSteps: Int
}

@available(iOS 18.0, macOS 15.0, *)
public actor ZenzStateful8BitGenerator {
    private let modelBox: MLModelBox
    private let tokenizer: any Tokenizer
    private var evalState: MLState
    private var cachedTokens: [Int] = []
    private var cachedLogits: [Float] = []
    private var cachedVocabSize: Int = 0

    private static let modelName = "zenz_v3.1_stateful-8bit"
    public init(computeUnits: ZenzCoreMLComputeUnits = .cpuAndGPU) async throws {
        guard let modelURL = ZenzCoreMLResources.statefulModelURL(named: Self.modelName) else {
            throw ZenzCoreMLError.modelNotFound
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreMLValue
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.modelBox = MLModelBox(model: model)
        self.evalState = model.makeState()
        self.tokenizer = try await Self.loadTokenizer()
    }

    /// Resets the internal KV state so the next prediction starts fresh.
    public func resetState() {
        resetCache()
    }

    public func logits(for tokens: [Int]) async throws -> ZenzCoreMLLogits {
        var commonPrefixCount = zip(tokens, cachedTokens).prefix { $0 == $1 }.count
        if commonPrefixCount < cachedTokens.count {
            resetCache()
            commonPrefixCount = 0
        }
        if cachedTokens.count < commonPrefixCount {
            try await advance(with: Array(tokens[cachedTokens.count..<commonPrefixCount]))
        }
        if cachedTokens.count > commonPrefixCount {
            // This should not happen; reset to be safe.
            resetCache()
        }
        if cachedTokens.count < tokens.count {
            try await advance(with: Array(tokens[cachedTokens.count..<tokens.count]))
        }
        let requiredCount = tokens.count * cachedVocabSize
        let values = Array(cachedLogits.prefix(requiredCount))
        return ZenzCoreMLLogits(values: values, vocabSize: cachedVocabSize, timeSteps: tokens.count)
    }

    private static func loadTokenizer() async throws -> any Tokenizer {
        guard let tokenizerDirectory = ZenzCoreMLResources.tokenizerDirectory else {
            throw ZenzCoreMLError.tokenizerNotFound
        }
        do {
            return try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
        } catch {
            throw ZenzCoreMLError.tokenizerLoadFailed(error.localizedDescription)
        }
    }

    private func advance(with chunk: [Int]) async throws {
        guard !chunk.isEmpty else { return }
        let (inputIDs, attentionMask) = try Self.makeInputArrays(from: chunk)
        let inputProvider = Stateful8BitInput(inputIDs: inputIDs, attentionMask: attentionMask)
        let features = try await modelBox.model.prediction(from: inputProvider, using: evalState)
        guard let logitsArray = features.featureValue(for: "logits")?.multiArrayValue else {
            throw ZenzCoreMLError.missingLogits
        }
        if cachedVocabSize == 0 {
            cachedVocabSize = logitsArray.shape[2].intValue
        }
        cachedTokens += chunk
        cachedLogits += Self.flatten(logitsArray)
    }

    private func resetCache() {
        cachedTokens = []
        cachedLogits = []
        cachedVocabSize = 0
        evalState = modelBox.model.makeState()
    }

    private static func makeInputArrays(from tokens: [Int]) throws -> (MLMultiArray, MLMultiArray) {
        let sequenceLength = tokens.count
        let shape = [NSNumber(value: 1), NSNumber(value: sequenceLength)]
        guard
            let inputIDs = try? MLMultiArray(shape: shape, dataType: .int32),
            let attentionMask = try? MLMultiArray(shape: shape, dataType: .int32)
        else {
            throw ZenzCoreMLError.multiArrayCreationFailed
        }
        for (idx, token) in tokens.enumerated() {
            inputIDs[idx] = NSNumber(value: token)
            attentionMask[idx] = 1
        }
        return (inputIDs, attentionMask)
    }

    private static func flatten(_ logits: MLMultiArray) -> [Float] {
        let count = logits.count
        var buffer = [Float](repeating: 0, count: count)
        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float.self)
            buffer.withUnsafeMutableBufferPointer {
                $0.baseAddress?.update(from: ptr, count: count)
            }
        case .float16:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<count {
                buffer[i] = Float(ptr[i])
            }
        default:
            for i in 0..<count {
                buffer[i] = logits[i].floatValue
            }
        }
        return buffer
    }
}

@available(iOS 18.0, macOS 15.0, *)
private final class Stateful8BitInput: MLFeatureProvider {
    private let inputIDs: MLMultiArray
    private let attentionMask: MLMultiArray

    init(inputIDs: MLMultiArray, attentionMask: MLMultiArray) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
    }

    var featureNames: Set<String> {
        ["input_ids", "attention_mask"]
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "input_ids":
            return MLFeatureValue(multiArray: inputIDs)
        case "attention_mask":
            return MLFeatureValue(multiArray: attentionMask)
        default:
            return nil
        }
    }
}

/// Calculates `argmax` over the vocab dimension for the specified batch/time slice.
private func argmaxLogitsRow(_ logits: MLMultiArray, batch: Int, time: Int) -> Int {
    let batchSize = logits.shape[0].intValue
    let seqLen = logits.shape[1].intValue
    let vocabSize = logits.shape[2].intValue
    guard batch >= 0, batch < batchSize, time >= 0, time < seqLen else {
        return 0
    }

    let base = (batch * seqLen + time) * vocabSize
    let totalCount = logits.count
    guard base >= 0, base + vocabSize <= totalCount else {
        return 0
    }

    switch logits.dataType {
    case .float32:
        let ptr = logits.dataPointer.assumingMemoryBound(to: Float.self)
        var bestID = 0
        var bestScore = -Float.infinity
        for vocabIndex in 0..<vocabSize {
            let score = ptr[base + vocabIndex]
            if score > bestScore {
                bestScore = score
                bestID = vocabIndex
            }
        }
        return bestID
    case .float16:
        let ptr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
        var bestID = 0
        var bestScore = -Float.infinity
        for vocabIndex in 0..<vocabSize {
            let score = Float(ptr[base + vocabIndex])
            if score > bestScore {
                bestScore = score
                bestID = vocabIndex
            }
        }
        return bestID
    default:
        var bestID = 0
        var bestScore = -Float.infinity
        for vocabIndex in 0..<vocabSize {
            let value = logits[[NSNumber(value: batch), NSNumber(value: time), NSNumber(value: vocabIndex)]].floatValue
            if value > bestScore {
                bestScore = value
                bestID = vocabIndex
            }
        }
        return bestID
    }
}
