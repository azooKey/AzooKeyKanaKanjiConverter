import Algorithms
import EfficientNGram
package import Foundation
import SwiftUtils

@MainActor public final class KanaKanjiConverter {
    let converter: Kana2Kanji
    private lazy var defaultSession: KanaKanjiConverterSession = self.makeSession()

    public init() {
        self.converter = .init()
    }
    public init(dicdataStore: DicdataStore) {
        self.converter = .init(dicdataStore: dicdataStore)
    }

    nonisolated public static let defaultSpecialCandidateProviders: [any SpecialCandidateProvider] = [
        CalendarSpecialCandidateProvider(),
        EmailAddressSpecialCandidateProvider(),
        UnicodeSpecialCandidateProvider(),
        VersionSpecialCandidateProvider(),
        TimeExpressionSpecialCandidateProvider(),
        CommaSeparatedNumberSpecialCandidateProvider()
    ]

    @MainActor private var checker = SpellChecker()
    var sharedChecker: SpellChecker { checker }
    private var checkerInitialized: [KeyboardLanguage: Bool] = [.none: true, .ja_JP: true]

    // zenz model handle (shared across sessions)
    private var zenz: Zenz?
    private var zenzaiPersonalization: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?
    public private(set) var zenzStatus: String = ""

    public func stopComposition() {
        self.zenz?.endSession()
        self.zenzaiPersonalization = nil
        self.defaultSession.stop()
    }

    func getZenzaiPersonalization(mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode?) -> (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)? {
        guard let mode else {
            return nil
        }
        if let zenzaiPersonalization, zenzaiPersonalization.mode == mode {
            return zenzaiPersonalization
        }
        let tokenizer = ZenzTokenizer()
        let baseModel = EfficientNGram(baseFilename: mode.baseNgramLanguageModel, n: mode.n, d: mode.d, tokenizer: tokenizer)
        let personalModel = EfficientNGram(baseFilename: mode.personalNgramLanguageModel, n: mode.n, d: mode.d, tokenizer: tokenizer)
        self.zenzaiPersonalization = (mode, baseModel, personalModel)
        return (mode, baseModel, personalModel)
    }

    public func makeSession() -> KanaKanjiConverterSession {
        KanaKanjiConverterSession(converter: self)
    }

    package func getModel(modelURL: URL) -> Zenz? {
        if let model = self.zenz, model.resourceURL == modelURL {
            self.zenzStatus = "load \(modelURL.absoluteString)"
            return model
        } else {
            do {
                self.zenz = try Zenz(resourceURL: modelURL)
                self.zenzStatus = "load \(modelURL.absoluteString)"
                return self.zenz
            } catch {
                self.zenzStatus = "load \(modelURL.absoluteString)    " + error.localizedDescription
                return nil
            }
        }
    }

    public func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        guard let zenz = self.getModel(modelURL: options.zenzaiMode.weightURL) else {
            print("zenz-v2 model unavailable")
            return []
        }
        guard options.zenzaiMode.versionDependentMode.version == .v2 else {
            print("next character prediction requires zenz-v2 models, not zenz-v1 nor zenz-v3 and later")
            return []
        }
        return zenz.predictNextCharacter(leftSideContext: leftSideContext, count: count)
    }

    public func setKeyboardLanguage(_ language: KeyboardLanguage) {
        if !checkerInitialized[language, default: false] {
            switch language {
            case .en_US:
                Task { @MainActor in
                    _ = self.checker.completions(forPartialWordRange: NSRange(location: 0, length: 1), in: "a", language: "en-US")
                    self.checkerInitialized[language] = true
                }
            case .el_GR:
                Task { @MainActor in
                    _ = self.checker.completions(forPartialWordRange: NSRange(location: 0, length: 1), in: "a", language: "el-GR")
                    self.checkerInitialized[language] = true
                }
            case .none, .ja_JP:
                checkerInitialized[language] = true
            }
        }
    }

    public func sendToDicdataStore(_ data: DicdataStore.Notification) {
        self.converter.dicdataStore.sendToDicdataStore(data)
    }

    public func setCompletedData(_ candidate: Candidate) {
        self.defaultSession.setCompletedData(candidate)
    }
    public func updateLearningData(_ candidate: Candidate) {
        self.defaultSession.updateLearningData(candidate)
    }
    public func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        self.defaultSession.updateLearningData(candidate, with: predictionCandidate)
    }

    public func getAppropriateActions(_ candidate: Candidate) -> [CompleteAction] {
        if ["[]", "()", "｛｝", "〈〉", "〔〕", "（）", "「」", "『』", "【】", "{}", "<>", "《》", "\"\"", "\'\'", "””"].contains(candidate.text) { return [.moveCursor(-1)] }
        if ["{{}}"].contains(candidate.text) { return [.moveCursor(-2)] }
        return []
    }

    public func mergeCandidates(_ left: Candidate, _ right: Candidate) -> Candidate {
        converter.mergeCandidates(left, right)
    }
    public func requestCandidates(_ inputData: ComposingText, options: ConvertRequestOptions) -> ConversionResult {
        self.defaultSession.requestCandidates(inputData, options: options)
    }
    public func requestPostCompositionPredictionCandidates(leftSideCandidate: Candidate, options: ConvertRequestOptions) -> [PostCompositionPredictionCandidate] {
        self.defaultSession.requestPostCompositionPredictionCandidates(leftSideCandidate: leftSideCandidate, options: options)
    }
}
