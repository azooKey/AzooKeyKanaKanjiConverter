import Foundation
import KanaKanjiConverterModule
import ArgumentParser

extension Subcommands.Dict {
    struct Read: ParsableCommand {
        enum SortOrder: String, Codable, ExpressibleByArgument {
            case value
            case ruby
            case word

            init?(argument: String) {
                self.init(rawValue: argument)
            }
        }

        @Argument(help: "辞書データのfilename")
        var target: String = ""

        @Option(name: [.customLong("dictionary_dir"), .customShort("d")], help: "The directory for dictionary data.")
        var dictionaryDirectory: String = "./"

        @Option(name: [.customLong("ruby")], help: "Regex for entry ruby filter")
        var rubyFilter: String = ""

        @Option(name: [.customLong("word")], help: "Regex for entry word filter")
        var wordFilter: String = ""

        @Option(name: [.customLong("sort")], help: "Sort order")
        var sortOrder: SortOrder = .ruby

        static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Read dictionary data and extract informations"
        )

        mutating func run() throws {
            guard #available(macOS 13, *) else {
                return
            }
            let start = Date()
            let isMemory = self.target == "memory"
            guard let louds = LOUDS.load(self.target, option: self.requestOptions()) else {
                print(
                    """
                    \(bold: "=== Summary for target \(self.target) ===")
                    - directory: \(self.dictionaryDirectory)
                    - target: \(self.target)
                    - memory?: \(isMemory)
                    - result: LOUDS data was not found
                    - time for execute: \(Date().timeIntervalSince(start))
                    """
                )
                return
            }
            // ありったけ取り出す
            let nodeIndices = louds.prefixNodeIndices(chars: [], maxDepth: .max)
            let store = DicdataStore(convertRequestOptions: self.requestOptions())
            let result = store.getDicdataFromLoudstxt3(identifier: self.target, indices: nodeIndices)
            var filteredResult = result
            var hasFilter = false
            if !rubyFilter.isEmpty {
                let filter = try Regex(rubyFilter)
                hasFilter = true
                filteredResult = filteredResult.filter {
                    $0.ruby.wholeMatch(of: filter) != nil
                }
            }
            if !wordFilter.isEmpty {
                let filter = try Regex(wordFilter)
                hasFilter = true
                filteredResult = filteredResult.filter {
                    $0.word.wholeMatch(of: filter) != nil
                }
            }

            print(
                """
                \(bold: "=== Summary for target \(self.target) ===")
                - directory: \(self.dictionaryDirectory)
                - target: \(self.target)
                - memory?: \(isMemory)
                - count of entry: \(result.count)
                - time for execute: \(Date().timeIntervalSince(start))
                """
            )

            if hasFilter {
                let sortFunction: (DicdataElement, DicdataElement) -> Bool = switch self.sortOrder {
                case .ruby: { $0.ruby < $1.ruby || $0.ruby.count < $1.ruby.count}
                case .value: { $0.value() < $1.value() }
                case .word: { $0.word < $1.word }
                }

                print("\(bold: "=== Found Entries ===")")
                print("- count of found entry: \(filteredResult.count)")
                for entry in filteredResult.sorted(by: sortFunction) {
                    print("\(bold: "Ruby:") \(entry.ruby) \(bold: "Word:") \(entry.word) \(bold: "Value:") \(entry.value()) \(bold: "CID:") \((entry.lcid, entry.rcid)) \(bold: "MID:") \(entry.mid)")
                }
            }
        }

        func requestOptions() -> ConvertRequestOptions {
            .init(
                N_best: 0,
                requireJapanesePrediction: false,
                requireEnglishPrediction: false,
                keyboardLanguage: .ja_JP,
                typographyLetterCandidate: false,
                unicodeCandidate: true,
                englishCandidateInRoman2KanaInput: true,
                fullWidthRomanCandidate: false,
                halfWidthKanaCandidate: false,
                learningType: .nothing,
                maxMemoryCount: 0,
                dictionaryResourceURL: URL(fileURLWithPath: self.dictionaryDirectory),
                memoryDirectoryURL: URL(fileURLWithPath: self.dictionaryDirectory),
                sharedContainerURL: URL(fileURLWithPath: self.dictionaryDirectory),
                textReplacer: .empty,
                metadata: .init(versionString: "anco for debugging")
            )
        }
    }
}
