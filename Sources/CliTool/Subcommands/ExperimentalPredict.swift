import KanaKanjiConverterModuleWithDefaultDictionary
import ArgumentParser
import Foundation

extension Subcommands {
    struct ExperimentalPredict: AsyncParsableCommand {
        @Argument(help: "通常の文字列")
        var input: String = ""

        @Option(name: [.customShort("n"), .customLong("top_n")], help: "Display top n candidates.")
        var displayTopN: Int = 1
        @Option(name: [.customLong("zenz")], help: "gguf format model weight for zenz.")
        var zenzWeightPath: String = ""

        static let configuration = CommandConfiguration(commandName: "experimental_predict", abstract: "Show help for this utility.")

        @MainActor mutating func run() async {
            let converter = KanaKanjiConverter()
            let result = converter.predictNextCharacter(leftSideContext: self.input, count: 10, options: requestOptions())
            for (i, res) in result.indexed() {
                print("\(i). \(res.character): \(res.value)")
            }
        }

        func requestOptions() -> ConvertRequestOptions {
            .withDefaultDictionary(
                N_best: 10,
                requireJapanesePrediction: true,
                requireEnglishPrediction: false,
                keyboardLanguage: .ja_JP,
                typographyLetterCandidate: false,
                unicodeCandidate: true,
                englishCandidateInRoman2KanaInput: true,
                fullWidthRomanCandidate: false,
                halfWidthKanaCandidate: false,
                learningType: .nothing,
                maxMemoryCount: 0,
                shouldResetMemory: false,
                memoryDirectoryURL: URL(fileURLWithPath: ""),
                sharedContainerURL: URL(fileURLWithPath: ""),
                zenzaiMode: self.zenzWeightPath.isEmpty ? .off : .on(weight: URL(string: self.zenzWeightPath)!, inferenceLimit: .max, versionDependentMode: .v3(.init())),
                metadata: .init(versionString: "anco for debugging")
            )
        }
    }
}
