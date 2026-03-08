import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

extension Subcommands {
    struct Session: AsyncParsableCommand {
        @Argument(help: "ひらがなで表記された入力")
        var input: String = ""

        @OptionGroup
        var options: SharedConversionOptions

        @Option(name: [.customLong("replay")], help: "history.txt for replay.")
        var replayHistory: String?

        static let configuration = CommandConfiguration(commandName: "session", abstract: "Start session for incremental input.")

        @MainActor mutating func run() async throws {
            if self.options.zenzV2 {
                print("\(bold: "We strongly recommend to use zenz-v3 models")")
            }
            if !self.options.zenzWeightPath.isEmpty && (!self.options.zenzV2 && !self.options.zenzV3) {
                print("zenz version is not specified. By default, zenz-v3 will be used.")
            }

            let requestOptions = try self.options.makeRequestOptions()
            let userDictionaryItems = try self.options.parseUserDictionaryItems()
            var session = AncoSession(
                defaultDictionaryRequestOptions: requestOptions,
                inputStyle: self.options.inputStyle,
                displayTopN: self.options.displayTopN,
                debugPossibleNexts: true,
                userDictionaryItems: userDictionaryItems
            )

            print("Working with \(requestOptions.learningType) mode. Memory path is \(session.memoryDirectoryURL).")

            var inputs = try self.loadReplayInputs()
            while true {
                print()
                print("\(bold: "== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==")")
                if !session.leftSideContext.isEmpty {
                    print("\(bold: "Current Left-Side Context"): \(session.leftSideContext)")
                }

                let rawInput: String
                if inputs != nil {
                    rawInput = inputs!.removeFirst()
                } else {
                    rawInput = readLine(strippingNewline: true) ?? ""
                }

                guard let command = AncoSessionRequest(decoding: rawInput) else {
                    print("\(bold: "Error"): Failed to parse command: \(rawInput)")
                    continue
                }

                do {
                    if case let .typoCorrection(command) = command {
                        session.recordHistory(.typoCorrection(command))
                        let result = session.experimentalRequestTypoCorrection(
                            config: self.options.makeExperimentalTypoCorrectionConfig(from: command)
                        )
                        self.printTypoCorrectionResult(result)
                        continue
                    }
                    let result = try session.execute(command)
                    self.printResult(result)
                    if result.shouldQuit {
                        return
                    }
                } catch {
                    print("\(bold: "Error"): \(error.localizedDescription)")
                }
            }
        }

        private func loadReplayInputs() throws -> [String]? {
            guard let replayHistory else {
                return nil
            }
            var inputs = try String(contentsOfFile: replayHistory, encoding: .utf8)
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
            inputs.append(":q")
            return inputs
        }

        private func printResult(_ result: AncoSession.ExecutionResult) {
            switch result.action {
            case .quit:
                return

            case .helpRequested:
                if let message = result.message {
                    print(message)
                }
                print(":tc [n] [beam=N] [top_k=N] [max_steps=N] [alpha=F] [beta=F] [gamma=F] - typo correction candidates (LM + channel)")

            case .stateCleared, .saved, .configUpdated:
                if let message = result.message {
                    print(message)
                }

            case .pageUpdated:
                self.printCandidates(result.displayedCandidates)

            case .candidatesUpdated:
                if let message = result.message {
                    print(message)
                }
                if let predictiveInputTime = result.predictiveInputTime {
                    print("\(bold: "Time (ip):") \(predictiveInputTime)")
                }
                print(result.composingText.convertTarget)
                self.printCandidates(result.displayedCandidates)
                if let entropy = result.entropy {
                    print("\(bold: "Entropy:") \(entropy)")
                }
                if let elapsedTime = result.elapsedTime {
                    print("\(bold: "Time:") \(elapsedTime)")
                }

            case .noAction:
                if let message = result.message {
                    print(message)
                }
            }
        }

        private func printTypoCorrectionResult(_ result: AncoSession.TypoCorrectionResult) {
            if result.candidates.isEmpty {
                print("No typo correction candidate found.")
            } else {
                for (index, candidate) in result.candidates.enumerated() {
                    print(
                        "\(bold: String(index)). \(candidate.correctedInput) " +
                        "\(bold: "score:") \(candidate.score) " +
                        "\(bold: "lm:") \(candidate.lmScore) " +
                        "\(bold: "channel:") \(candidate.channelCost) " +
                        "\(bold: "prom:") \(candidate.prominence) " +
                        "\(bold: "text:") \(candidate.convertedText)"
                    )
                }
            }
            print("\(bold: "Time (tc):") \(result.elapsedTime)")
        }

        private func printCandidates(_ candidates: [Candidate]) {
            for (index, candidate) in candidates.enumerated() {
                if self.options.reportScore {
                    print("\(bold: String(index)). \(candidate.text) \(bold: "score:") \(candidate.value)")
                } else {
                    print("\(bold: String(index)). \(candidate.text)")
                }
            }
        }
    }
}
