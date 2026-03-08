import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

extension Subcommands {
    struct Session: AsyncParsableCommand {
        @Argument(help: "ひらがなで表記された入力")
        var input: String = ""

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

        @Option(name: [.customLong("replay")], help: "history.txt for replay.")
        var replayHistory: String?

        static let configuration = CommandConfiguration(commandName: "session", abstract: "Start session for incremental input.")

        @MainActor mutating func run() async throws {
            if self.zenzV2 {
                Swift.print("\(bold: "We strongly recommend to use zenz-v3 models")")
            }
            if !self.zenzWeightPath.isEmpty && (!self.zenzV2 && !self.zenzV3) {
                Swift.print("zenz version is not specified. By default, zenz-v3 will be used.")
            }

            let requestOptions = try self.makeRequestOptions()
            let userDictionaryItems = try AncoSession.parseUserDictionaryItems(
                from: self.configUserDictionary.map(URL.init(fileURLWithPath:))
            )
            var session = AncoSession(
                defaultDictionaryRequestOptions: requestOptions,
                inputStyle: self.roman2kana ? .roman2kana : .direct,
                displayTopN: self.displayTopN,
                debugPossibleNexts: true,
                userDictionaryItems: userDictionaryItems
            )

            Swift.print("Working with \(requestOptions.learningType) mode. Memory path is \(session.memoryDirectoryURL).")

            var inputs = try self.loadReplayInputs()
            while true {
                Swift.print()
                Swift.print("\(bold: "== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==")")
                if !session.leftSideContext.isEmpty {
                    Swift.print("\(bold: "Current Left-Side Context"): \(session.leftSideContext)")
                }

                let rawInput: String
                if inputs != nil {
                    rawInput = inputs!.removeFirst()
                } else {
                    rawInput = readLine(strippingNewline: true) ?? ""
                }

                if let typoConfig = self.parseTypoCorrectionCommand(rawInput) {
                    session.recordHistory(.typoCorrection(rawInput))
                    let result = session.experimentalRequestTypoCorrection(config: typoConfig)
                    self.printTypoCorrectionResult(result)
                    continue
                }

                guard let command = AncoSessionCommand(decoding: rawInput) else {
                    Swift.print("\(bold: "Error"): Failed to parse command: \(rawInput)")
                    continue
                }

                do {
                    let result = try session.execute(command)
                    self.printResult(result)
                    if result.shouldQuit {
                        return
                    }
                } catch {
                    Swift.print("\(bold: "Error"): \(error.localizedDescription)")
                }
            }
        }

        private func makeRequestOptions() throws -> ConvertRequestOptions {
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

            let zenzaiVersionDependentMode: ConvertRequestOptions.ZenzaiVersionDependentMode = if self.zenzV2 {
                .v2(.init(profile: self.configZenzaiProfile))
            } else {
                .v3(.init(profile: self.configZenzaiProfile, topic: self.configZenzaiTopic))
            }
            let personalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode?
            if let base = self.configZenzaiBaseLM, let personal = self.configZenzaiPersonalLM {
                personalizationMode = .init(
                    baseNgramLanguageModel: base,
                    personalNgramLanguageModel: personal,
                    n: 5,
                    d: 0.75,
                    alpha: self.configZenzaiPersonalizationAlpha
                )
            } else if self.configZenzaiBaseLM != nil || self.configZenzaiPersonalLM != nil {
                throw ValidationError("Both --config_zenzai_base_lm and --config_zenzai_personal_lm must be set")
            } else {
                personalizationMode = nil
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
                zenzaiMode: self.zenzWeightPath.isEmpty ? .off : .on(
                    weight: URL(fileURLWithPath: self.zenzWeightPath),
                    inferenceLimit: self.configZenzaiInferenceLimit,
                    requestRichCandidates: self.configRequestRichCandidates,
                    personalizationMode: personalizationMode,
                    versionDependentMode: zenzaiVersionDependentMode
                ),
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

        private func makeTypoMode() throws -> ConvertRequestOptions.TypoCorrectionMode {
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

        private func parseTypoCorrectionCommand(_ input: String) -> ExperimentalTypoCorrectionConfig? {
            guard input == ":tc" || input.hasPrefix(":tc ") else {
                return nil
            }

            let parts = input.split(separator: " ")
            var nBest = 5
            var beamSize = 10
            var topK = 100
            var maxSteps: Int?
            var alpha: Float = 2.0
            var beta: Float = 3.0
            var gamma: Float = 2.0

            for part in parts.dropFirst() {
                if let parsed = Int(part) {
                    nBest = parsed
                    continue
                }
                if part.hasPrefix("beam=") {
                    if let parsed = Int(part.dropFirst("beam=".count)) {
                        beamSize = parsed
                    }
                    continue
                }
                if part.hasPrefix("top_k=") {
                    if let parsed = Int(part.dropFirst("top_k=".count)) {
                        topK = parsed
                    }
                    continue
                }
                if part.hasPrefix("max_steps=") {
                    if let parsed = Int(part.dropFirst("max_steps=".count)) {
                        maxSteps = parsed
                    }
                    continue
                }
                if part.hasPrefix("alpha=") {
                    if let parsed = Float(part.dropFirst("alpha=".count)) {
                        alpha = parsed
                    }
                    continue
                }
                if part.hasPrefix("beta=") {
                    if let parsed = Float(part.dropFirst("beta=".count)) {
                        beta = parsed
                    }
                    continue
                }
                if part.hasPrefix("gamma=") {
                    if let parsed = Float(part.dropFirst("gamma=".count)) {
                        gamma = parsed
                    }
                }
            }

            return self.experimentalTypoCorrectionConfig(
                beamSize: max(1, min(beamSize, 256)),
                topK: max(1, min(topK, 256)),
                nBest: max(1, min(nBest, 50)),
                maxSteps: maxSteps,
                alpha: alpha,
                beta: beta,
                gamma: gamma
            )
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
                    Swift.print(message)
                }
                Swift.print(":tc [n] [beam=N] [top_k=N] [max_steps=N] [alpha=F] [beta=F] [gamma=F] - typo correction candidates (LM + channel)")

            case .stateCleared, .saved, .configUpdated:
                if let message = result.message {
                    Swift.print(message)
                }

            case .pageUpdated:
                self.printCandidates(result.displayedCandidates)

            case .candidatesUpdated:
                if let message = result.message {
                    Swift.print(message)
                }
                if let predictiveInputTime = result.predictiveInputTime {
                    Swift.print("\(bold: "Time (ip):") \(predictiveInputTime)")
                }
                Swift.print(result.composingText.convertTarget)
                self.printCandidates(result.displayedCandidates)
                if let entropy = result.entropy {
                    Swift.print("\(bold: "Entropy:") \(entropy)")
                }
                if let elapsedTime = result.elapsedTime {
                    Swift.print("\(bold: "Time:") \(elapsedTime)")
                }

            case .noAction:
                if let message = result.message {
                    Swift.print(message)
                }
            }
        }

        private func printTypoCorrectionResult(_ result: AncoSession.TypoCorrectionResult) {
            if result.candidates.isEmpty {
                Swift.print("No typo correction candidate found.")
            } else {
                for (index, candidate) in result.candidates.enumerated() {
                    Swift.print(
                        "\(bold: String(index)). \(candidate.correctedInput) " +
                        "\(bold: "score:") \(candidate.score) " +
                        "\(bold: "lm:") \(candidate.lmScore) " +
                        "\(bold: "channel:") \(candidate.channelCost) " +
                        "\(bold: "prom:") \(candidate.prominence) " +
                        "\(bold: "text:") \(candidate.convertedText)"
                    )
                }
            }
            Swift.print("\(bold: "Time (tc):") \(result.elapsedTime)")
        }

        private func printCandidates(_ candidates: [Candidate]) {
            for (index, candidate) in candidates.enumerated() {
                if self.reportScore {
                    Swift.print("\(bold: String(index)). \(candidate.text) \(bold: "score:") \(candidate.value)")
                } else {
                    Swift.print("\(bold: String(index)). \(candidate.text)")
                }
            }
        }

        private func experimentalTypoCorrectionConfig(
            beamSize: Int = 32,
            topK: Int = 64,
            nBest: Int = 5,
            maxSteps: Int? = nil,
            alpha: Float = 2.0,
            beta: Float = 3.0,
            gamma: Float = 2.0
        ) -> ExperimentalTypoCorrectionConfig {
            precondition(self.configTypoNGramN > 0, "--config_typo_ngram_n must be positive")
            let languageModel: ExperimentalTypoCorrectionConfig.LanguageModel = if let prefix = self.configTypoNGramPrefix, !prefix.isEmpty {
                .ngram(.init(prefix: prefix, n: self.configTypoNGramN, d: self.configTypoNGramD))
            } else {
                .zenz
            }
            return .init(
                languageModel: languageModel,
                beamSize: beamSize,
                topK: topK,
                nBest: nBest,
                maxSteps: maxSteps,
                alpha: alpha,
                beta: beta,
                gamma: gamma
            )
        }
    }
}
