import Algorithms
import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils
import Tokenizers

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
        @Flag(name: [.customLong("zenz_v1")], help: "Use zenz_v1 model.")
        var zenzV1 = false
        @Flag(name: [.customLong("zenz_v2")], help: "Use zenz_v2 model.")
        var zenzV2 = false
        @Flag(name: [.customLong("zenz_v3")], help: "Use zenz_v3 model.")
        var zenzV3 = false
        @Option(name: [.customLong("config_zenzai_base_lm")], help: "Marisa files for Base LM.")
        var configZenzaiBaseLM: String?
        @Option(name: [.customLong("config_zenzai_personal_lm")], help: "Marisa files for Personal LM.")
        var configZenzaiPersonalLM: String?
        @Option(name: [.customLong("config_zenzai_personalization_alpha")], help: "Strength of personalization (0.5 by default)")
        var configZenzaiPersonalizationAlpha: Float = 0.5

        @Option(name: [.customLong("replay")], help: "history.txt for replay.")
        var replayHistory: String?

        static let configuration = CommandConfiguration(commandName: "session", abstract: "Start session for incremental input.")

        private func getTemporaryDirectory() -> URL? {
            let fileManager = FileManager.default
            let tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            do {
                try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                print("Temporary directory created at \(tempDirectoryURL)")
                return tempDirectoryURL
            } catch {
                print("Error creating temporary directory: \(error)")
                return nil
            }
        }

        private func parseUserDictionaryFile() throws -> [InputUserDictionaryItem] {
            guard let configUserDictionary else {
                return []
            }
            let url = URL(fileURLWithPath: configUserDictionary)
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([InputUserDictionaryItem].self, from: data)
        }

        @MainActor mutating func run() async {
            if self.zenzV1 || self.zenzV2 {
                print("\(bold: "We strongly recommend to use zenz-v3 models")")
            }
            if (self.zenzV1 || self.zenzV2 || self.zenzV3) && self.zenzWeightPath.isEmpty {
                preconditionFailure("\(bold: "zenz version is specified but --zenz weight is not specified")")
            }
            if !self.zenzWeightPath.isEmpty && (!self.zenzV1 && !self.zenzV2 && !self.zenzV3) {
                print("zenz version is not specified. By default, zenz-v3 will be used.")
            }

            let userDictionary = try! self.parseUserDictionaryFile().map {
                DicdataElement(word: $0.word, ruby: $0.reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
            }

            let learningType: LearningType = if self.readOnlyMemoryPath != nil {
                // 読み取りのみ
                .onlyOutput
            } else if self.enableLearning {
                // 読み書き
                .inputAndOutput
            } else {
                // 読み書きなし
                .nothing
            }
            let memoryDirectory = if let readOnlyMemoryPath {
                URL(fileURLWithPath: readOnlyMemoryPath)
            } else if self.enableLearning {
                if let dir = self.getTemporaryDirectory() {
                    dir
                } else {
                    fatalError("Could not get temporary directory.")
                }
            } else {
                URL(fileURLWithPath: "")
            }
            print("Working with \(learningType) mode. Memory path is \(memoryDirectory).")

            let converter = KanaKanjiConverter()
            converter.sendToDicdataStore(
                .setRequestOptions(requestOptions(learningType: learningType, memoryDirectory: memoryDirectory, leftSideContext: nil))
            )
            converter.sendToDicdataStore(.importDynamicUserDict(userDictionary))
            var composingText = ComposingText()
            let inputStyle: InputStyle = self.roman2kana ? .roman2kana : .direct
            var lastCandidates: [Candidate] = []
            var leftSideContext: String = ""
            var page = 0

            var histories = [String]()

            var inputs = self.replayHistory.map {
                try! String(contentsOfFile: $0, encoding: .utf8)
            }?.split(by: "\n")
            inputs?.append(":q")

            while true {
                print()
                print("\(bold: "== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==")")
                if !leftSideContext.isEmpty {
                    print("\(bold: "Current Left-Side Context"): \(leftSideContext)")
                }
                var input = if inputs != nil {
                    inputs!.removeFirst()
                } else {
                    readLine(strippingNewline: true) ?? ""
                }
                histories.append(input)
                switch input {
                case ":q", ":quit":
                    // 終了
                    return
                case ":d", ":del":
                    if !composingText.isEmpty {
                        composingText.deleteBackwardFromCursorPosition(count: 1)
                    } else {
                        _ = leftSideContext.popLast()
                        continue
                    }
                case ":c", ":clear":
                    // クリア
                    composingText.stopComposition()
                    converter.stopComposition()
                    leftSideContext = ""
                    print("composition is stopped")
                    continue
                case ":n", ":next":
                    // ページ送り
                    page += 1
                    for (i, candidate) in lastCandidates[self.displayTopN * page ..< self.displayTopN * (page + 1)].indexed() {
                        if self.reportScore {
                            print("\(bold: String(i)). \(candidate.text) \(bold: "score:") \(candidate.value)")
                        } else {
                            print("\(bold: String(i)). \(candidate.text)")
                        }
                    }
                    continue
                case ":s", ":save":
                    composingText.stopComposition()
                    converter.stopComposition()
                    converter.sendToDicdataStore(.closeKeyboard)
                    if learningType.needUpdateMemory {
                        print("saved")
                    } else {
                        print("anything should not be saved because the learning type is not for update memory")
                    }
                    continue
                case ":p", ":pred":
                    // 次の文字の予測を取得する
                    let results = converter.predictNextCharacter(
                        leftSideContext: leftSideContext,
                        count: 10,
                        options: requestOptions(learningType: learningType, memoryDirectory: memoryDirectory, leftSideContext: leftSideContext)
                    )
                    if let firstCandidate = results.first {
                        leftSideContext.append(firstCandidate.character)
                    }
                    continue
                case ":h", ":help":
                    // ヘルプ
                    print("""
                    \(bold: "== anco session commands ==")
                    \(bold: ":q, :quit") - quit session
                    \(bold: ":c, :clear") - clear composition
                    \(bold: ":d, :del") - delete one character
                    \(bold: ":n, :next") - see more candidates
                    \(bold: ":s, :save") - save memory to temporary directory
                    \(bold: ":p, :pred") - predict next one character
                    \(bold: ":%d") - select candidate at that index (like :3 to select 3rd candidate)
                    \(bold: ":ctx %s") - set the string as context
                    \(bold: ":input %s") - insert special characters to input. Supported special characters:
                    - eot: end of text (for finalizing composition)
                    \(bold: ":dump %s") - dump command history to specified file name (default: history.txt).
                    """)
                default:
                    if input.hasPrefix(":ctx") {
                        let ctx = String(input.split(by: ":ctx ").last ?? "")
                        leftSideContext.append(ctx)
                        continue
                    } else if input.hasPrefix(":input") {
                        let specialInput = String(input.split(by: ":input ").last ?? "")
                        switch specialInput {
                        case "eot":
                            composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
                        default:
                            fatalError("Unknown special input: \(specialInput)")
                        }
                    } else if input.hasPrefix(":dump") {
                        let fileName = if ":dump " < input {
                            String(input.dropFirst(6))
                        } else {
                            "history.txt"
                        }
                        histories.removeAll(where: {$0.hasPrefix(":dump")})
                        let content = histories.joined(separator: "\n")
                        try! content.write(to: URL(fileURLWithPath: fileName), atomically: true, encoding: .utf8)
                        continue
                    } else if input.hasPrefix(":"), let index = Int(input.dropFirst()) {
                        if !lastCandidates.indices.contains(index) {
                            print("\(bold: "Error"): Index \(index) is not available for current context.")
                            continue
                        }
                        let candidate = lastCandidates[index]
                        print("Submit \(candidate.text)")
                        converter.setCompletedData(candidate)
                        converter.updateLearningData(candidate)
                        composingText.prefixComplete(composingCount: candidate.composingCount)
                        if composingText.isEmpty {
                            composingText.stopComposition()
                            converter.stopComposition()
                        }
                        leftSideContext += candidate.text
                    } else {
                        input = String(input.map { (c: Character) -> Character in
                            [
                                "-": "ー",
                                ".": "。",
                                ",": "、"
                            ][c, default: c]
                        })
                        composingText.insertAtCursorPosition(input, inputStyle: inputStyle)
                    }
                }
                print(composingText.convertTarget)
                let start = Date()
                let result = converter.requestCandidates(composingText, options: requestOptions(learningType: learningType, memoryDirectory: memoryDirectory, leftSideContext: leftSideContext))
                let mainResults = result.mainResults.filter {
                    !self.onlyWholeConversion || $0.data.reduce(into: "", {$0.append(contentsOf: $1.ruby)}) == input.toKatakana()
                }
                for (i, candidate) in mainResults.prefix(self.displayTopN).indexed() {
                    if self.reportScore {
                        print("\(bold: String(i)). \(candidate.text) \(bold: "score:") \(candidate.value)")
                    } else {
                        print("\(bold: String(i)). \(candidate.text)")
                    }
                }
                lastCandidates = mainResults
                page = 0
                if self.onlyWholeConversion {
                    // entropyを示す
                    let mean = mainResults.reduce(into: 0) { $0 += Double($1.value) } / Double(mainResults.count)
                    let expValues = mainResults.map { exp(Double($0.value) - mean) }
                    let sumOfExpValues = expValues.reduce(into: 0, +=)
                    // 確率値に補正
                    let probs = mainResults.map { exp(Double($0.value) - mean) / sumOfExpValues }
                    let entropy = -probs.reduce(into: 0) { $0 += $1 * log($1) }
                    print("\(bold: "Entropy:") \(entropy)")
                }
                print("\(bold: "Time:") \(-start.timeIntervalSinceNow)")
            }
        }

        func requestOptions(learningType: LearningType, memoryDirectory: URL, leftSideContext: String?) -> ConvertRequestOptions {
            let zenzaiVersionDependentMode: ConvertRequestOptions.ZenzaiVersionDependentMode = if self.zenzV1 {
                .v1
            } else if self.zenzV2 {
                .v2(.init(profile: self.configZenzaiProfile, leftSideContext: leftSideContext))
            } else {
                .v3(.init(profile: self.configZenzaiProfile, topic: self.configZenzaiTopic, leftSideContext: leftSideContext))
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
                fatalError("Both --config_zenzai_base_lm and --config_zenzai_personal_lm must be set")
            } else {
                personalizationMode = nil
            }
            var option: ConvertRequestOptions = .withDefaultDictionary(
                N_best: self.onlyWholeConversion ? max(self.configNBest, self.displayTopN) : self.configNBest,
                requireJapanesePrediction: !self.onlyWholeConversion && !self.disablePrediction,
                requireEnglishPrediction: false,
                keyboardLanguage: .ja_JP,
                typographyLetterCandidate: false,
                unicodeCandidate: true,
                englishCandidateInRoman2KanaInput: self.mixEnglishCandidate,
                fullWidthRomanCandidate: false,
                halfWidthKanaCandidate: false,
                learningType: learningType,
                shouldResetMemory: false,
                memoryDirectoryURL: memoryDirectory,
                sharedContainerURL: URL(fileURLWithPath: ""),
                zenzaiMode: self.zenzWeightPath.isEmpty ? .off : .on(
                    weight: URL(string: self.zenzWeightPath)!,
                    inferenceLimit: self.configZenzaiInferenceLimit,
                    requestRichCandidates: self.configRequestRichCandidates,
                    personalizationMode: personalizationMode,
                    versionDependentMode: zenzaiVersionDependentMode
                ),
                metadata: .init(versionString: "anco for debugging")
            )
            if self.onlyWholeConversion {
                option.requestQuery = .完全一致
            }
            return option
        }
    }
}
