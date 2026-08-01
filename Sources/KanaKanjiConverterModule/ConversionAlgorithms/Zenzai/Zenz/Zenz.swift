import EfficientNGram
package import Foundation
import SwiftUtils

/// 同一モデルのnative contextをConverter間で共有する。
///
/// CPU推論を直列化することで、複数Converterが同時に18 MiBのKV cacheを保持する
/// ことを避ける。context内のKV再利用は毎回完全なtoken prefixを照合するため、
/// セッションを跨いでも推論結果には影響しない。
private final class SharedZenzCache: @unchecked Sendable {
    static let shared = SharedZenzCache()

    private init() {
        self.cache.countLimit = 1
    }

    func zenz(resourceURL: URL) throws -> Zenz {
        try self.lock.withLock {
            let key = resourceURL.absoluteString as NSString
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            let zenz = try Zenz(resourceURL: resourceURL)
            self.cache.setObject(zenz, forKey: key)
            return zenz
        }
    }

    private let cache = NSCache<NSString, Zenz>()
    private let lock = NSLock()
}

package final class Zenz {
    package var resourceURL: URL
    private var zenzContext: ZenzContext?
    private let inferenceLock = NSLock()

    package static func shared(resourceURL: URL) throws -> Zenz {
        try SharedZenzCache.shared.zenz(resourceURL: resourceURL)
    }

    init(resourceURL: URL) throws {
        self.resourceURL = resourceURL
        do {
            #if canImport(Darwin)
            if #available(iOS 16, macOS 13, *) {
                self.zenzContext = try ZenzContext.createContext(path: resourceURL.path(percentEncoded: false))
            } else {
                // this is not percent-encoded
                self.zenzContext = try ZenzContext.createContext(path: resourceURL.path)
            }
            #else
            // this is not percent-encoded
            self.zenzContext = try ZenzContext.createContext(path: resourceURL.path)
            #endif
            debug("Loaded model \(resourceURL.lastPathComponent)")
        } catch {
            throw error
        }
    }

    package func endSession() {
        // contextはモデル単位で共有される。各呼び出し時にtoken prefixを照合して
        // 不一致範囲を除去するため、Converter単位のnative context再生成は不要。
    }

    func candidateEvaluate(
        convertTarget: String,
        convertTargetCursorPosition: Int? = nil,
        candidates: [Candidate],
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return .error
            }
            for candidate in candidates {
                return ZenzCandidateEvaluator.evaluate(
                    context: zenzContext,
                    input: convertTarget.toKatakana(),
                    inputCursorPosition: convertTargetCursorPosition,
                    candidate: candidate,
                    requestRichCandidates: requestRichCandidates,
                    prefixConstraint: prefixConstraint,
                    personalizationMode: personalizationMode,
                    versionDependentConfig: versionDependentConfig,
                    memoizationCache: memoizationCache
                )
            }
            return .error
        }
    }

    func predictNextInputText(
        leftSideContext: String,
        composingText: String,
        count: Int,
        minLength: Int = 1,
        maxEntropy: Float?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        possibleNexts: [String] = []
    ) -> String {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return ""
            }
            return ZenzInputTextGenerator.generate(
                context: zenzContext,
                leftSideContext: leftSideContext,
                composingText: composingText,
                count: count,
                minLength: minLength,
                maxEntropy: maxEntropy,
                versionDependentConfig: versionDependentConfig,
                possibleNexts: possibleNexts
            )
        }
    }

    package func pureGreedyDecoding(pureInput: String, maxCount: Int = .max) -> String {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return ""
            }
            return ZenzPureGreedyDecoder.decode(
                context: zenzContext,
                leftSideContext: pureInput,
                maxCount: maxCount
            )
        }
    }

    func generateTypoCandidates(
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        experimentalConfig: ExperimentalTypoCorrectionConfig,
        cache: ZenzaiTypoGenerationCache
    ) -> [ZenzaiTypoCandidate] {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return []
            }
            return ZenzaiTypoCandidateGenerator.generate(
                context: zenzContext,
                leftSideContext: leftSideContext,
                composingText: composingText,
                inputStyle: inputStyle,
                experimentalConfig: experimentalConfig,
                cache: cache
            )
        }
    }
}
