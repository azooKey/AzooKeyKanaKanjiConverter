import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

extension Subcommands {
    struct Session: AsyncParsableCommand {
        private enum PresentationCommand {
            case nextPage
            case previousPage
            case setSource(AncoSessionPresentationContext.CandidateSource)
            case setPhase(AncoSessionPresentationContext.Phase)
            case setLiveConversion(Bool)
            case selectCandidate(Int)

            init?(decoding command: String) {
                switch command {
                case ":n", ":next":
                    self = .nextPage
                case ":p", ":prev":
                    self = .previousPage
                case let command where command == ":src main" || command == ":source main":
                    self = .setSource(.main)
                case let command where command == ":src prediction" || command == ":source prediction":
                    self = .setSource(.prediction)
                case let command where command == ":phase composing":
                    self = .setPhase(.composing)
                case let command where command == ":phase previewing":
                    self = .setPhase(.previewing)
                case let command where command == ":phase selecting":
                    self = .setPhase(.selecting)
                case let command where command == ":live on":
                    self = .setLiveConversion(true)
                case let command where command == ":live off":
                    self = .setLiveConversion(false)
                case let command where command == ":sel" || command.hasPrefix(":sel "):
                    let parts = command.split(separator: " ")
                    guard parts.count == 2, let index = Int(parts[1]) else {
                        return nil
                    }
                    self = .selectCandidate(index)
                default:
                    return nil
                }
            }
        }

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

            var presentationContext = AncoSessionPresentationContext()
            var candidatePageStart = 0
            var inputs = try self.loadReplayInputs()
            while true {
                print()
                print("\(bold: "== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==")")

                let rawInput: String
                if inputs != nil {
                    rawInput = inputs!.removeFirst()
                } else {
                    guard let line = readLine(strippingNewline: true) else {
                        return
                    }
                    rawInput = line
                }

                if let command = PresentationCommand(decoding: rawInput) {
                    self.handlePresentationCommand(
                        command,
                        session: session,
                        context: &presentationContext,
                        candidatePageStart: &candidatePageStart
                    )
                    continue
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
                    let result: AncoSession.ExecutionResult
                    switch command {
                    case let .selectCandidate(index):
                        presentationContext.phase = .selecting
                        presentationContext.selectedIndex = index
                        let presentation = AncoSessionPresenter.present(session: session, context: presentationContext)
                        guard let candidate = presentation.selectedCandidate else {
                            throw AncoSession.SessionError.invalidCandidateIndex(index)
                        }
                        session.recordHistory(command)
                        result = session.commit(candidate: candidate, submittedCommand: command)
                        presentationContext.phase = .composing
                        presentationContext.selectedIndex = nil
                        candidatePageStart = 0

                    default:
                        result = try session.execute(command)
                        self.updatePresentationContext(
                            after: command,
                            result: result,
                            context: &presentationContext,
                            candidatePageStart: &candidatePageStart
                        )
                    }
                    self.printResult(
                        result,
                        session: session,
                        context: presentationContext,
                        candidatePageStart: candidatePageStart
                    )
                    if result.action == .quit {
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

        private func printResult(
            _ result: AncoSession.ExecutionResult,
            session: AncoSession,
            context: AncoSessionPresentationContext,
            candidatePageStart: Int
        ) {
            let presentation = AncoSessionPresenter.present(session: session, context: context)
            switch result.action {
            case .quit:
                return

            case .helpRequested:
                if let message = result.message {
                    print(message)
                }
                print(":src main|prediction - switch candidate source")
                print(":phase composing|previewing|selecting - switch presentation phase")
                print(":live on|off - toggle live conversion presentation")
                print(":sel N - focus the Nth candidate in the active source")
                print(":n, :next / :p, :prev - page through presented candidates")

            case .stateCleared, .saved:
                if let message = result.message {
                    print(message)
                }

            case .configUpdated:
                if let message = result.message {
                    print(message)
                }

            case .candidatesUpdated:
                if let message = result.message {
                    print(message)
                }
                if let predictiveInputTime = result.predictiveInputTime {
                    print("\(bold: "Time (ip):") \(predictiveInputTime)")
                }
                print(self.renderMarkedText(presentation.markedText))
                self.printCandidates(
                    self.displayedCandidates(
                        presentation.candidates,
                        start: candidatePageStart,
                        pageSize: session.displayTopN
                    ),
                    startIndex: candidatePageStart
                )
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

        private func handlePresentationCommand(
            _ command: PresentationCommand,
            session: AncoSession,
            context: inout AncoSessionPresentationContext,
            candidatePageStart: inout Int
        ) {
            switch command {
            case .nextPage:
                let candidates = AncoSessionPresenter.present(session: session, context: context).candidates
                guard !candidates.isEmpty else {
                    print("No candidates")
                    return
                }
                let lastPageStart = ((candidates.count - 1) / session.displayTopN) * session.displayTopN
                candidatePageStart = min(candidatePageStart + session.displayTopN, lastPageStart)

            case .previousPage:
                candidatePageStart = max(0, candidatePageStart - session.displayTopN)

            case let .setSource(source):
                context.candidateSource = source
                context.selectedIndex = nil
                candidatePageStart = 0

            case let .setPhase(phase):
                context.phase = phase
                if phase != .selecting {
                    context.selectedIndex = nil
                }

            case let .setLiveConversion(enabled):
                context.liveConversion = enabled

            case let .selectCandidate(index):
                context.phase = .selecting
                context.selectedIndex = index
            }

            self.printPresentation(session: session, context: context, candidatePageStart: candidatePageStart)
        }

        private func updatePresentationContext(
            after command: AncoSessionRequest,
            result: AncoSession.ExecutionResult,
            context: inout AncoSessionPresentationContext,
            candidatePageStart: inout Int
        ) {
            switch command {
            case .clearComposition:
                context.selectedIndex = nil
                context.phase = .composing
                candidatePageStart = 0

            case .input, .deleteBackward, .moveCursor, .editSegment, .predictInput, .specialInput:
                context.selectedIndex = nil
                if result.action == .candidatesUpdated {
                    context.phase = .composing
                    candidatePageStart = 0
                }

            default:
                break
            }
        }

        private func printPresentation(
            session: AncoSession,
            context: AncoSessionPresentationContext,
            candidatePageStart: Int
        ) {
            let presentation = AncoSessionPresenter.present(session: session, context: context)
            print(self.renderMarkedText(presentation.markedText))
            self.printCandidates(
                self.displayedCandidates(
                    presentation.candidates,
                    start: candidatePageStart,
                    pageSize: session.displayTopN
                ),
                startIndex: candidatePageStart
            )
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

        private func printCandidates(_ candidates: [Candidate], startIndex: Int = 0) {
            for (index, candidate) in candidates.enumerated() {
                if self.options.reportScore {
                    print("\(bold: String(startIndex + index)). \(candidate.text) \(bold: "score:") \(candidate.value)")
                } else {
                    print("\(bold: String(startIndex + index)). \(candidate.text)")
                }
            }
        }

        private func displayedCandidates(_ candidates: [Candidate], start: Int, pageSize: Int) -> [Candidate] {
            guard start < candidates.count else {
                return []
            }
            let end = min(candidates.count, start + pageSize)
            return Array(candidates[start..<end])
        }

        private func renderMarkedText(_ markedText: AncoSessionMarkedText) -> String {
            markedText.text.map { element in
                switch element.focus {
                case .focused:
                    "[\(element.content)]"
                case .unfocused, .none:
                    element.content
                }
            }.joined()
        }
    }
}
