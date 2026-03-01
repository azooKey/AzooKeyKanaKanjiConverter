@testable import EfficientNGram
import Foundation
import Tokenizers
import XCTest

class SwiftNGramTests: XCTestCase {
    #if canImport(SwiftyMarisa)
    func testTokenizers() throws {
        let tokenizer = ZenzTokenizer()
        let inputIds = tokenizer.encode(text: "これは日本語です")
        XCTAssertEqual(inputIds, [268, 262, 253, 304, 358, 698, 246, 255])
        XCTAssertEqual(tokenizer.decode(tokens: inputIds), "これは日本語です")
    }
    #endif

    #if canImport(SwiftyMarisa) && Zenzai
    private struct LCG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) {
            self.state = seed
        }
        mutating func next() -> UInt64 {
            state = 6364136223846793005 &* state &+ 1
            return state
        }
    }

    private static let randomCharacters: [String] = {
        let hiragana = (0x3042 ... 0x3093).compactMap { codePoint -> String? in
            UnicodeScalar(codePoint).map { String($0) }
        }
        return hiragana + ["ー"]
    }()

    private func makeRandomLine(length: Int, rng: inout LCG) -> String {
        var parts: [String] = []
        parts.reserveCapacity(length)
        for _ in 0 ..< length {
            let index = Int(rng.next() % UInt64(Self.randomCharacters.count))
            parts.append(Self.randomCharacters[index])
        }
        return parts.joined()
    }

    func testTrainProfileRandomAonCorpus() throws {
        guard ProcessInfo.processInfo.environment["ENABLE_NGRAM_PROFILE_TEST"] == "1" else {
            throw XCTSkip("Set ENABLE_NGRAM_PROFILE_TEST=1 to run this profiling test.")
        }

        let lineCount = 20_000
        let lineLength = 100
        var rng = LCG(seed: 0xA0A0_A0A0)

        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for _ in 0 ..< lineCount {
            lines.append(makeRandomLine(length: lineLength, rng: &rng))
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngram_profile_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: outputDir)
        }

        let start = Date()
        trainNGram(lines: lines, n: 5, baseFilePattern: "lm", outputDir: outputDir.path, resumeFilePattern: nil)
        let elapsed = Date().timeIntervalSince(start)
        print("ProfileResult lineCount=\(lineCount) lineLength=\(lineLength) elapsed=\(elapsed)s outputDir=\(outputDir.path)")
    }

    func testTrainProfileRandomAonCorpusFromFile() throws {
        guard ProcessInfo.processInfo.environment["ENABLE_NGRAM_FILE_PROFILE_TEST"] == "1" else {
            throw XCTSkip("Set ENABLE_NGRAM_FILE_PROFILE_TEST=1 to run this profiling test.")
        }

        let lineCount = 20_000
        let lineLength = 100
        var rng = LCG(seed: 0xA0A0_A0A1)

        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for _ in 0 ..< lineCount {
            lines.append(makeRandomLine(length: lineLength, rng: &rng))
        }

        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngram_profile_from_file_\(UUID().uuidString)", isDirectory: true)
        let inputFile = rootDir.appendingPathComponent("train.txt")
        let outputDir = rootDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootDir)
        }

        let corpus = lines.joined(separator: "\n") + "\n"
        try corpus.write(to: inputFile, atomically: true, encoding: .utf8)

        let start = Date()
        trainNGramFromFile(
            filePath: inputFile.path,
            n: 5,
            baseFilePattern: "lm",
            outputDir: outputDir.path,
            resumeFilePattern: nil
        )
        let elapsed = Date().timeIntervalSince(start)
        print(
            "ProfileResultFromFile lineCount=\(lineCount) lineLength=\(lineLength) elapsed=\(elapsed)s inputFile=\(inputFile.path) outputDir=\(outputDir.path)"
        )
    }

    func testTokenizerDecodedVocabBoundaryProbe() throws {
        let tokenizer = ZenzTokenizer()
        let vocabSize = tokenizer.vocabSize

        var nonEmptyDecodedCount = 0
        var multiScalarTokenCount = 0
        var multiGraphemeTokenCount = 0
        var singleGraphemeMultiScalarTokenCount = 0
        var samples: [String] = []
        samples.reserveCapacity(12)

        for id in 0 ..< vocabSize {
            let decoded = tokenizer.decode(tokens: [id])
            guard !decoded.isEmpty else { continue }
            nonEmptyDecodedCount += 1

            let scalarCount = decoded.unicodeScalars.count
            let graphemeCount = decoded.count

            if scalarCount > 1 {
                multiScalarTokenCount += 1
                if samples.count < 12 {
                    samples.append("id=\(id) '\(decoded)' scalars=\(scalarCount) graphemes=\(graphemeCount)")
                }
                if graphemeCount == 1 {
                    singleGraphemeMultiScalarTokenCount += 1
                }
            }
            if graphemeCount > 1 {
                multiGraphemeTokenCount += 1
            }
        }

        print(
            """
            TokenizerVocabProbe vocab=\(vocabSize) nonEmpty=\(nonEmptyDecodedCount) \
            multiScalar=\(multiScalarTokenCount) multiGrapheme=\(multiGraphemeTokenCount) \
            singleGraphemeMultiScalar=\(singleGraphemeMultiScalarTokenCount)
            """
        )
        for line in samples {
            print("TokenizerVocabProbe sample \(line)")
        }

        XCTAssertGreaterThan(
            multiScalarTokenCount,
            0,
            "decode([id]) で Unicode scalar が2以上のtokenがあるなら、strictなコードポイント単位分割ではない"
        )
    }

    func testFastTokenizerPathMatchesSlowForRepresentativeInputs() throws {
        let tokenizer = ZenzTokenizer(enableFastTokenizerPath: true)
        let samples = [
            "これは日本語です",
            "あいうえお",
            "ガッツポーズ",
            "。、！？（）",
            "abcXYZ123",
            "2026-03-01",
            "🇯🇵",
            "❤️",
            "e\u{301}",
            "ば"
        ]

        for sample in samples {
            let fast = tokenizer.encode(text: sample)
            let slow = tokenizer.encodeSlow(text: sample)
            XCTAssertEqual(fast, slow, "mismatch for sample=\(sample)")
        }
    }
    #endif
}
