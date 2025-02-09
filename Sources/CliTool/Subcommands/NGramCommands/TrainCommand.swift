import Foundation
import EfficientNGram
import ArgumentParser

extension Subcommands.NGram {
    struct Train: ParsableCommand {
        @Argument(help: "学習テキストデータのfilename")
        var target: String = ""

        @Option(name: [.customLong("output_dir"), .customShort("o")], help: "The directory for output lm data.")
        var outputDirectory: String = "./"

        @Option(name: [.customShort("n")], help: "n-gram's n")
        var n: Int = 5

        static let configuration = CommandConfiguration(
            commandName: "train",
            abstract: "Train ngram and write the data"
        )

        mutating func run() throws {
            let pattern = URL(fileURLWithPath: self.outputDirectory).path() + "lm_"
            print("Saving for \(pattern)")
            trainNGramFromFile(filePath: self.target, n: self.n, baseFilename: "lm", outputDir: self.outputDirectory)
        }
    }
}
