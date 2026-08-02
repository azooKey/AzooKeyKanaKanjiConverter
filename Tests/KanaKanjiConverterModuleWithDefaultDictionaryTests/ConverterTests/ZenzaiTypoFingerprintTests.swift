import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

#if Zenzai || ZenzaiCPU
final class ZenzaiTypoFingerprintTests: XCTestCase {
    func testGradualNGramCandidateFingerprint() throws {
        guard let ngramPrefix = ProcessInfo.processInfo.environment["AZOOKEY_DESKTOP_NGRAM_PREFIX"] else {
            throw XCTSkip("Set AZOOKEY_DESKTOP_NGRAM_PREFIX to run the fingerprint test")
        }
        let scenarios: [(String, InputStyle)] = [
            ("このぶんしょうはかんじへんかんがせいかくということでわだいのにほんごにゅうりょくしすてむをつかってうちこんでいます", .direct),
            ("konobunshouhakanjihenkangaseikakutoiukotodewadainonihongonyuuryokusisutemuwotukatteutikondeimasu", .roman2kana),
            ("konobjxphakzzihdkzgasskakutoiuktdewadqnonihlgonyhryokusisutemuwotuka；teutikldwms", .mapped(id: .defaultAZIK))
        ]
        let options = ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            maxMemoryCount: 0,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            typoCorrectionMode: .automatic,
            metadata: nil
        )
        let config = ExperimentalTypoCorrectionConfig(
            languageModel: .ngram(.init(prefix: ngramPrefix, n: 5, d: 0.75)),
            beamSize: 16,
            topK: 32,
            nBest: 3
        )
        var fingerprint: UInt64 = 14_695_981_039_346_656_037

        func appendByte(_ byte: UInt8) {
            fingerprint ^= UInt64(byte)
            fingerprint &*= 1_099_511_628_211
        }
        func appendString(_ string: String) {
            string.utf8.forEach(appendByte)
            appendByte(0xff)
        }
        func appendUInt32(_ value: UInt32) {
            appendByte(UInt8(truncatingIfNeeded: value))
            appendByte(UInt8(truncatingIfNeeded: value >> 8))
            appendByte(UInt8(truncatingIfNeeded: value >> 16))
            appendByte(UInt8(truncatingIfNeeded: value >> 24))
        }

        for (input, inputStyle) in scenarios {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            var composingText = ComposingText()
            for character in input {
                composingText.insertAtCursorPosition(String(character), inputStyle: inputStyle)
                let candidates = converter.experimentalRequestTypoCorrection(
                    leftSideContext: "日本語入力の性能を確認します。",
                    composingText: composingText,
                    options: options,
                    inputStyle: inputStyle,
                    config: config
                )
                appendUInt32(UInt32(candidates.count))
                for candidate in candidates {
                    appendString(candidate.correctedInput)
                    appendString(candidate.convertedText)
                    appendUInt32(candidate.score.bitPattern)
                    appendUInt32(candidate.lmScore.bitPattern)
                    appendUInt32(candidate.channelCost.bitPattern)
                    appendUInt32(candidate.prominence.bitPattern)
                }
            }
        }
        print("[ZenzaiTypoFingerprint] \(String(fingerprint, radix: 16))")
    }
}
#endif
