package import Foundation
import SwiftUtils

package struct AncoSession {
    package struct InputUserDictionaryItem: Codable, Sendable, Equatable {
        package var word: String
        package var reading: String
        package var hint: String?
    }

    package enum Action: Sendable, Equatable {
        case candidatesUpdated
        case pageUpdated
        case stateCleared
        case saved
        case helpRequested
        case configUpdated
        case quit
        case noAction
    }

    package struct ExecutionResult: Sendable {
        package var action: Action
        package var submittedCommand: AncoSessionRequest
        package var executedCommand: AncoSessionRequest
        package var composingText: ComposingText
        package var leftSideContext: String
        package var candidates: [Candidate]
        package var displayedCandidates: [Candidate]
        package var displayedCandidateStartIndex: Int
        package var page: Int
        package var histories: [AncoSessionRequest]
        package var message: String?
        package var elapsedTime: TimeInterval?
        package var predictiveInputTime: TimeInterval?
        package var entropy: Double?
    }

    package struct TypoCorrectionResult: Sendable {
        package var candidates: [ZenzaiTypoCandidate]
        package var elapsedTime: TimeInterval
    }

    private enum CandidateView: String, Sendable {
        case main
        case prediction
        case liveConversion
    }

    package enum SessionError: Error, LocalizedError {
        case invalidCandidateIndex(Int)
        case invalidConfigKey(String)
        case invalidConfigValue(key: String, value: String)
        case historyDumpFailed(URL, any Error)
        case userDictionaryFileReadFailed(URL, any Error)
        case userDictionaryDecodeFailed(URL, any Error)

        package var errorDescription: String? {
            switch self {
            case let .invalidCandidateIndex(index):
                "Candidate index \(index) is not available for the current context."
            case let .invalidConfigKey(key):
                "Unknown config key: \(key)"
            case let .invalidConfigValue(key, value):
                "Invalid config value for \(key): \(value)"
            case let .historyDumpFailed(url, error):
                "Failed to dump command history to \(url.path): \(error.localizedDescription)"
            case let .userDictionaryFileReadFailed(url, error):
                "Failed to read user dictionary file at \(url.path): \(error.localizedDescription)"
            case let .userDictionaryDecodeFailed(url, error):
                "Failed to decode user dictionary file at \(url.path): \(error.localizedDescription)"
            }
        }
    }

    private let converter: KanaKanjiConverter
    private var requestOptionsState: ConvertRequestOptions
    private var inputStyle: InputStyle
    private var displayTopN: Int
    private var view: CandidateView
    private let debugPossibleNexts: Bool
    private let initialRequestOptionsState: ConvertRequestOptions
    private let initialInputStyle: InputStyle
    private let initialDisplayTopN: Int
    private let initialView: CandidateView

    package var memoryDirectoryURL: URL {
        self.requestOptionsState.memoryDirectoryURL
    }

    package private(set) var composingText = ComposingText()
    package private(set) var lastCandidates: [Candidate] = []
    package private(set) var lastMainCandidates: [Candidate] = []
    package private(set) var lastPredictionCandidates: [Candidate] = []
    package private(set) var lastLiveConversionSnapshot: LiveConversionSnapshot?
    package private(set) var leftSideContext: String = ""
    package private(set) var page: Int = 0
    package private(set) var histories: [AncoSessionRequest] = []
    private var liveConversionState = LiveConversionState(config: .init(enabled: true))

    package init(
        converter: KanaKanjiConverter,
        requestOptions: ConvertRequestOptions,
        inputStyle: InputStyle = .direct,
        displayTopN: Int = 1,
        view: String = "main",
        debugPossibleNexts: Bool = false,
        userDictionaryItems: [InputUserDictionaryItem] = []
    ) {
        self.view = CandidateView(rawValue: view) ?? .main
        self.converter = converter
        self.requestOptionsState = requestOptions
        self.inputStyle = inputStyle
        self.displayTopN = displayTopN
        self.debugPossibleNexts = debugPossibleNexts
        self.initialRequestOptionsState = requestOptions
        self.initialInputStyle = inputStyle
        self.initialDisplayTopN = displayTopN
        self.initialView = self.view

        if !userDictionaryItems.isEmpty {
            let userDictionary = userDictionaryItems.map {
                DicdataElement(
                    word: $0.word,
                    ruby: $0.reading.toKatakana(),
                    cid: CIDData.固有名詞.cid,
                    mid: MIDData.一般.mid,
                    value: -10
                )
            }
            self.converter.importDynamicUserDictionary(userDictionary)
        }
    }

    package static func parseUserDictionaryItems(from url: URL?) throws -> [InputUserDictionaryItem] {
        guard let url else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionError.userDictionaryFileReadFailed(url, error)
        }
        do {
            return try JSONDecoder().decode([InputUserDictionaryItem].self, from: data)
        } catch {
            throw SessionError.userDictionaryDecodeFailed(url, error)
        }
    }

    package mutating func recordHistory(_ command: AncoSessionRequest) {
        self.histories.append(command)
    }

    package mutating func execute(_ submittedCommand: AncoSessionRequest) throws -> ExecutionResult {
        self.histories.append(submittedCommand)

        switch submittedCommand {
        case .quit:
            return self.makeResult(action: .quit, submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case .deleteBackward:
            if !self.composingText.isEmpty {
                self.composingText.deleteBackwardFromCursorPosition(count: 1)
            } else {
                _ = self.leftSideContext.popLast()
                return self.makeResult(action: .noAction, submittedCommand: submittedCommand, executedCommand: submittedCommand)
            }
            return self.updateCandidates(submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case .clearComposition:
            self.reset()
            return self.makeResult(
                action: .stateCleared,
                submittedCommand: submittedCommand,
                executedCommand: submittedCommand,
                message: "composition is stopped"
            )

        case .nextPage:
            self.page += 1
            return self.makeResult(action: .pageUpdated, submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case .save:
            self.composingText.stopComposition()
            self.converter.stopComposition()
            self.converter.commitUpdateLearningData()
            let message = self.requestOptionsState.learningType.needUpdateMemory
                ? "saved"
                : "anything should not be saved because the learning type is not for update memory"
            return self.makeResult(action: .saved, submittedCommand: submittedCommand, executedCommand: submittedCommand, message: message)

        case let .predictInput(requestedCount, maxEntropy, minLength):
            let predictCount = max(1, min(requestedCount, 50))
            let predictMinLength = max(1, min(minLength, predictCount))
            let ipStart = Date()
            let (predictedText, suffixCount) = self.converter.predictNextInputText(
                leftSideContext: self.leftSideContext,
                composingText: self.composingText,
                count: predictCount,
                minLength: predictMinLength,
                maxEntropy: maxEntropy,
                options: self.requestOptions(leftSideContext: self.leftSideContext),
                inputStyle: self.inputStyle,
                debugPossibleNexts: self.debugPossibleNexts
            )
            let predictiveInputTime = -ipStart.timeIntervalSinceNow
            guard !predictedText.isEmpty else {
                return self.makeResult(
                    action: .noAction,
                    submittedCommand: submittedCommand,
                    executedCommand: submittedCommand,
                    predictiveInputTime: predictiveInputTime
                )
            }

            if suffixCount > 0 {
                self.composingText.deleteBackwardFromCursorPosition(count: suffixCount)
            }

            let insertText = self.inputStyle == .roman2kana ? predictedText.toHiragana() : predictedText
            self.composingText.insertAtCursorPosition(insertText, inputStyle: self.inputStyle)
            let executedCommand = AncoSessionRequest.input(insertText)

            return self.updateCandidates(
                submittedCommand: submittedCommand,
                executedCommand: executedCommand,
                predictiveInputTime: predictiveInputTime
            )

        case .help:
            return self.makeResult(
                action: .helpRequested,
                submittedCommand: submittedCommand,
                executedCommand: submittedCommand,
                message: AncoSessionRequest.helpText
            )

        case .typoCorrection:
            return self.makeResult(action: .noAction, submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case let .setConfig(key, value):
            try self.updateConfig(key: key, value: value)
            self.page = 0
            if key == "view" {
                self.lastCandidates = self.currentCandidates()
            }
            return self.makeResult(
                action: .configUpdated,
                submittedCommand: submittedCommand,
                executedCommand: submittedCommand,
                message: "\(key)=\(value)"
            )

        case let .setContext(context):
            self.leftSideContext.append(context)
            return self.makeResult(action: .noAction, submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case let .specialInput(specialInput):
            switch specialInput {
            case .endOfText:
                self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: self.inputStyle)])
            }
            return self.updateCandidates(submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case let .dumpHistory(filePath):
            let fileName = filePath ?? "history.txt"
            let content = (self.initialConfigCommands() + self.replayableHistories()).map(\.encodedCommand).joined(separator: "\n")
            let url = URL(fileURLWithPath: fileName)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw SessionError.historyDumpFailed(url, error)
            }
            return self.makeResult(action: .noAction, submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case let .selectCandidate(index):
            guard self.lastCandidates.indices.contains(index) else {
                throw SessionError.invalidCandidateIndex(index)
            }
            let candidate = self.lastCandidates[index]
            self.converter.setCompletedData(candidate)
            self.converter.updateLearningData(candidate)
            self.composingText.prefixComplete(composingCount: candidate.composingCount)
            if self.composingText.isEmpty {
                self.composingText.stopComposition()
                self.converter.stopComposition()
                self.liveConversionState.stopComposition()
            } else {
                self.liveConversionState.updateAfterFirstClauseCompletion()
            }
            self.leftSideContext += candidate.text
            return self.updateCandidates(
                submittedCommand: submittedCommand,
                executedCommand: submittedCommand,
                message: "Submit \(candidate.text)"
            )

        case let .input(rawInput):
            let input = Self.normalize(input: rawInput)
            self.composingText.insertAtCursorPosition(input, inputStyle: self.inputStyle)
            return self.updateCandidates(
                submittedCommand: submittedCommand,
                executedCommand: .input(input)
            )
        }
    }

    package mutating func reset() {
        self.composingText.stopComposition()
        self.converter.stopComposition()
        self.lastCandidates = []
        self.lastMainCandidates = []
        self.lastPredictionCandidates = []
        self.lastLiveConversionSnapshot = nil
        self.leftSideContext = ""
        self.page = 0
        self.liveConversionState.stopComposition()
    }

    package func experimentalRequestTypoCorrection(
        config: ExperimentalTypoCorrectionConfig = .init()
    ) -> TypoCorrectionResult {
        let start = Date()
        let candidates = self.converter.experimentalRequestTypoCorrection(
            leftSideContext: self.leftSideContext,
            composingText: self.composingText,
            options: self.requestOptions(leftSideContext: self.leftSideContext),
            inputStyle: self.inputStyle,
            config: config
        )
        return .init(candidates: candidates, elapsedTime: -start.timeIntervalSinceNow)
    }

    private mutating func updateCandidates(
        submittedCommand: AncoSessionRequest,
        executedCommand: AncoSessionRequest,
        message: String? = nil,
        predictiveInputTime: TimeInterval? = nil
    ) -> ExecutionResult {
        let start = Date()
        let result = self.converter.requestCandidates(
            self.composingText,
            options: self.requestOptions(leftSideContext: self.leftSideContext)
        )
        let mainResults = result.mainResults.filter {
            if self.requestOptionsState.requestQuery != .完全一致 {
                return true
            }
            guard case let .input(input) = executedCommand else {
                return false
            }
            return $0.data.reduce(into: "", {$0.append(contentsOf: $1.ruby)}) == input.toKatakana()
        }
        self.lastMainCandidates = mainResults
        self.lastPredictionCandidates = result.predictionResults
        self.lastLiveConversionSnapshot = self.liveConversionState.update(
            self.composingText,
            candidates: mainResults,
            firstClauseResults: result.firstClauseResults,
            convertTargetCursorPosition: self.composingText.convertTargetCursorPosition,
            convertTarget: self.composingText.convertTarget
        )
        self.lastCandidates = self.currentCandidates()
        self.page = 0

        let entropy = self.requestOptionsState.requestQuery == .完全一致 ? Self.calculateEntropy(candidates: mainResults) : nil
        return self.makeResult(
            action: .candidatesUpdated,
            submittedCommand: submittedCommand,
            executedCommand: executedCommand,
            message: message,
            elapsedTime: -start.timeIntervalSinceNow,
            predictiveInputTime: predictiveInputTime,
            entropy: entropy
        )
    }

    private func makeResult(
        action: Action,
        submittedCommand: AncoSessionRequest,
        executedCommand: AncoSessionRequest,
        message: String? = nil,
        elapsedTime: TimeInterval? = nil,
        predictiveInputTime: TimeInterval? = nil,
        entropy: Double? = nil
    ) -> ExecutionResult {
        let startIndex = self.page * self.displayTopN
        let endIndex = min(startIndex + self.displayTopN, self.lastCandidates.count)
        let displayedCandidates = startIndex < endIndex ? Array(self.lastCandidates[startIndex..<endIndex]) : []
        return ExecutionResult(
            action: action,
            submittedCommand: submittedCommand,
            executedCommand: executedCommand,
            composingText: self.composingText,
            leftSideContext: self.leftSideContext,
            candidates: self.lastCandidates,
            displayedCandidates: displayedCandidates,
            displayedCandidateStartIndex: startIndex,
            page: self.page,
            histories: self.histories,
            message: message,
            elapsedTime: elapsedTime,
            predictiveInputTime: predictiveInputTime,
            entropy: entropy
        )
    }

    private func currentCandidates() -> [Candidate] {
        switch self.view {
        case .main:
            self.lastMainCandidates
        case .prediction:
            self.lastPredictionCandidates
        case .liveConversion:
            self.lastLiveConversionSnapshot?.currentCandidate.map { [$0] } ?? []
        }
    }

    private func requestOptions(leftSideContext: String?) -> ConvertRequestOptions {
        var options = self.requestOptionsState
        switch options.zenzaiMode.versionDependentMode {
        case let .v2(mode):
            options.zenzaiMode.versionDependentMode = .v2(.init(
                profile: mode.profile,
                leftSideContext: leftSideContext,
                maxLeftSideContextLength: mode.maxLeftSideContextLength
            ))
        case let .v3(mode):
            options.zenzaiMode.versionDependentMode = .v3(.init(
                profile: mode.profile,
                topic: mode.topic,
                style: mode.style,
                preference: mode.preference,
                leftSideContext: leftSideContext,
                maxLeftSideContextLength: mode.maxLeftSideContextLength
            ))
        }
        return options
    }

    private mutating func updateConfig(key: String, value: String) throws {
        switch key {
        case "displayTopN":
            guard let parsed = Int(value), parsed > 0 else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.displayTopN = parsed

        case "view":
            guard let parsed = CandidateView(rawValue: value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.view = parsed

        case "inputStyle":
            switch value {
            case "direct":
                self.inputStyle = .direct
            case "roman2kana":
                self.inputStyle = .roman2kana
            default:
                throw SessionError.invalidConfigValue(key: key, value: value)
            }

        case "onlyWholeConversion":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.requestOptionsState.requestQuery = parsed ? .完全一致 : .default

        case "predictionMode":
            guard let parsed = Self.parsePredictionMode(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.requestOptionsState.requireJapanesePrediction = parsed

        case "zenzai.profile":
            switch self.requestOptionsState.zenzaiMode.versionDependentMode {
            case let .v2(mode):
                self.requestOptionsState.zenzaiMode.versionDependentMode = .v2(.init(
                    profile: value.isEmpty ? nil : value,
                    leftSideContext: mode.leftSideContext,
                    maxLeftSideContextLength: mode.maxLeftSideContextLength
                ))
            case let .v3(mode):
                self.requestOptionsState.zenzaiMode.versionDependentMode = .v3(.init(
                    profile: value.isEmpty ? nil : value,
                    topic: mode.topic,
                    style: mode.style,
                    preference: mode.preference,
                    leftSideContext: mode.leftSideContext,
                    maxLeftSideContextLength: mode.maxLeftSideContextLength
                ))
            }

        case "zenzai.topic":
            switch self.requestOptionsState.zenzaiMode.versionDependentMode {
            case .v2:
                throw SessionError.invalidConfigValue(key: key, value: value)
            case let .v3(mode):
                self.requestOptionsState.zenzaiMode.versionDependentMode = .v3(.init(
                    profile: mode.profile,
                    topic: value.isEmpty ? nil : value,
                    style: mode.style,
                    preference: mode.preference,
                    leftSideContext: mode.leftSideContext,
                    maxLeftSideContextLength: mode.maxLeftSideContextLength
                ))
            }

        case "zenzai.inferenceLimit":
            guard let parsed = Int(value), parsed > 0 else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.requestOptionsState.zenzaiMode.inferenceLimit = parsed

        case "zenzai.requestRichCandidates":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.requestOptionsState.zenzaiMode.requestRichCandidates = parsed

        case "zenzai.experimentalPredictiveInput":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.requestOptionsState.experimentalZenzaiPredictiveInput = parsed

        default:
            throw SessionError.invalidConfigKey(key)
        }
    }

    private func replayableHistories() -> [AncoSessionRequest] {
        self.histories.filter { command in
            switch command {
            case .dumpHistory:
                return false
            default:
                return true
            }
        }
    }

    private func initialConfigCommands() -> [AncoSessionRequest] {
        Self.configCommands(
            requestOptions: self.initialRequestOptionsState,
            inputStyle: self.initialInputStyle,
            displayTopN: self.initialDisplayTopN,
            view: self.initialView
        )
    }

    private static func configCommands(
        requestOptions: ConvertRequestOptions,
        inputStyle: InputStyle,
        displayTopN: Int,
        view: CandidateView
    ) -> [AncoSessionRequest] {
        let inputStyleValue: String
        switch inputStyle {
        case .direct:
            inputStyleValue = "direct"
        case .roman2kana:
            inputStyleValue = "roman2kana"
        default:
            inputStyleValue = "direct"
        }

        var commands: [AncoSessionRequest] = [
            .setConfig(key: "displayTopN", value: String(displayTopN)),
            .setConfig(key: "view", value: view.rawValue),
            .setConfig(key: "inputStyle", value: inputStyleValue),
            .setConfig(
                key: "onlyWholeConversion",
                value: requestOptions.requestQuery == .完全一致 ? "true" : "false"
            ),
            .setConfig(
                key: "predictionMode",
                value: Self.predictionModeValue(requestOptions.requireJapanesePrediction)
            ),
            .setConfig(
                key: "zenzai.inferenceLimit",
                value: String(requestOptions.zenzaiMode.inferenceLimit)
            ),
            .setConfig(
                key: "zenzai.requestRichCandidates",
                value: requestOptions.zenzaiMode.requestRichCandidates ? "true" : "false"
            ),
            .setConfig(
                key: "zenzai.experimentalPredictiveInput",
                value: requestOptions.experimentalZenzaiPredictiveInput ? "true" : "false"
            )
        ]

        switch requestOptions.zenzaiMode.versionDependentMode {
        case let .v2(mode):
            commands.append(.setConfig(key: "zenzai.profile", value: mode.profile ?? ""))
        case let .v3(mode):
            commands.append(.setConfig(key: "zenzai.profile", value: mode.profile ?? ""))
            commands.append(.setConfig(key: "zenzai.topic", value: mode.topic ?? ""))
        }

        return commands
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes", "on":
            true
        case "false", "0", "no", "off":
            false
        default:
            nil
        }
    }

    private static func parsePredictionMode(_ value: String) -> ConvertRequestOptions.PredictionMode? {
        switch value.lowercased() {
        case "automix":
            .autoMix
        case "manualmix":
            .manualMix
        case "disabled":
            .disabled
        default:
            nil
        }
    }

    private static func predictionModeValue(_ mode: ConvertRequestOptions.PredictionMode) -> String {
        switch mode {
        case .autoMix:
            "automix"
        case .manualMix:
            "manualmix"
        case .disabled:
            "disabled"
        }
    }

    private static func normalize(input: String) -> String {
        String(input.map { character in
            switch character {
            case "-": "ー"
            case ".": "。"
            case ",": "、"
            default: character
            }
        })
    }

    private static func calculateEntropy(candidates: [Candidate]) -> Double? {
        guard !candidates.isEmpty else {
            return nil
        }
        let mean = candidates.reduce(into: 0.0) { $0 += Double($1.value) } / Double(candidates.count)
        let expValues = candidates.map { exp(Double($0.value) - mean) }
        let sumOfExpValues = expValues.reduce(into: 0.0, +=)
        guard sumOfExpValues > 0 else {
            return nil
        }
        let probabilities = expValues.map { $0 / sumOfExpValues }
        return -probabilities.reduce(into: 0.0) { result, probability in
            result += probability * log(probability)
        }
    }
}
