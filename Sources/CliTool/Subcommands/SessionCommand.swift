import ArgumentParser
#if canImport(Darwin)
import Darwin
#endif
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

        @Flag(name: [.customLong("disable-immediate-input")], help: "Require Enter for every input instead of processing regular characters immediately.")
        var disableImmediateInput = false

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

            var inputReader = try SessionInputReader(
                replayInputs: self.loadReplayInputs(),
                disableImmediateInput: self.disableImmediateInput
            )
            defer { inputReader.restoreTerminalIfNeeded() }
            while true {
                print()
                print("\(bold: "== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==")")
                guard let rawInput = inputReader.readInput() else {
                    let result = try session.execute(.quit)
                    self.printResult(result)
                    return
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

        private func printResult(_ result: AncoSession.ExecutionResult) {
            switch result.action {
            case .quit:
                return

            case .helpRequested:
                if let message = result.message {
                    print(message)
                }
                print(":tc [n] [beam=N] [top_k=N] [max_steps=N] [alpha=F] [beta=F] [gamma=F] - typo correction candidates (LM + channel)")

            case .stateCleared, .saved:
                if let message = result.message {
                    print(message)
                }
                if result.action == .stateCleared {
                    self.printComposingLine(
                        leftSideContext: result.leftSideContext,
                        composingText: result.composingText,
                        rightSideContext: result.rightSideContext
                    )
                }

            case .configUpdated:
                if case .setConfig("view", _) = result.submittedCommand {
                    self.printCandidates(result.displayedCandidates)
                } else if let message = result.message {
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
                self.printComposingLine(
                    leftSideContext: result.leftSideContext,
                    composingText: result.composingText,
                    rightSideContext: result.rightSideContext
                )
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
                self.printComposingLine(
                    leftSideContext: result.leftSideContext,
                    composingText: result.composingText,
                    rightSideContext: result.rightSideContext
                )
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

        private func printComposingLine(leftSideContext: String, composingText: ComposingText, rightSideContext: String) {
            let beforeCursor = String(composingText.convertTarget.prefix(composingText.convertTargetCursorPosition))
            let afterCursor = String(composingText.convertTarget.dropFirst(composingText.convertTargetCursorPosition))

            if composingText.isEmpty {
                print("\(leftSideContext)|\(rightSideContext)")
                return
            }

            print("\(leftSideContext)\(inputHighlighted: beforeCursor)|\(inputHighlighted: afterCursor)\(rightSideContext)")
        }
    }
}

private struct SessionInputReader {
    private enum InputMode {
        case replay([String])
        case line
        case rawTerminal
    }

    private enum InputError: Error, LocalizedError {
        case failedToReadCharacter
        case failedToEnableRawMode

        var errorDescription: String? {
            switch self {
            case .failedToReadCharacter:
                "Failed to read from stdin."
            case .failedToEnableRawMode:
                "Failed to configure stdin for immediate input."
            }
        }
    }

    private var mode: InputMode
    #if canImport(Darwin)
    private var originalTermios: termios?
    #endif
    private var commandBuffer: String?

    init(replayInputs: [String]?, disableImmediateInput: Bool) throws {
        if let replayInputs {
            self.mode = .replay(replayInputs)
            return
        }
        if disableImmediateInput {
            self.mode = .line
            return
        }
        #if canImport(Darwin)
        if isatty(STDIN_FILENO) == 1 {
            self.mode = .rawTerminal
            try self.enableRawMode()
            return
        }
        #endif
        self.mode = .line
    }

    mutating func readInput() -> String? {
        switch self.mode {
        case var .replay(inputs):
            guard !inputs.isEmpty else {
                self.mode = .replay(inputs)
                return nil
            }
            let input = inputs.removeFirst()
            self.mode = .replay(inputs)
            return input

        case .line:
            return readLine(strippingNewline: true)

        case .rawTerminal:
            return self.readRawTerminalInput()
        }
    }

    mutating func restoreTerminalIfNeeded() {
        #if canImport(Darwin)
        guard var originalTermios = self.originalTermios else {
            return
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        self.originalTermios = nil
        #endif
    }

    #if canImport(Darwin)
    private mutating func enableRawMode() throws {
        var termiosState = termios()
        guard tcgetattr(STDIN_FILENO, &termiosState) == 0 else {
            throw InputError.failedToEnableRawMode
        }
        self.originalTermios = termiosState

        termiosState.c_lflag &= ~tcflag_t(ICANON | ECHO)
        Self.withControlCharacters(&termiosState) { controlCharacters in
            controlCharacters[Int(VMIN)] = 1
            controlCharacters[Int(VTIME)] = 0
        }

        guard tcsetattr(STDIN_FILENO, TCSANOW, &termiosState) == 0 else {
            throw InputError.failedToEnableRawMode
        }
    }

    private static func withControlCharacters(
        _ termiosState: inout termios,
        _ body: (UnsafeMutableBufferPointer<cc_t>) -> Void
    ) {
        withUnsafeMutablePointer(to: &termiosState.c_cc) { pointer in
            let capacity = Int(NCCS)
            pointer.withMemoryRebound(to: cc_t.self, capacity: capacity) { controlCharacters in
                body(.init(start: controlCharacters, count: capacity))
            }
        }
    }
    #endif

    private mutating func readRawTerminalInput() -> String? {
        while let character = self.readCharacter() {
            switch character {
            case "\u{04}":
                return nil

            case "\u{1B}":
                if let command = self.readEscapeSequence() {
                    return command
                }
                continue

            case "\r", "\n":
                if let commandBuffer = self.commandBuffer {
                    self.commandBuffer = nil
                    print()
                    return commandBuffer
                }
                continue

            case "\u{7F}", "\u{08}":
                if var commandBuffer = self.commandBuffer {
                    if commandBuffer.count > 1 {
                        commandBuffer.removeLast()
                        self.commandBuffer = commandBuffer
                        fputs("\u{08} \u{08}", stdout)
                        fflush(stdout)
                        continue
                    }
                    self.commandBuffer = nil
                    fputs("\u{08} \u{08}", stdout)
                    fflush(stdout)
                    continue
                }
                return ":d"

            case ":":
                guard self.commandBuffer == nil else {
                    self.commandBuffer?.append(character)
                    fputs(String(character), stdout)
                    fflush(stdout)
                    continue
                }
                self.commandBuffer = String(character)
                fputs(String(character), stdout)
                fflush(stdout)

            default:
                if self.commandBuffer != nil {
                    self.commandBuffer?.append(character)
                    fputs(String(character), stdout)
                    fflush(stdout)
                    continue
                }
                return String(character)
            }
        }
        return nil
    }

    private mutating func readEscapeSequence() -> String? {
        guard self.commandBuffer == nil else {
            return nil
        }
        guard let first = self.readByte(), first == UInt8(ascii: "[") else {
            return nil
        }
        guard let second = self.readByte() else {
            return nil
        }
        switch second {
        case UInt8(ascii: "D"):
            return ":m -1"
        case UInt8(ascii: "C"):
            return ":m 1"
        default:
            return nil
        }
    }

    private mutating func readCharacter() -> Character? {
        guard let firstByte = self.readByte() else {
            return nil
        }
        let expectedLength = Self.expectedUTF8Length(firstByte)
        var bytes = [firstByte]
        if expectedLength > 1 {
            for _ in 1..<expectedLength {
                guard let nextByte = self.readByte() else {
                    return nil
                }
                bytes.append(nextByte)
            }
        }
        return String(decoding: bytes, as: UTF8.self).first
    }

    private mutating func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &byte) { buffer in
            Foundation.read(STDIN_FILENO, buffer.baseAddress, buffer.count)
        }
        switch count {
        case 1:
            return byte
        case 0:
            return nil
        default:
            return nil
        }
    }

    private static func expectedUTF8Length(_ firstByte: UInt8) -> Int {
        switch firstByte {
        case 0b0000_0000...0b0111_1111:
            return 1
        case 0b1100_0000...0b1101_1111:
            return 2
        case 0b1110_0000...0b1110_1111:
            return 3
        case 0b1111_0000...0b1111_0111:
            return 4
        default:
            return 1
        }
    }
}
