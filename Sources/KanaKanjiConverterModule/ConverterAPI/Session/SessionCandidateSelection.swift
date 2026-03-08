public enum SessionCandidateSelectionResult: Sendable, Equatable {
    case compositionContinues
    case compositionEnded
}

public extension KanaKanjiConverter {
    @discardableResult
    func completePrefixCandidate(
        _ candidate: Candidate,
        composingText: inout ComposingText
    ) -> SessionCandidateSelectionResult {
        self.updateLearningData(candidate)
        composingText.prefixComplete(composingCount: candidate.composingCount)
        guard !composingText.isEmpty else {
            self.stopComposition()
            return .compositionEnded
        }
        self.setCompletedData(candidate)
        return .compositionContinues
    }
}
