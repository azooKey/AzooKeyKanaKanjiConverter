package import Foundation

package struct AncoSessionPresentationContext: Sendable, Equatable {
    package enum Phase: Sendable, Equatable {
        case composing
        case previewing
        case selecting
    }

    package enum CandidateSource: String, Sendable, Equatable {
        case main
        case prediction
    }

    package init(
        phase: Phase = .composing,
        liveConversion: Bool = false,
        candidateSource: CandidateSource = .main,
        selectedIndex: Int? = nil
    ) {
        self.phase = phase
        self.liveConversion = liveConversion
        self.candidateSource = candidateSource
        self.selectedIndex = selectedIndex
    }

    package var phase: Phase
    package var liveConversion: Bool
    package var candidateSource: CandidateSource
    package var selectedIndex: Int?
}

package struct AncoSessionMarkedText: Sendable, Equatable, Hashable, Sequence {
    package enum FocusState: Sendable, Equatable, Hashable {
        case focused
        case unfocused
        case none
    }

    package struct Element: Sendable, Equatable, Hashable {
        package init(content: String, focus: FocusState) {
            self.content = content
            self.focus = focus
        }

        package var content: String
        package var focus: FocusState
    }

    package init(text: [Element], selectionRange: NSRange) {
        self.text = text
        self.selectionRange = selectionRange
    }

    package var text: [Element]
    package var selectionRange: NSRange

    package func makeIterator() -> Array<Element>.Iterator {
        self.text.makeIterator()
    }
}

package struct AncoSessionPresentation: Sendable {
    package init(
        candidates: [Candidate],
        selectedCandidate: Candidate?,
        markedText: AncoSessionMarkedText
    ) {
        self.candidates = candidates
        self.selectedCandidate = selectedCandidate
        self.markedText = markedText
    }

    package var candidates: [Candidate]
    package var selectedCandidate: Candidate?
    package var markedText: AncoSessionMarkedText
}

package enum AncoSessionPresenter {
    package static func present(
        session: AncoSession,
        context: AncoSessionPresentationContext
    ) -> AncoSessionPresentation {
        let candidates = self.candidates(session: session, source: context.candidateSource)
        let selectedCandidate = self.selectedCandidate(candidates: candidates, selectedIndex: context.selectedIndex)
        let markedText = self.markedText(session: session, context: context, candidates: candidates, selectedCandidate: selectedCandidate)
        return .init(candidates: candidates, selectedCandidate: selectedCandidate, markedText: markedText)
    }

    private static func candidates(
        session: AncoSession,
        source: AncoSessionPresentationContext.CandidateSource
    ) -> [Candidate] {
        switch source {
        case .main:
            session.lastMainCandidates
        case .prediction:
            session.lastPredictionCandidates
        }
    }

    private static func selectedCandidate(candidates: [Candidate], selectedIndex: Int?) -> Candidate? {
        guard let selectedIndex, candidates.indices.contains(selectedIndex) else {
            return nil
        }
        return candidates[selectedIndex]
    }

    private static func markedText(
        session: AncoSession,
        context: AncoSessionPresentationContext,
        candidates: [Candidate],
        selectedCandidate: Candidate?
    ) -> AncoSessionMarkedText {
        switch context.phase {
        case .composing:
            let text: String
            if context.liveConversion,
               context.candidateSource == .main,
               session.composingText.convertTarget.count > 1,
               let firstCandidate = session.lastMainCandidates.first {
                text = firstCandidate.text
            } else {
                text = session.composingText.convertTarget
            }
            return .init(
                text: [.init(content: text, focus: .none)],
                selectionRange: NSRange(location: NSNotFound, length: 0)
            )

        case .previewing:
            if let firstCandidate = session.lastMainCandidates.first,
               session.composingText.isWholeComposingText(composingCount: firstCandidate.composingCount) {
                return .init(
                    text: [.init(content: firstCandidate.text, focus: .none)],
                    selectionRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            return .init(
                text: [.init(content: session.composingText.convertTarget, focus: .none)],
                selectionRange: NSRange(location: NSNotFound, length: 0)
            )

        case .selecting:
            guard let selectedCandidate else {
                return .init(
                    text: [.init(content: session.composingText.convertTarget, focus: .none)],
                    selectionRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            var afterComposingText = session.composingText
            afterComposingText.prefixComplete(composingCount: selectedCandidate.composingCount)
            return .init(
                text: [
                    .init(content: selectedCandidate.text, focus: .focused),
                    .init(content: afterComposingText.convertTarget, focus: .unfocused)
                ],
                selectionRange: NSRange(location: selectedCandidate.text.count, length: 0)
            )
        }
    }
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var composingText = self
        composingText.prefixComplete(composingCount: composingCount)
        return composingText.isEmpty
    }
}
