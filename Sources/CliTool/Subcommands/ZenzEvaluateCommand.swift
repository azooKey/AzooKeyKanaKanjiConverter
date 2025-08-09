import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

extension Subcommands {
    struct ZenzEvaluate: AsyncParsableCommand {
        @Argument(help: "query, answer, tagを備えたjsonファイルへのパス")
        var inputFile: String = ""

        @Option(name: [.customLong("output")], help: "Output file path.")
        var outputFilePath: String?
        @Flag(name: [.customLong("stable")], help: "Report only stable properties; timestamps and values will not be reported.")
        var stable: Bool = false
        @Option(name: [.customLong("zenz")], help: "gguf format model weight for zenz.")
        var zenzWeightPath: String = ""

        static let configuration = CommandConfiguration(commandName: "zenz_evaluate", abstract: "Evaluate quality of pure zenz's Conversion for input data.")

        private func parseInputFile() throws -> [EvaluationInputItem] {
            let url = URL(fileURLWithPath: self.inputFile)
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([EvaluationInputItem].self, from: data)
        }

        private func greedyDecoding(query: String, leftContext: String?, zenz: Zenz, maxCount: Int) async -> String {
            var leftContext = if let leftContext {
                "\u{EE02}" + String(leftContext.suffix(40))
            } else {
                ""
            }
            leftContext = "\u{EE00}\(query)\(leftContext)\u{EE01}"
            return await zenz.pureGreedyDecoding(pureInput: leftContext, maxCount: maxCount)
        }

        mutating func run() async throws {
            let inputItems = try parseInputFile()
            let converter = await KanaKanjiConverter.withDefaultDictionary()
            var executionTime: Double = 0
            var resultItems: [EvaluateItem] = []

            guard let zenz = await converter.getModel(modelURL: URL(string: self.zenzWeightPath)!) else {
                print("Failed to initialize zenz model")
                return
            }

            for item in inputItems {
                let start = Date()
                if item.user_dictionary != nil {
                    print("Warning: zenz_evaluate command does not suppport user dictionary. User Dictionary Contents are just ignored.")
                }
                // 変換
                let result = await self.greedyDecoding(query: item.query, leftContext: item.left_context, zenz: zenz, maxCount: item.answer.map(\.utf8.count).max()!)
                print("Results:", result)
                resultItems.append(
                    EvaluateItem(
                        query: item.query,
                        answers: item.answer,
                        left_context: item.left_context,
                        outputs: [
                            EvaluateItemOutput(text: result, score: 0.0)
                        ]
                    )
                )
                executionTime += Date().timeIntervalSince(start)
                await zenz.endSession()
            }
            var result = EvaluateResult(n_best: 1, execution_time: executionTime, items: resultItems)
            if stable {
                result.execution_time = 0
                result.timestamp = 0
                result.items.mutatingForEach {
                    $0.outputs.mutatingForEach {
                        $0.score = Double(Int($0.score))
                    }
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(result)

            if let outputFilePath {
                try json.write(to: URL(fileURLWithPath: outputFilePath))
            } else {
                let string = String(data: json, encoding: .utf8)!
                print(string)
            }
        }
    }
}
