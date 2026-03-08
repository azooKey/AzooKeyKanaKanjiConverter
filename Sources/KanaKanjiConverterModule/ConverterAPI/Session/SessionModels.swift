package enum SessionView: String, Sendable, Codable, Equatable {
    case main
    case prediction
    case liveConversion
}

package enum SessionOverride<Value: Sendable>: Sendable {
    case keepCurrent
    case set(Value)
}

extension SessionOverride: Equatable where Value: Equatable {}

package struct SessionConfig: Sendable {
    package var requestOptions: ConvertRequestOptions
    package var inputStyle: InputStyle
    package var displayTopN: Int
    package var view: SessionView
    package var liveConversion: LiveConversionConfig

    package init(
        requestOptions: ConvertRequestOptions,
        inputStyle: InputStyle,
        displayTopN: Int,
        view: SessionView,
        liveConversion: LiveConversionConfig
    ) {
        self.requestOptions = requestOptions
        self.inputStyle = inputStyle
        self.displayTopN = displayTopN
        self.view = view
        self.liveConversion = liveConversion
    }

    package func applying(_ patch: SessionConfigPatch) -> SessionConfig {
        var config = self
        if let inputStyle = patch.inputStyle {
            config.inputStyle = inputStyle
        }
        if let displayTopN = patch.displayTopN {
            config.displayTopN = displayTopN
        }
        if let view = patch.view {
            config.view = view
        }
        if let enabled = patch.onlyWholeConversion {
            config.requestOptions.requestQuery = enabled ? .完全一致 : .default
        }
        if let predictionMode = patch.predictionMode {
            config.requestOptions.requireJapanesePrediction = predictionMode
        }
        switch patch.zenzaiProfile {
        case .keepCurrent:
            break
        case let .set(profile):
            switch config.requestOptions.zenzaiMode.versionDependentMode {
            case let .v2(mode):
                config.requestOptions.zenzaiMode.versionDependentMode = .v2(.init(
                    profile: profile,
                    leftSideContext: mode.leftSideContext,
                    maxLeftSideContextLength: mode.maxLeftSideContextLength
                ))
            case let .v3(mode):
                config.requestOptions.zenzaiMode.versionDependentMode = .v3(.init(
                    profile: profile,
                    topic: mode.topic,
                    style: mode.style,
                    preference: mode.preference,
                    leftSideContext: mode.leftSideContext,
                    maxLeftSideContextLength: mode.maxLeftSideContextLength
                ))
            }
        }
        switch patch.zenzaiTopic {
        case .keepCurrent:
            break
        case let .set(topic):
            switch config.requestOptions.zenzaiMode.versionDependentMode {
            case .v2:
                break
            case let .v3(mode):
                config.requestOptions.zenzaiMode.versionDependentMode = .v3(.init(
                    profile: mode.profile,
                    topic: topic,
                    style: mode.style,
                    preference: mode.preference,
                    leftSideContext: mode.leftSideContext,
                    maxLeftSideContextLength: mode.maxLeftSideContextLength
                ))
            }
        }
        if let inferenceLimit = patch.zenzaiInferenceLimit {
            config.requestOptions.zenzaiMode.inferenceLimit = inferenceLimit
        }
        if let requestRichCandidates = patch.zenzaiRequestRichCandidates {
            config.requestOptions.zenzaiMode.requestRichCandidates = requestRichCandidates
        }
        if let experimentalPredictiveInput = patch.experimentalZenzaiPredictiveInput {
            config.requestOptions.experimentalZenzaiPredictiveInput = experimentalPredictiveInput
        }
        if let enabled = patch.liveConversionEnabled {
            config.liveConversion.enabled = enabled
        }
        switch patch.liveConversionAutoCommitThreshold {
        case .keepCurrent:
            break
        case let .set(threshold):
            config.liveConversion.autoCommitThreshold = threshold
        }
        return config
    }
}

package struct SessionConfigPatch: Sendable, Equatable {
    package var inputStyle: InputStyle?
    package var displayTopN: Int?
    package var view: SessionView?
    package var onlyWholeConversion: Bool?
    package var predictionMode: ConvertRequestOptions.PredictionMode?
    package var zenzaiProfile: SessionOverride<String?> = .keepCurrent
    package var zenzaiTopic: SessionOverride<String?> = .keepCurrent
    package var zenzaiInferenceLimit: Int?
    package var zenzaiRequestRichCandidates: Bool?
    package var experimentalZenzaiPredictiveInput: Bool?
    package var liveConversionEnabled: Bool?
    package var liveConversionAutoCommitThreshold: SessionOverride<Int?> = .keepCurrent

    package init(
        inputStyle: InputStyle? = nil,
        displayTopN: Int? = nil,
        view: SessionView? = nil,
        onlyWholeConversion: Bool? = nil,
        predictionMode: ConvertRequestOptions.PredictionMode? = nil,
        zenzaiProfile: SessionOverride<String?> = .keepCurrent,
        zenzaiTopic: SessionOverride<String?> = .keepCurrent,
        zenzaiInferenceLimit: Int? = nil,
        zenzaiRequestRichCandidates: Bool? = nil,
        experimentalZenzaiPredictiveInput: Bool? = nil,
        liveConversionEnabled: Bool? = nil,
        liveConversionAutoCommitThreshold: SessionOverride<Int?> = .keepCurrent
    ) {
        self.inputStyle = inputStyle
        self.displayTopN = displayTopN
        self.view = view
        self.onlyWholeConversion = onlyWholeConversion
        self.predictionMode = predictionMode
        self.zenzaiProfile = zenzaiProfile
        self.zenzaiTopic = zenzaiTopic
        self.zenzaiInferenceLimit = zenzaiInferenceLimit
        self.zenzaiRequestRichCandidates = zenzaiRequestRichCandidates
        self.experimentalZenzaiPredictiveInput = experimentalZenzaiPredictiveInput
        self.liveConversionEnabled = liveConversionEnabled
        self.liveConversionAutoCommitThreshold = liveConversionAutoCommitThreshold
    }
}

package struct SessionConfigPreset: Sendable, Equatable {
    package var id: String
    package var patch: SessionConfigPatch

    package init(id: String, patch: SessionConfigPatch) {
        self.id = id
        self.patch = patch
    }

    package static let builtinPresets: [SessionConfigPreset] = [
        .init(
            id: "cli-debug",
            patch: .init(
                displayTopN: 5,
                view: .main,
                liveConversionEnabled: true
            )
        ),
        .init(
            id: "ios-default",
            patch: .init(
                displayTopN: 1,
                view: .liveConversion,
                liveConversionEnabled: true
            )
        ),
        .init(
            id: "macos-default",
            patch: .init(
                displayTopN: 9,
                view: .main,
                liveConversionEnabled: true
            )
        )
    ]

    package static func builtin(id: String) -> SessionConfigPreset? {
        self.builtinPresets.first { $0.id == id }
    }
}

package struct SessionConfiguration: Sendable {
    package var defaultConfig: SessionConfig
    package var preset: SessionConfigPreset?
    package var userOverrides: SessionConfigPatch
    package var runtimeOverrides: SessionConfigPatch

    package init(
        defaultConfig: SessionConfig,
        preset: SessionConfigPreset? = nil,
        userOverrides: SessionConfigPatch = .init(),
        runtimeOverrides: SessionConfigPatch = .init()
    ) {
        self.defaultConfig = defaultConfig
        self.preset = preset
        self.userOverrides = userOverrides
        self.runtimeOverrides = runtimeOverrides
    }

    package var effectiveConfig: SessionConfig {
        var config = self.defaultConfig
        if let preset = self.preset {
            config = config.applying(preset.patch)
        }
        config = config.applying(self.userOverrides)
        config = config.applying(self.runtimeOverrides)
        return config
    }

    package mutating func applyPreset(id: String) -> Bool {
        guard let preset = SessionConfigPreset.builtin(id: id) else {
            return false
        }
        self.preset = preset
        return true
    }

    package mutating func clearPreset() {
        self.preset = nil
    }

    package mutating func applyRuntimePatch(_ patch: SessionConfigPatch) {
        self.runtimeOverrides = self.runtimeOverrides.merging(patch)
    }
}

extension SessionConfigPatch {
    package func merging(_ other: SessionConfigPatch) -> SessionConfigPatch {
        .init(
            inputStyle: other.inputStyle ?? self.inputStyle,
            displayTopN: other.displayTopN ?? self.displayTopN,
            view: other.view ?? self.view,
            onlyWholeConversion: other.onlyWholeConversion ?? self.onlyWholeConversion,
            predictionMode: other.predictionMode ?? self.predictionMode,
            zenzaiProfile: Self.merge(self.zenzaiProfile, other.zenzaiProfile),
            zenzaiTopic: Self.merge(self.zenzaiTopic, other.zenzaiTopic),
            zenzaiInferenceLimit: other.zenzaiInferenceLimit ?? self.zenzaiInferenceLimit,
            zenzaiRequestRichCandidates: other.zenzaiRequestRichCandidates ?? self.zenzaiRequestRichCandidates,
            experimentalZenzaiPredictiveInput: other.experimentalZenzaiPredictiveInput ?? self.experimentalZenzaiPredictiveInput,
            liveConversionEnabled: other.liveConversionEnabled ?? self.liveConversionEnabled,
            liveConversionAutoCommitThreshold: Self.merge(
                self.liveConversionAutoCommitThreshold,
                other.liveConversionAutoCommitThreshold
            )
        )
    }

    private static func merge<Value: Sendable>(
        _ lhs: SessionOverride<Value>,
        _ rhs: SessionOverride<Value>
    ) -> SessionOverride<Value> {
        switch rhs {
        case .keepCurrent:
            lhs
        case .set:
            rhs
        }
    }
}

package enum SessionSpecialInput: String, Sendable, Equatable {
    case endOfText = "eot"

    package init?(decoding command: String) {
        self.init(rawValue: command)
    }

    package var encodedCommand: String {
        self.rawValue
    }
}

package struct SessionTypoCorrectionRequest: Sendable, Equatable {
    package var rawCommand: String
    package var nBest: Int
    package var beamSize: Int
    package var topK: Int
    package var maxSteps: Int?
    package var alpha: Float
    package var beta: Float
    package var gamma: Float

    package init(
        rawCommand: String,
        nBest: Int,
        beamSize: Int,
        topK: Int,
        maxSteps: Int? = nil,
        alpha: Float,
        beta: Float,
        gamma: Float
    ) {
        self.rawCommand = rawCommand
        self.nBest = nBest
        self.beamSize = beamSize
        self.topK = topK
        self.maxSteps = maxSteps
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
    }
}

package enum SessionEvent: Sendable, Equatable {
    case quit
    case deleteBackward
    case clearComposition
    case nextPage
    case save
    case predictInput(count: Int, maxEntropy: Float?, minLength: Int)
    case help
    case typoCorrection(SessionTypoCorrectionRequest)
    case updateConfig(key: String, value: String)
    case setLeftContext(String)
    case specialInput(SessionSpecialInput)
    case dumpHistory(String?)
    case selectCandidate(Int)
    case insert(String)
}

package struct SessionOutputs: Sendable {
    package var mainCandidates: [Candidate]
    package var predictionCandidates: [Candidate]
    package var liveConversion: LiveConversionSnapshot?

    package init(
        mainCandidates: [Candidate],
        predictionCandidates: [Candidate],
        liveConversion: LiveConversionSnapshot?
    ) {
        self.mainCandidates = mainCandidates
        self.predictionCandidates = predictionCandidates
        self.liveConversion = liveConversion
    }
}

package enum SessionPresentedContent: Sendable {
    case candidates([Candidate])
    case liveConversion(LiveConversionSnapshot)
}

package struct SessionSnapshot: Sendable {
    package var composingText: ComposingText
    package var leftSideContext: String
    package var config: SessionConfig
    package var presetID: String?
    package var outputs: SessionOutputs
    package var selectedView: SessionView
    package var presentedContent: SessionPresentedContent

    package init(
        composingText: ComposingText,
        leftSideContext: String,
        config: SessionConfig,
        presetID: String?,
        outputs: SessionOutputs,
        selectedView: SessionView,
        presentedContent: SessionPresentedContent
    ) {
        self.composingText = composingText
        self.leftSideContext = leftSideContext
        self.config = config
        self.presetID = presetID
        self.outputs = outputs
        self.selectedView = selectedView
        self.presentedContent = presentedContent
    }
}
