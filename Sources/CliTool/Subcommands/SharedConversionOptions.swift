import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct SharedConversionOptions: ParsableArguments {
    @Option(name: [.customLong("config_n_best")], help: "The parameter n (n best parameter) for internal viterbi search.")
    var configNBest: Int = 10
    @Option(name: [.customShort("n"), .customLong("top_n")], help: "Display top n candidates.")
    var displayTopN: Int = 1
    @Option(name: [.customLong("zenz")], help: "gguf format model weight for zenz.")
    var zenzWeightPath: String = ""
    @Flag(name: [.customLong("mix_english_candidate")], help: "Enable mixing English Candidates.")
    var mixEnglishCandidate = false
    @Flag(name: [.customLong("disable_prediction")], help: "Disable producing prediction candidates.")
    var disablePrediction = false
    @Flag(name: [.customLong("enable_memory")], help: "Enable memory.")
    var enableLearning = false
    @Option(name: [.customLong("readwrite_memory")], help: "Enable read/write memory.")
    var writableMemoryPath: String?
    @Option(name: [.customLong("readonly_memory")], help: "Enable readonly memory.")
    var readOnlyMemoryPath: String?
    @Flag(name: [.customLong("only_whole_conversion")], help: "Show only whole conversion (完全一致変換).")
    var onlyWholeConversion = false
    @Flag(name: [.customLong("report_score")], help: "Show internal score for the candidate.")
    var reportScore = false
    @Flag(name: [.customLong("roman2kana")], help: "Use roman2kana input.")
    var roman2kana = false
    @Option(name: [.customLong("config_user_dictionary")], help: "User Dictionary JSON file path")
    var configUserDictionary: String?
    @Option(name: [.customLong("config_zenzai_inference_limit")], help: "inference limit for zenzai.")
    var configZenzaiInferenceLimit: Int = .max
    @Flag(name: [.customLong("config_zenzai_rich_n_best")], help: "enable rich n_best generation for zenzai.")
    var configRequestRichCandidates = false
    @Option(name: [.customLong("config_profile")], help: "enable profile prompting for zenz-v2 and later.")
    var configZenzaiProfile: String?
    @Option(name: [.customLong("config_topic")], help: "enable topic prompting for zenz-v3 and later.")
    var configZenzaiTopic: String?
    @Flag(name: [.customLong("zenz_v2")], help: "Use zenz_v2 model.")
    var zenzV2 = false
    @Flag(name: [.customLong("zenz_v3")], help: "Use zenz_v3 model.")
    var zenzV3 = false
    @Flag(name: [.customLong("experimental_zenzai_predictive_input")], help: "Enable experimental zenzai predictive input.")
    var experimentalZenzaiPredictiveInput = false
    @Option(name: [.customLong("config_typo_mode")], help: "Typo correction mode for normal conversion: auto/on/off.")
    var configTypoMode: String = "auto"
    @Option(name: [.customLong("config_typo_ngram_prefix")], help: "Prefix for experimental typo n-gram model files.")
    var configTypoNGramPrefix: String?
    @Option(name: [.customLong("config_typo_ngram_n")], help: "n for experimental typo n-gram LM. (default: 5)")
    var configTypoNGramN: Int = 5
    @Option(name: [.customLong("config_typo_ngram_d")], help: "discount d for experimental typo n-gram LM. (default: 0.75)")
    var configTypoNGramD: Double = 0.75
    @Option(name: [.customLong("config_zenzai_base_lm")], help: "Marisa files for Base LM.")
    var configZenzaiBaseLM: String?
    @Option(name: [.customLong("config_zenzai_personal_lm")], help: "Marisa files for Personal LM.")
    var configZenzaiPersonalLM: String?
    @Option(name: [.customLong("config_zenzai_personalization_alpha")], help: "Strength of personalization (0.5 by default)")
    var configZenzaiPersonalizationAlpha: Float = 0.5

    var inputStyle: InputStyle {
        self.roman2kana ? .roman2kana : .direct
    }

    func parseUserDictionaryItems() throws -> [AncoSession.InputUserDictionaryItem] {
        try AncoSession.parseUserDictionaryItems(
            from: self.configUserDictionary.map(URL.init(fileURLWithPath:))
        )
    }

    func makeRequestOptions() throws -> ConvertRequestOptions {
        if (self.zenzV2 || self.zenzV3) && self.zenzWeightPath.isEmpty {
            throw ValidationError("zenz version is specified but --zenz weight is not specified")
        }
        let learningType: LearningType
        if self.writableMemoryPath != nil {
            learningType = .inputAndOutput
        } else if self.readOnlyMemoryPath != nil {
            learningType = .onlyOutput
        } else if self.enableLearning {
            learningType = .inputAndOutput
        } else {
            learningType = .nothing
        }

        let japanesePredictionMode: ConvertRequestOptions.PredictionMode = (!self.onlyWholeConversion && !self.disablePrediction) ? .autoMix : .disabled
        let typoMode = try self.makeTypoMode()
        var options = ConvertRequestOptions(
            N_best: self.onlyWholeConversion ? max(self.configNBest, self.displayTopN) : self.configNBest,
            requireJapanesePrediction: japanesePredictionMode,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: self.mixEnglishCandidate,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: learningType,
            shouldResetMemory: false,
            memoryDirectoryURL: self.writableMemoryPath.map(URL.init(fileURLWithPath:))
                ?? self.readOnlyMemoryPath.map(URL.init(fileURLWithPath:))
                ?? (learningType == .nothing ? URL(fileURLWithPath: "") : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: try self.makeZenzaiMode(versionDependentMode: self.makeDefaultVersionDependentMode()),
            experimentalZenzaiPredictiveInput: self.experimentalZenzaiPredictiveInput,
            typoCorrectionMode: typoMode,
            metadata: .init(versionString: "anco for debugging")
        )
        if self.onlyWholeConversion {
            options.requestQuery = .完全一致
        }
        if learningType != .nothing,
           self.writableMemoryPath == nil,
           self.readOnlyMemoryPath == nil,
           self.enableLearning {
            try FileManager.default.createDirectory(at: options.memoryDirectoryURL, withIntermediateDirectories: true)
        }
        return options
    }

    func makeEvaluateRequestOptions(leftSideContext: String?, ignoreLeftContext: Bool) throws -> ConvertRequestOptions {
        var options = ConvertRequestOptions(
            N_best: self.configNBest,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: try self.makeZenzaiMode(
                versionDependentMode: .v3(.init(leftSideContext: ignoreLeftContext ? nil : leftSideContext))
            ),
            experimentalZenzaiPredictiveInput: self.experimentalZenzaiPredictiveInput,
            typoCorrectionMode: try self.makeTypoMode(),
            metadata: .init(versionString: "anco for debugging")
        )
        options.requestQuery = .完全一致
        return options
    }

    func makePersonalizationMode() throws -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        if let base = self.configZenzaiBaseLM, let personal = self.configZenzaiPersonalLM {
            return .init(
                baseNgramLanguageModel: base,
                personalNgramLanguageModel: personal,
                n: 5,
                d: 0.75,
                alpha: self.configZenzaiPersonalizationAlpha
            )
        }
        if self.configZenzaiBaseLM != nil || self.configZenzaiPersonalLM != nil {
            throw ValidationError("Both --config_zenzai_base_lm and --config_zenzai_personal_lm must be set")
        }
        return nil
    }

    func makeDefaultVersionDependentMode() -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        if self.zenzV2 {
            return .v2(.init(profile: self.configZenzaiProfile))
        }
        return .v3(.init(profile: self.configZenzaiProfile, topic: self.configZenzaiTopic))
    }

    func makeZenzaiMode(
        versionDependentMode: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) throws -> ConvertRequestOptions.ZenzaiMode {
        guard !self.zenzWeightPath.isEmpty else {
            return .off
        }
        return .on(
            weight: URL(fileURLWithPath: self.zenzWeightPath),
            inferenceLimit: self.configZenzaiInferenceLimit,
            requestRichCandidates: self.configRequestRichCandidates,
            personalizationMode: try self.makePersonalizationMode(),
            versionDependentMode: versionDependentMode
        )
    }

    func makeExperimentalTypoCorrectionConfig(
        from command: AncoSessionRequest.TypoCorrection
    ) -> ExperimentalTypoCorrectionConfig {
        precondition(self.configTypoNGramN > 0, "--config_typo_ngram_n must be positive")
        let languageModel: ExperimentalTypoCorrectionConfig.LanguageModel = if let prefix = self.configTypoNGramPrefix, !prefix.isEmpty {
            .ngram(.init(prefix: prefix, n: self.configTypoNGramN, d: self.configTypoNGramD))
        } else {
            .zenz
        }
        return .init(
            languageModel: languageModel,
            beamSize: command.beamSize,
            topK: command.topK,
            nBest: command.nBest,
            maxSteps: command.maxSteps,
            alpha: command.alpha,
            beta: command.beta,
            gamma: command.gamma
        )
    }

    func makeTypoMode() throws -> ConvertRequestOptions.TypoCorrectionMode {
        switch self.configTypoMode {
        case "auto":
            .automatic
        case "on":
            .enabled
        case "off":
            .disabled
        default:
            throw ValidationError("Unknown --config_typo_mode '\(self.configTypoMode)'. Use auto/on/off.")
        }
    }

}
