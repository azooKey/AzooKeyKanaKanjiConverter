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
        package var snapshot: SessionSnapshot
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
    private var configuration: SessionConfiguration
    private let debugPossibleNexts: Bool
    private let initialConfiguration: SessionConfiguration

    package var memoryDirectoryURL: URL {
        self.sessionConfig.requestOptions.memoryDirectoryURL
    }

    package private(set) var composingText = ComposingText()
    package private(set) var lastCandidates: [Candidate] = []
    package private(set) var lastMainCandidates: [Candidate] = []
    package private(set) var lastPredictionCandidates: [Candidate] = []
    package private(set) var lastFirstClauseCandidates: [Candidate] = []
    package private(set) var lastLiveConversionSnapshot: LiveConversionSnapshot?
    package private(set) var leftSideContext: String = ""
    package private(set) var page: Int = 0
    package private(set) var histories: [AncoSessionRequest] = []
    private var core: AncoSessionCore

    package init(
        converter: KanaKanjiConverter,
        requestOptions: ConvertRequestOptions,
        inputStyle: InputStyle = .direct,
        displayTopN: Int = 1,
        view: String = "main",
        preset: String? = nil,
        debugPossibleNexts: Bool = false,
        userDictionaryItems: [InputUserDictionaryItem] = []
    ) {
        self.converter = converter
        self.debugPossibleNexts = debugPossibleNexts
        let defaultConfig = SessionConfig(
            requestOptions: requestOptions,
            inputStyle: inputStyle,
            displayTopN: displayTopN,
            view: SessionView(rawValue: view) ?? .main,
            liveConversion: .init(enabled: true)
        )
        var configuration = SessionConfiguration(defaultConfig: defaultConfig)
        if let preset, !preset.isEmpty {
            _ = configuration.applyPreset(id: preset)
        }
        self.configuration = configuration
        self.initialConfiguration = configuration
        self.core = .init(
            converter: converter,
            configuration: .init(
                requestOptions: configuration.effectiveConfig.requestOptions,
                inputStyle: configuration.effectiveConfig.inputStyle,
                liveConversion: configuration.effectiveConfig.liveConversion
            )
        )

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

    package var sessionConfig: SessionConfig {
        get {
            self.configuration.effectiveConfig
        }
        set {
            self.configuration = SessionConfiguration(defaultConfig: newValue)
            self.syncCoreState()
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

    package mutating func execute(event: SessionEvent) throws -> ExecutionResult {
        try self.execute(Self.request(for: event))
    }

    package mutating func execute(_ submittedCommand: AncoSessionRequest) throws -> ExecutionResult {
        self.histories.append(submittedCommand)

        switch submittedCommand {
        case .quit:
            return self.makeResult(action: .quit, submittedCommand: submittedCommand, executedCommand: submittedCommand)

        case .deleteBackward:
            if !self.composingText.isEmpty {
                self.syncCoreState()
                _ = self.core.send(.deleteBackward(1))
                self.syncFromCore()
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
            let message = self.sessionConfig.requestOptions.learningType.needUpdateMemory
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
                inputStyle: self.sessionConfig.inputStyle,
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
                self.syncCoreState()
                _ = self.core.send(.deleteBackward(suffixCount))
                self.syncFromCore()
            }

            let inputStyle = self.sessionConfig.inputStyle
            let insertText = inputStyle == .roman2kana ? predictedText.toHiragana() : predictedText
            self.syncCoreState()
            _ = self.core.send(.insert(insertText, inputStyle: inputStyle))
            self.syncFromCore()
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
                self.syncCoreState()
                _ = self.core.send(.insertCompositionSeparator(inputStyle: self.sessionConfig.inputStyle))
                self.syncFromCore()
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
            self.syncCoreState()
            _ = self.core.selectCandidate(candidate)
            self.syncFromCore()
            return self.updateCandidates(
                submittedCommand: submittedCommand,
                executedCommand: submittedCommand,
                message: "Submit \(candidate.text)"
            )

        case let .input(rawInput):
            let input = Self.normalize(input: rawInput)
            self.syncCoreState()
            _ = self.core.send(.insert(input, inputStyle: self.sessionConfig.inputStyle))
            self.syncFromCore()
            return self.updateCandidates(
                submittedCommand: submittedCommand,
                executedCommand: .input(input)
            )
        }
    }

    package mutating func reset() {
        self.converter.stopComposition()
        self.core.reset()
        self.syncFromCore()
        self.page = 0
    }

    package func experimentalRequestTypoCorrection(
        config: ExperimentalTypoCorrectionConfig = .init()
    ) -> TypoCorrectionResult {
        let start = Date()
        let candidates = self.converter.experimentalRequestTypoCorrection(
            leftSideContext: self.leftSideContext,
            composingText: self.composingText,
            options: self.requestOptions(leftSideContext: self.leftSideContext),
            inputStyle: self.sessionConfig.inputStyle,
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
        self.syncCoreState()
        let wholeMatchInput: String?
        if self.sessionConfig.requestOptions.requestQuery == .完全一致, case let .input(input) = executedCommand {
            wholeMatchInput = input
        } else {
            wholeMatchInput = nil
        }
        let outputs = self.core.requestCandidates(filteredByWholeMatchInput: wholeMatchInput)
        self.syncFromCore()
        self.page = 0

        let entropy = self.sessionConfig.requestOptions.requestQuery == .完全一致
            ? Self.calculateEntropy(candidates: outputs.mainCandidates)
            : nil
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
        let startIndex = self.page * self.sessionConfig.displayTopN
        let endIndex = min(startIndex + self.sessionConfig.displayTopN, self.lastCandidates.count)
        let displayedCandidates = startIndex < endIndex ? Array(self.lastCandidates[startIndex..<endIndex]) : []
        return ExecutionResult(
            action: action,
            submittedCommand: submittedCommand,
            executedCommand: executedCommand,
            snapshot: self.snapshot(),
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

    package func snapshot() -> SessionSnapshot {
        let outputs = SessionOutputs(
            mainCandidates: self.lastMainCandidates,
            predictionCandidates: self.lastPredictionCandidates,
            liveConversion: self.lastLiveConversionSnapshot
        )
        let presentedContent: SessionPresentedContent
        switch self.sessionConfig.view {
        case .main, .prediction:
            presentedContent = .candidates(self.currentCandidates())
        case .liveConversion:
            if let snapshot = self.lastLiveConversionSnapshot {
                presentedContent = .liveConversion(snapshot)
            } else {
                presentedContent = .candidates([])
            }
        }
        return .init(
            composingText: self.composingText,
            leftSideContext: self.leftSideContext,
            config: self.sessionConfig,
            presetID: self.configuration.preset?.id,
            outputs: outputs,
            selectedView: self.sessionConfig.view,
            presentedContent: presentedContent
        )
    }

    private func currentCandidates() -> [Candidate] {
        switch self.sessionConfig.view {
        case .main:
            self.lastMainCandidates
        case .prediction:
            self.lastPredictionCandidates
        case .liveConversion:
            self.lastLiveConversionSnapshot?.currentCandidate.map { [$0] } ?? []
        }
    }

    private func requestOptions(leftSideContext: String?) -> ConvertRequestOptions {
        var options = self.sessionConfig.requestOptions
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
        case "preset":
            if value.isEmpty {
                self.configuration.clearPreset()
            } else if !self.configuration.applyPreset(id: value) {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.syncCoreState()
            self.refreshLiveConversionSnapshot()

        case "displayTopN":
            guard let parsed = Int(value), parsed > 0 else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(displayTopN: parsed))

        case "view":
            guard let parsed = SessionView(rawValue: value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(view: parsed))

        case "inputStyle":
            switch value {
            case "direct":
                self.configuration.applyRuntimePatch(.init(inputStyle: .direct))
            case "roman2kana":
                self.configuration.applyRuntimePatch(.init(inputStyle: .roman2kana))
            default:
                throw SessionError.invalidConfigValue(key: key, value: value)
            }

        case "onlyWholeConversion":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(onlyWholeConversion: parsed))

        case "predictionMode":
            guard let parsed = Self.parsePredictionMode(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(predictionMode: parsed))

        case "zenzai.profile":
            self.configuration.applyRuntimePatch(.init(zenzaiProfile: .set(value.isEmpty ? nil : value)))

        case "zenzai.topic":
            switch self.sessionConfig.requestOptions.zenzaiMode.versionDependentMode {
            case .v2:
                throw SessionError.invalidConfigValue(key: key, value: value)
            case .v3:
                self.configuration.applyRuntimePatch(.init(zenzaiTopic: .set(value.isEmpty ? nil : value)))
            }

        case "zenzai.inferenceLimit":
            guard let parsed = Int(value), parsed > 0 else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(zenzaiInferenceLimit: parsed))

        case "zenzai.requestRichCandidates":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(zenzaiRequestRichCandidates: parsed))

        case "zenzai.experimentalPredictiveInput":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(experimentalZenzaiPredictiveInput: parsed))

        case "liveConversion.enabled":
            guard let parsed = Self.parseBool(value) else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.configuration.applyRuntimePatch(.init(liveConversionEnabled: parsed))
            self.syncCoreState()
            self.refreshLiveConversionSnapshot()

        case "liveConversion.autoCommitThreshold":
            if value.isEmpty {
                self.configuration.applyRuntimePatch(.init(liveConversionAutoCommitThreshold: .set(nil)))
            } else if let parsed = Int(value), parsed > 0 {
                self.configuration.applyRuntimePatch(.init(liveConversionAutoCommitThreshold: .set(parsed)))
            } else {
                throw SessionError.invalidConfigValue(key: key, value: value)
            }
            self.syncCoreState()
            self.refreshLiveConversionSnapshot()

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
        var commands: [AncoSessionRequest] = []
        if let presetID = self.initialConfiguration.preset?.id {
            commands.append(.setConfig(key: "preset", value: presetID))
        }
        commands.append(contentsOf: Self.configCommands(config: self.initialConfiguration.effectiveConfig))
        return commands
    }

    private static func configCommands(
        config: SessionConfig
    ) -> [AncoSessionRequest] {
        let inputStyleValue: String
        switch config.inputStyle {
        case .direct:
            inputStyleValue = "direct"
        case .roman2kana:
            inputStyleValue = "roman2kana"
        default:
            inputStyleValue = "direct"
        }

        var commands: [AncoSessionRequest] = [
            .setConfig(key: "displayTopN", value: String(config.displayTopN)),
            .setConfig(key: "view", value: config.view.rawValue),
            .setConfig(key: "inputStyle", value: inputStyleValue),
            .setConfig(
                key: "onlyWholeConversion",
                value: config.requestOptions.requestQuery == .完全一致 ? "true" : "false"
            ),
            .setConfig(
                key: "predictionMode",
                value: Self.predictionModeValue(config.requestOptions.requireJapanesePrediction)
            ),
            .setConfig(
                key: "zenzai.inferenceLimit",
                value: String(config.requestOptions.zenzaiMode.inferenceLimit)
            ),
            .setConfig(
                key: "zenzai.requestRichCandidates",
                value: config.requestOptions.zenzaiMode.requestRichCandidates ? "true" : "false"
            ),
            .setConfig(
                key: "zenzai.experimentalPredictiveInput",
                value: config.requestOptions.experimentalZenzaiPredictiveInput ? "true" : "false"
            ),
            .setConfig(
                key: "liveConversion.enabled",
                value: config.liveConversion.enabled ? "true" : "false"
            )
        ]
        if let threshold = config.liveConversion.autoCommitThreshold {
            commands.append(.setConfig(key: "liveConversion.autoCommitThreshold", value: String(threshold)))
        }

        switch config.requestOptions.zenzaiMode.versionDependentMode {
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

    private static func request(for event: SessionEvent) -> AncoSessionRequest {
        switch event {
        case .quit:
            .quit
        case .deleteBackward:
            .deleteBackward
        case .clearComposition:
            .clearComposition
        case .nextPage:
            .nextPage
        case .save:
            .save
        case let .predictInput(count, maxEntropy, minLength):
            .predictInput(count: count, maxEntropy: maxEntropy, minLength: minLength)
        case .help:
            .help
        case let .typoCorrection(request):
            .typoCorrection(.init(
                rawCommand: request.rawCommand,
                nBest: request.nBest,
                beamSize: request.beamSize,
                topK: request.topK,
                maxSteps: request.maxSteps,
                alpha: request.alpha,
                beta: request.beta,
                gamma: request.gamma
            ))
        case let .updateConfig(key, value):
            .setConfig(key: key, value: value)
        case let .setLeftContext(context):
            .setContext(context)
        case let .specialInput(specialInput):
            .specialInput(.init(rawValue: specialInput.rawValue)!)
        case let .dumpHistory(path):
            .dumpHistory(path)
        case let .selectCandidate(index):
            .selectCandidate(index)
        case let .insert(text):
            .input(text)
        }
    }

    private mutating func refreshLiveConversionSnapshot() {
        self.syncCoreState()
        let conversionResult = ConversionResult(
            mainResults: self.lastMainCandidates,
            predictionResults: self.lastPredictionCandidates,
            englishPredictionResults: [],
            firstClauseResults: self.lastFirstClauseCandidates
        )
        _ = self.core.projectOutputs(conversionResult: conversionResult)
        self.syncFromCore()
    }

    private var coreConfiguration: AncoSessionCore.Configuration {
        .init(
            requestOptions: self.sessionConfig.requestOptions,
            inputStyle: self.sessionConfig.inputStyle,
            liveConversion: self.sessionConfig.liveConversion
        )
    }

    private mutating func syncCoreState() {
        self.core.apply(
            composingText: self.composingText,
            leftSideContext: self.leftSideContext,
            configuration: self.coreConfiguration
        )
    }

    private mutating func syncFromCore() {
        let snapshot = self.core.snapshot
        self.composingText = snapshot.composingText
        self.leftSideContext = snapshot.leftSideContext
        self.lastMainCandidates = snapshot.outputs.mainCandidates
        self.lastPredictionCandidates = snapshot.outputs.predictionCandidates
        self.lastFirstClauseCandidates = snapshot.outputs.firstClauseCandidates
        self.lastLiveConversionSnapshot = snapshot.outputs.liveConversionSnapshot
        self.lastCandidates = self.currentCandidates()
    }
}
