import Foundation

/// Actor representing a kana-kanji converter session.
public actor KanaKanjiConverterSession {
    private let converter: KanaKanjiConverter
    private var previousInputData: ComposingText?
    private var nodes: [[LatticeNode]] = []

    public init(converter: KanaKanjiConverter) {
        self.converter = converter
    }

    // MARK: - Wrapper APIs

    public func stopComposition() {
        self.converter.stopComposition()
        self.previousInputData = nil
        self.nodes = []
    }

    public func predictNextCharacterAsync(leftSideContext: String, count: Int, options: ConvertRequestOptions) async -> [(character: Character, value: Float)] {
        await self.converter.predictNextCharacterAsync(leftSideContext: leftSideContext, count: count, options: options)
    }

    public func predictNextCharacter(leftSideContext: String, count: Int, options: ConvertRequestOptions) -> [(character: Character, value: Float)] {
        self.converter.predictNextCharacter(leftSideContext: leftSideContext, count: count, options: options)
    }

    public func setKeyboardLanguage(_ language: KeyboardLanguage) {
        self.converter.setKeyboardLanguage(language)
    }

    public func sendToDicdataStore(_ data: DicdataStore.Notification) {
        self.converter.sendToDicdataStore(data)
    }

    public func setCompletedData(_ candidate: Candidate) {
        self.converter.setCompletedData(candidate)
    }

    public func updateLearningData(_ candidate: Candidate) {
        self.converter.updateLearningData(candidate)
    }

    public func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        self.converter.updateLearningData(candidate, with: predictionCandidate)
    }

    public func getAppropriateActions(_ candidate: Candidate) -> [CompleteAction] {
        self.converter.getAppropriateActions(candidate)
    }

    public func mergeCandidates(_ left: Candidate, _ right: Candidate) -> Candidate {
        self.converter.mergeCandidates(left, right)
    }

    public func requestCandidatesAsync(_ inputData: ComposingText, options: ConvertRequestOptions) async -> ConversionResult {
        if inputData.convertTarget.isEmpty {
            return ConversionResult(mainResults: [], firstClauseResults: [])
        }

        self.converter.sendToDicdataStore(.setRequestOptions(options))

        guard let lattice = await self.converter.convertToLattice(
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

    public func requestCandidates(_ inputData: ComposingText, options: ConvertRequestOptions) -> ConversionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: ConversionResult = ConversionResult(mainResults: [], firstClauseResults: [])
        Task.detached {
            result = await self.requestCandidatesAsync(inputData, options: options)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    public func requestPostCompositionPredictionCandidates(leftSideCandidate: Candidate, options: ConvertRequestOptions) -> [PostCompositionPredictionCandidate] {
        self.converter.requestPostCompositionPredictionCandidates(leftSideCandidate: leftSideCandidate, options: options)
    }
}

