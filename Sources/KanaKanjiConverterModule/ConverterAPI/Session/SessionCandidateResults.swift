public struct SessionCandidateResults: Sendable {
    public var mainCandidates: [Candidate]
    public var predictionCandidates: [Candidate]
    public var firstClauseCandidates: [Candidate]
    public var liveConversionSnapshot: LiveConversionSnapshot?

    public init(
        mainCandidates: [Candidate],
        predictionCandidates: [Candidate],
        firstClauseCandidates: [Candidate],
        liveConversionSnapshot: LiveConversionSnapshot?
    ) {
        self.mainCandidates = mainCandidates
        self.predictionCandidates = predictionCandidates
        self.firstClauseCandidates = firstClauseCandidates
        self.liveConversionSnapshot = liveConversionSnapshot
    }

    public init(
        conversionResult: ConversionResult,
        composingText: ComposingText,
        liveConversionState: inout LiveConversionState,
        mainCandidates: [Candidate]? = nil
    ) {
        let mainCandidates = mainCandidates ?? conversionResult.mainResults
        self.mainCandidates = mainCandidates
        self.predictionCandidates = conversionResult.predictionResults
        self.firstClauseCandidates = conversionResult.firstClauseResults
        if liveConversionState.config.enabled {
            self.liveConversionSnapshot = liveConversionState.update(
                composingText,
                candidates: mainCandidates,
                firstClauseResults: conversionResult.firstClauseResults,
                convertTargetCursorPosition: composingText.convertTargetCursorPosition,
                convertTarget: composingText.convertTarget
            )
        } else {
            liveConversionState.stopComposition()
            self.liveConversionSnapshot = nil
        }
    }
}
