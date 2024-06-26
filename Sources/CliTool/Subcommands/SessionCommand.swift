import KanaKanjiConverterModuleWithDefaultDictionary
import ArgumentParser
import Foundation

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
        @Flag(name: [.customLong("disable_prediction")], help: "Disable producing prediction candidates.")
        var disablePrediction = false
        @Flag(name: [.customLong("enable_memory")], help: "Enable memory.")
        var enableLearning = false
        @Flag(name: [.customLong("only_whole_conversion")], help: "Show only whole conversion (完全一致変換).")
        var onlyWholeConversion = false
        @Flag(name: [.customLong("report_score")], help: "Show internal score for the candidate.")
        var reportScore = false
        @Flag(name: [.customLong("roman2kana")], help: "Use roman2kana input.")
        var roman2kana = false
        @Option(name: [.customLong("config_zenzai_inference_limit")], help: "inference limit for zenzai.")
        var configZenzaiInferenceLimit: Int = .max


        static var configuration = CommandConfiguration(commandName: "session", abstract: "Start session for incremental input.")

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

        @MainActor mutating func run() async {
            let memoryDirector = if self.enableLearning {
                if let dir = self.getTemporaryDirectory() {
                    dir
                } else {
                    fatalError("Could not get temporary directory.")
                }
            } else {
                URL(fileURLWithPath: "")
            }

            let converter = KanaKanjiConverter()
            var composingText = ComposingText()
            let inputStyle: InputStyle = self.roman2kana ? .roman2kana : .direct
            var lastCandidates: [Candidate] = []
            var page = 0
            while true {
                print()
                print("\(bold: "== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==")")
                let input = readLine(strippingNewline: true) ?? ""
                switch input {
                case ":q":
                    // 終了
                    return
                case ":d":
                    // 削除
                    composingText.deleteBackwardFromCursorPosition(count: 1)
                case ":c":
                    // クリア
                    composingText.stopComposition()
                    converter.stopComposition()
                    print("composition is stopped")
                    continue
                case ":n":
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
                case ":h":
                    // ヘルプ
                    print("""
                    \(bold: "== anco session commands ==")
                    \(bold: ":q") - quit session
                    \(bold: ":c") - clear composition
                    \(bold: ":d") - delete one character
                    \(bold: ":n") - see more candidates
                    \(bold: ":%d") - select candidate at that index (like :3 to select 3rd candidate)
                    """)
                default:
                    if input.hasPrefix(":"), let index = Int(input.dropFirst()) {
                        if !lastCandidates.indices.contains(index) {
                            print("\(bold: "Error"): Index \(index) is not available for current context.")
                            continue
                        }
                        let candidate = lastCandidates[index]
                        print("Submit \(candidate.text)")
                        converter.setCompletedData(candidate)
                        converter.updateLearningData(candidate)
                        composingText.prefixComplete(correspondingCount: candidate.correspondingCount)
                        if composingText.isEmpty {
                            composingText.stopComposition()
                            converter.stopComposition()
                        }
                    } else {
                        composingText.insertAtCursorPosition(input, inputStyle: inputStyle)
                    }
                }
                print(composingText.convertTarget)
                let start = Date()
                let result = converter.requestCandidates(composingText, options: requestOptions(memoryDirector: memoryDirector))
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

        func requestOptions(memoryDirector: URL) -> ConvertRequestOptions {
            var option: ConvertRequestOptions = .withDefaultDictionary(
                N_best: self.onlyWholeConversion ? max(self.configNBest, self.displayTopN) : self.configNBest,
                requireJapanesePrediction: !self.onlyWholeConversion && !self.disablePrediction,
                requireEnglishPrediction: false,
                keyboardLanguage: .ja_JP,
                typographyLetterCandidate: false,
                unicodeCandidate: true,
                englishCandidateInRoman2KanaInput: true,
                fullWidthRomanCandidate: false,
                halfWidthKanaCandidate: false,
                learningType: enableLearning ? .inputAndOutput : .nothing,
                maxMemoryCount: 0,
                shouldResetMemory: false,
                memoryDirectoryURL: memoryDirector,
                sharedContainerURL: URL(fileURLWithPath: ""),
                zenzaiMode: self.zenzWeightPath.isEmpty ? .off : .on(weight: URL(string: self.zenzWeightPath)!, inferenceLimit: self.configZenzaiInferenceLimit),
                metadata: .init(versionString: "anco for debugging")
            )
            if self.onlyWholeConversion {
                option.requestQuery = .完全一致
            }
            return option
        }
    }
}
