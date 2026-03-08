import SwiftUtils

public struct LiveConversionConfig: Sendable, Equatable {
    public var enabled: Bool
    public var autoCommitThreshold: Int?

    public init(enabled: Bool = false, autoCommitThreshold: Int? = nil) {
        self.enabled = enabled
        self.autoCommitThreshold = autoCommitThreshold
    }
}

public struct LiveConversionSnapshot: Sendable {
    public var displayedText: String
    public var currentCandidate: Candidate?
    public var autoCommitCandidate: Candidate?
    public var firstClauseHistory: [Candidate]

    public init(
        displayedText: String,
        currentCandidate: Candidate?,
        autoCommitCandidate: Candidate?,
        firstClauseHistory: [Candidate]
    ) {
        self.displayedText = displayedText
        self.currentCandidate = currentCandidate
        self.autoCommitCandidate = autoCommitCandidate
        self.firstClauseHistory = firstClauseHistory
    }
}

public struct LiveConversionState: Sendable {
    public var config: LiveConversionConfig
    public private(set) var currentCandidate: Candidate?
    private var headClauseCandidateHistories: [[Candidate]] = []

    public init(config: LiveConversionConfig = .init()) {
        self.config = config
    }

    public mutating func stopComposition() {
        self.currentCandidate = nil
        self.headClauseCandidateHistories = []
    }

    public mutating func updateAfterFirstClauseCompletion() {
        self.currentCandidate = nil
        if !self.headClauseCandidateHistories.isEmpty {
            self.headClauseCandidateHistories.removeFirst()
        }
    }

    public var autoCommitCandidate: Candidate? {
        guard
            let threshold = self.config.autoCommitThreshold,
            threshold > 0,
            let history = self.headClauseCandidateHistories.first,
            history.count >= threshold
        else {
            return nil
        }

        let texts = Set(history.suffix(threshold).map(\.text))
        guard texts.count == 1 else {
            return nil
        }
        return history.last
    }

    public var firstClauseHistory: [Candidate] {
        self.headClauseCandidateHistories.first ?? []
    }

    public mutating func update(
        _ composingText: ComposingText,
        candidates: [Candidate],
        firstClauseResults: [Candidate],
        convertTargetCursorPosition: Int,
        convertTarget: String
    ) -> LiveConversionSnapshot {
        guard self.config.enabled else {
            self.stopComposition()
            return LiveConversionSnapshot(
                displayedText: convertTargetCursorPosition > 0 ? convertTarget : "",
                currentCandidate: nil,
                autoCommitCandidate: nil,
                firstClauseHistory: []
            )
        }

        var candidate: Candidate
        if convertTargetCursorPosition > 1,
           let firstCandidate = candidates.first(where: { $0.data.map(\.ruby).joined().count == convertTarget.count }) {
            candidate = firstCandidate
        } else {
            candidate = .init(
                text: convertTarget,
                value: 0,
                composingCount: .inputCount(composingText.input.count),
                lastMid: MIDData.一般.mid,
                data: [
                    .init(
                        ruby: convertTarget.toKatakana(),
                        cid: CIDData.一般名詞.cid,
                        mid: MIDData.一般.mid,
                        value: 0
                    )
                ]
            )
        }
        Self.adjustCandidate(candidate: &candidate)

        let displayedText: String
        if convertTargetCursorPosition > 0 {
            self.setCurrentCandidate(candidate, firstClauseCandidates: firstClauseResults)
            displayedText = candidate.text
        } else {
            self.currentCandidate = nil
            displayedText = ""
        }

        return LiveConversionSnapshot(
            displayedText: displayedText,
            currentCandidate: self.currentCandidate,
            autoCommitCandidate: self.autoCommitCandidate,
            firstClauseHistory: self.firstClauseHistory
        )
    }

    private mutating func setCurrentCandidate(_ candidate: Candidate, firstClauseCandidates: [Candidate]) {
        let diff: Int
        if let currentCandidate {
            let lastLength = currentCandidate.data.reduce(0) { $0 + $1.ruby.count }
            let newLength = candidate.data.reduce(0) { $0 + $1.ruby.count }
            diff = newLength - lastLength
        } else {
            diff = 1
        }
        self.currentCandidate = candidate

        if diff > 0 {
            self.updateHistories(newCandidate: candidate, firstClauseCandidates: firstClauseCandidates)
        } else if diff < 0 {
            self.headClauseCandidateHistories = self.headClauseCandidateHistories.map { history in
                var history = history
                _ = history.popLast()
                return history
            }
        } else {
            self.headClauseCandidateHistories = self.headClauseCandidateHistories.map { history in
                var history = history
                _ = history.popLast()
                return history
            }
            self.updateHistories(newCandidate: candidate, firstClauseCandidates: firstClauseCandidates)
        }
    }

    private mutating func updateHistories(newCandidate: Candidate, firstClauseCandidates: [Candidate]) {
        var data = ArraySlice(newCandidate.data)
        var count = 0
        while !data.isEmpty {
            var clause = Candidate.makePrefixClauseCandidate(data: data)
            if count == 0,
               let first = firstClauseCandidates.first(where: { $0.text == clause.text }) {
                clause.composingCount = first.composingCount
            }
            if self.headClauseCandidateHistories.count <= count {
                self.headClauseCandidateHistories.append([clause])
            } else {
                self.headClauseCandidateHistories[count].append(clause)
            }
            data = data.dropFirst(clause.data.count)
            count += 1
        }
    }

    private static func adjustCandidate(candidate: inout Candidate) {
        guard let last = candidate.data.last, last.ruby.count < 2 else {
            return
        }
        let rubyHiragana = last.ruby.toHiragana()
        let newElement = DicdataElement(
            word: rubyHiragana,
            ruby: last.ruby,
            lcid: last.lcid,
            rcid: last.rcid,
            mid: last.mid,
            value: last.adjustedData(0).value(),
            adjust: last.adjust
        )
        var newCandidate = Candidate(
            text: candidate.data.dropLast().map(\.word).joined() + rubyHiragana,
            value: candidate.value,
            composingCount: candidate.composingCount,
            lastMid: candidate.lastMid,
            data: Array(candidate.data.dropLast()) + [newElement]
        )
        newCandidate.parseTemplate()
        candidate = newCandidate
    }
}
