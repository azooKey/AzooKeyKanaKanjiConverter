import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

extension Subcommands {
    struct Run: AsyncParsableCommand {
        @Argument(help: "ひらがなで表記された入力")
        var input: String = ""

        @OptionGroup
        var options: SharedConversionOptions

        static let configuration = CommandConfiguration(commandName: "run", abstract: "Show help for this utility.")

        @MainActor mutating func run() async throws {
            var session = AncoSession(
                defaultDictionaryRequestOptions: try self.options.makeRequestOptions(),
                inputStyle: self.options.inputStyle,
                displayTopN: self.options.displayTopN,
                userDictionaryItems: try self.options.parseUserDictionaryItems()
            )
            let result = try session.execute(.input(self.input))

            for candidate in result.displayedCandidates {
                if self.options.reportScore {
                    print("\(candidate.text) \(bold: "score:") \(candidate.value)")
                } else {
                    print(candidate.text)
                }
            }
            if let entropy = result.entropy {
                print("\(bold: "Entropy:") \(entropy)")
            }
        }
    }
}
