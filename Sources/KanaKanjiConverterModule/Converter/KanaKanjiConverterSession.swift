import Foundation
import SwiftUtils
import EfficientNGram

/// Actor representing a kana-kanji converter session.
public actor KanaKanjiConverterSession {
    private let converter: KanaKanjiConverter
    private var previousInputData: ComposingText?
    private var nodes: [[LatticeNode]] = []
    private var completedData: Candidate?
    private var lastData: DicdataElement?
    private var zenz: Zenz? = nil
    private var zenzaiCache: Kana2Kanji.ZenzaiCache? = nil
    private var zenzaiPersonalization: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?
    public private(set) var zenzStatus: String = ""

    public init(converter: KanaKanjiConverter) {
        self.converter = converter
    }

    // MARK: - Wrapper APIs

    public func stopComposition() {
        if let zenz = self.zenz {
            Task.detached { await zenz.endSession() }
        }
        self.zenzaiPersonalization = nil
        self.zenzaiCache = nil
        self.completedData = nil
        self.lastData = nil
        self.previousInputData = nil
        self.nodes = []
    }

    package func getZenzaiPersonalization(mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode?) -> (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)? {
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

    package func getModel(modelURL: URL) async -> Zenz? {
        if let model = self.zenz, await model.resourceURL == modelURL {
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

    public func predictNextCharacterAsync(leftSideContext: String, count: Int, options: ConvertRequestOptions) async -> [(character: Character, value: Float)] {
        guard options.zenzaiMode.enabled else {
            return []
        }
        guard let zenz = await self.getModel(modelURL: options.zenzaiMode.weightURL) else {
            print("zenz-v2 model unavailable")
            return []
        }
        guard options.zenzaiMode.versionDependentMode.version == .v2 else {
            print("next character prediction requires zenz-v2 models, not zenz-v1 nor zenz-v3 and later")
            return []
        }
        let results = await zenz.predictNextCharacter(leftSideContext: leftSideContext, count: count)
        return results
    }

    public nonisolated func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [(character: Character, value: Float)] = []
        Task.detached { [self] in
            result = await self.predictNextCharacterAsync(leftSideContext: leftSideContext, count: count, options: options)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    public func setKeyboardLanguage(_ language: KeyboardLanguage) {
        self.converter.setKeyboardLanguage(language)
    }

    public func sendToDicdataStore(_ data: DicdataStore.Notification) {
        self.converter.sendToDicdataStore(data)
    }

    public func setCompletedData(_ candidate: Candidate) {
        self.completedData = candidate
    }

    public func updateLearningData(_ candidate: Candidate) {
        self.converter.kana2Kanji.dicdataStore.updateLearningData(candidate, with: self.lastData)
        self.lastData = candidate.data.last
    }

    public func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        self.converter.kana2Kanji.dicdataStore.updateLearningData(candidate, with: predictionCandidate)
        self.lastData = predictionCandidate.lastData
    }

    private func convertToLattice(
        _ inputData: ComposingText,
        N_best: Int,
        zenzaiMode: ConvertRequestOptions.ZenzaiMode,
        previousInputData: ComposingText?,
        nodes: [[LatticeNode]]
    ) async -> (result: LatticeNode, nodes: [[LatticeNode]])? {
        if inputData.convertTarget.isEmpty {
            return nil
        }

        if zenzaiMode.enabled, let model = await self.getModel(modelURL: zenzaiMode.weightURL) {
            let (result, nodes, cache) = await self.converter.kana2Kanji.all_zenzai(
                inputData,
                zenz: model,
                zenzaiCache: self.zenzaiCache,
                inferenceLimit: zenzaiMode.inferenceLimit,
                requestRichCandidates: zenzaiMode.requestRichCandidates,
                personalizationMode: self.getZenzaiPersonalization(mode: zenzaiMode.personalizationMode),
                versionDependentConfig: zenzaiMode.versionDependentMode
            )
            self.zenzaiCache = cache
            return (result, nodes)
        }

        #if os(iOS)
        let needTypoCorrection = true
        #else
        let needTypoCorrection = false
        #endif

        guard let previousInputData else {
            debug("convertToLattice: 新規計算用の関数を呼びますA")
            let result = converter.kana2Kanji.kana2lattice_all(inputData, N_best: N_best, needTypoCorrection: needTypoCorrection)
            return result
        }

        debug("convertToLattice: before \(previousInputData) after \(inputData)")

        if previousInputData == inputData {
            let result = converter.kana2Kanji.kana2lattice_no_change(N_best: N_best, previousResult: (inputData: previousInputData, nodes: nodes))
            return result
        }

        if let completedData, previousInputData.inputHasSuffix(inputOf: inputData) {
            debug("convertToLattice: 文節確定用の関数を呼びます、確定された文節は\(completedData)")
            let result = converter.kana2Kanji.kana2lattice_afterComplete(inputData, completedData: completedData, N_best: N_best, previousResult: (inputData: previousInputData, nodes: nodes), needTypoCorrection: needTypoCorrection)
            self.completedData = nil
            return result
        }

        let diff = inputData.differenceSuffix(to: previousInputData)

        if diff.deleted > 0 && diff.addedCount == 0 {
            debug("convertToLattice: 最後尾削除用の関数を呼びます, 消した文字数は\(diff.deleted)")
            let result = converter.kana2Kanji.kana2lattice_deletedLast(deletedCount: diff.deleted, N_best: N_best, previousResult: (inputData: previousInputData, nodes: nodes))
            return result
        }

        if diff.deleted > 0 {
            debug("convertToLattice: 最後尾文字置換用の関数を呼びます、差分は\(diff)")
            let result = converter.kana2Kanji.kana2lattice_changed(inputData, N_best: N_best, counts: (diff.deleted, diff.addedCount), previousResult: (inputData: previousInputData, nodes: nodes), needTypoCorrection: needTypoCorrection)
            return result
        }

        if diff.deleted == 0 && diff.addedCount != 0 {
            debug("convertToLattice: 最後尾追加用の関数を呼びます、追加文字数は\(diff.addedCount)")
            let result = converter.kana2Kanji.kana2lattice_added(inputData, N_best: N_best, addedCount: diff.addedCount, previousResult: (inputData: previousInputData, nodes: nodes), needTypoCorrection: needTypoCorrection)
            return result
        }

        debug("convertToLattice: 新規計算用の関数を呼びますB")
        let result = converter.kana2Kanji.kana2lattice_all(inputData, N_best: N_best, needTypoCorrection: needTypoCorrection)
        return result
    }

    public func getAppropriateActions(_ candidate: Candidate) -> [CompleteAction] {
        return self.converter.getAppropriateActions(candidate)
    }

    public func mergeCandidates(_ left: Candidate, _ right: Candidate) -> Candidate {
        return self.converter.mergeCandidates(left, right)
    }

    public func requestCandidatesAsync(_ inputData: ComposingText, options: ConvertRequestOptions) async -> ConversionResult {
        if inputData.convertTarget.isEmpty {
            return ConversionResult(mainResults: [], firstClauseResults: [])
        }

        self.converter.sendToDicdataStore(.setRequestOptions(options))

        guard let lattice = await self.convertToLattice(
            inputData,
            N_best: options.N_best,
            zenzaiMode: options.zenzaiMode,
            previousInputData: self.previousInputData,
            nodes: self.nodes
        ) else {
            return ConversionResult(mainResults: [], firstClauseResults: [])
        }

        self.previousInputData = inputData
        self.nodes = lattice.nodes

        return await self.converter.processResult(inputData: inputData, result: lattice, options: options)
    }

    public nonisolated func requestCandidates(_ inputData: ComposingText, options: ConvertRequestOptions) -> ConversionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: ConversionResult = ConversionResult(mainResults: [], firstClauseResults: [])
        Task.detached { [self] in
            result = await self.requestCandidatesAsync(inputData, options: options)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    public func requestPostCompositionPredictionCandidates(leftSideCandidate: Candidate, options: ConvertRequestOptions) -> [PostCompositionPredictionCandidate] {
        return self.converter.requestPostCompositionPredictionCandidates(leftSideCandidate: leftSideCandidate, options: options)
    }
}

