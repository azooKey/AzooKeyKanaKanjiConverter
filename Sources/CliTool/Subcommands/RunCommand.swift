import KanaKanjiConverterModuleWithDefaultDictionary
import ArgumentParser
import Foundation

extension Subcommands {
    struct Run: ParsableCommand {
        @Argument(help: "ひらがなで表記された入力")
        var input: String = ""

        @Option(name: [.customLong("config_n_best")], help: "The parameter n (n best parameter) for internal viterbi search.")
        var configNBest: Int = 10
        @Option(name: [.customShort("n"), .customLong("top_n")], help: "Display top n candidates.")
        var displayTopN: Int = 1

        @Flag(name: [.customLong("disable_prediction")], help: "Disable producing prediction candidates.")
        var disablePrediction = false

        @Flag(name: [.customLong("report_score")], help: "Show internal score for the candidate.")
        var reportScore = false

        static var configuration = CommandConfiguration(commandName: "run", abstract: "Show help for this utility.")

        @MainActor mutating func run() {
            let converter = KanaKanjiConverter()
            var composingText = ComposingText()
            composingText.insertAtCursorPosition(input, inputStyle: .direct)
            let result = converter.requestCandidates(composingText, options: requestOptions())
            for candidate in result.mainResults.prefix(self.displayTopN) {
                if self.reportScore {
                    print("\(candidate.text) \(bold: "score:") \(candidate.value)")
                } else {
                    print(candidate.text)
                }
            }
        }

        func requestOptions() -> ConvertRequestOptions {
            .withDefaultDictionary(
                N_best: configNBest,
                requireJapanesePrediction: !disablePrediction,
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
                metadata: .init(appVersionString: "anco")
            )
        }
    }
}
