import Foundation
import EfficientNGram
import ArgumentParser

extension Subcommands.NGram {
    struct Inference: ParsableCommand {
        @Argument(help: "学習済みのLM")
        var lmPattern: String = ""

        @Option(name: [.customLong("another_lm")], help: "Another lm for flavored decoding")
        var anotherLMPattern: String?

        @Option(name: [.customLong("alpha")], help: "alpha for flavored decoding")
        var alpha: Double = 0.5

        @Option(name: [.customLong("prompt"), .customShort("p")], help: "The prompt for inference.")
        var prompt: String = "これは"

        @Option(name: [.customShort("n")], help: "n-gram's n")
        var n: Int = 5

        @Option(name: [.customLong("length"), .customShort("l")], help: "token length for generation")
        var length: Int = 100

        static let configuration = CommandConfiguration(
            commandName: "inference",
            abstract: "Inference using ngram"
        )

        private func measureExecutionTime(block: () -> String) -> (String, Double) {
            let start = DispatchTime.now()
            let result = block()
            let end = DispatchTime.now()
            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
            let milliTime = Double(nanoTime) / 1_000_000 // ミリ秒単位
            return (result, milliTime)
        }

        mutating func run() throws {
            print("Loading LM base: \(self.lmPattern)")
            let tokenizer = ZenzTokenizer()
            let lmBase = EfficientNGram(baseFilename: self.lmPattern, n: self.n, d: 0.75, tokenizer: tokenizer)
            let lmPerson = if let anotherLMPattern {
                EfficientNGram(baseFilename: anotherLMPattern, n: self.n, d: 0.75, tokenizer: tokenizer)
            } else {
                lmBase
            }
            let (generatedText, elapsedTime) = measureExecutionTime {
                generateText(
                    inputText: self.prompt,
                    mixAlpha: self.alpha,
                    lmBase: lmBase,
                    lmPerson: lmPerson,
                    tokenizer: tokenizer,
                    maxCount: self.length
                )
            }
            print("\(bold: "Generated"): \(generatedText)")
            print("\(bold: "Execution Time"): \(elapsedTime) ms")
        }
    }
}
