import Foundation
import SwiftUtils

public struct AncoSessionCore {
    public enum Event: Sendable {
        case insert(String, inputStyle: InputStyle)
        case insertElements([ComposingText.InputElement])
        case insertCompositionSeparator(inputStyle: InputStyle)
        case deleteBackward(Int)
        case deleteForward(Int)
        case moveCursor(Int)
        case stopComposition
        case reset
    }

    public enum CandidateRequestTarget: Sendable {
        case composingText
        case prefixToCursorPosition
    }

    public struct Configuration: Sendable {
        public var requestOptions: ConvertRequestOptions
        public var inputStyle: InputStyle
        public var liveConversion: LiveConversionConfig

        public init(
            requestOptions: ConvertRequestOptions,
            inputStyle: InputStyle = .direct,
            liveConversion: LiveConversionConfig = .init(enabled: false)
        ) {
            self.requestOptions = requestOptions
            self.inputStyle = inputStyle
            self.liveConversion = liveConversion
        }
    }

    public struct Outputs: Sendable {
        public var conversionResult: ConversionResult?
        public var mainCandidates: [Candidate]
        public var predictionCandidates: [Candidate]
        public var firstClauseCandidates: [Candidate]
        public var liveConversionSnapshot: LiveConversionSnapshot?

        public init(
            conversionResult: ConversionResult? = nil,
            mainCandidates: [Candidate] = [],
            predictionCandidates: [Candidate] = [],
            firstClauseCandidates: [Candidate] = [],
            liveConversionSnapshot: LiveConversionSnapshot? = nil
        ) {
            self.conversionResult = conversionResult
            self.mainCandidates = mainCandidates
            self.predictionCandidates = predictionCandidates
            self.firstClauseCandidates = firstClauseCandidates
            self.liveConversionSnapshot = liveConversionSnapshot
        }
    }

    public struct Snapshot: Sendable {
        public var composingText: ComposingText
        public var leftSideContext: String
        public var configuration: Configuration
        public var outputs: Outputs

        public init(
            composingText: ComposingText,
            leftSideContext: String,
            configuration: Configuration,
            outputs: Outputs
        ) {
            self.composingText = composingText
            self.leftSideContext = leftSideContext
            self.configuration = configuration
            self.outputs = outputs
        }
    }

    public enum CandidateSelectionResult: Sendable, Equatable {
        case compositionEnded
        case compositionContinues
    }

    private let converter: KanaKanjiConverter
    private var liveConversionState: LiveConversionState

    public private(set) var composingText: ComposingText
    public private(set) var leftSideContext: String
    public private(set) var configuration: Configuration
    public private(set) var outputs: Outputs

    public init(
        converter: KanaKanjiConverter,
        configuration: Configuration,
        composingText: ComposingText = .init(),
        leftSideContext: String = ""
    ) {
        self.converter = converter
        self.configuration = configuration
        self.composingText = composingText
        self.leftSideContext = leftSideContext
        self.outputs = .init()
        self.liveConversionState = .init(config: configuration.liveConversion)
    }

    public var snapshot: Snapshot {
        .init(
            composingText: self.composingText,
            leftSideContext: self.leftSideContext,
            configuration: self.configuration,
            outputs: self.outputs
        )
    }

    public mutating func apply(
        composingText: ComposingText? = nil,
        leftSideContext: String? = nil,
        configuration: Configuration? = nil
    ) {
        if let composingText {
            self.composingText = composingText
        }
        if let leftSideContext {
            self.leftSideContext = leftSideContext
        }
        if let configuration {
            self.configuration = configuration
        }
        self.liveConversionState.config = self.configuration.liveConversion
    }

    public mutating func reset() {
        self.composingText.stopComposition()
        self.leftSideContext = ""
        self.outputs = .init()
        self.liveConversionState.stopComposition()
    }

    public mutating func stopComposition() {
        self.composingText.stopComposition()
        self.outputs = .init()
        self.liveConversionState.stopComposition()
        self.converter.stopComposition()
    }

    @discardableResult
    public mutating func send(_ event: Event) -> Snapshot {
        switch event {
        case let .insert(text, inputStyle):
            self.composingText.insertAtCursorPosition(text, inputStyle: inputStyle)
            self.clearOutputsAfterEditing()
        case let .insertElements(elements):
            self.composingText.insertAtCursorPosition(elements)
            self.clearOutputsAfterEditing()
        case let .insertCompositionSeparator(inputStyle):
            self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
            self.clearOutputsAfterEditing()
        case let .deleteBackward(count):
            self.composingText.deleteBackwardFromCursorPosition(count: count)
            self.clearOutputsAfterEditing()
        case let .deleteForward(count):
            self.composingText.deleteForwardFromCursorPosition(count: count)
            self.clearOutputsAfterEditing()
        case let .moveCursor(count):
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
            self.outputs = .init()
        case .stopComposition:
            self.stopComposition()
        case .reset:
            self.reset()
        }
        return self.snapshot
    }

    @discardableResult
    public mutating func requestCandidates(
        for target: CandidateRequestTarget = .composingText,
        filteredByWholeMatchInput wholeMatchInput: String? = nil
    ) -> Outputs {
        let requestComposingText: ComposingText
        switch target {
        case .composingText:
            requestComposingText = self.composingText
        case .prefixToCursorPosition:
            requestComposingText = self.composingText.prefixToCursorPosition()
        }
        let result = self.converter.requestCandidates(
            requestComposingText,
            options: self.requestOptions(leftSideContext: self.leftSideContext)
        )
        return self.projectOutputs(
            conversionResult: result,
            using: requestComposingText,
            filteredByWholeMatchInput: wholeMatchInput
        )
    }

    @discardableResult
    public mutating func projectOutputs(
        conversionResult: ConversionResult,
        using composingText: ComposingText? = nil,
        filteredByWholeMatchInput wholeMatchInput: String? = nil
    ) -> Outputs {
        let projectedComposingText = composingText ?? self.composingText
        let mainCandidates: [Candidate]
        if let wholeMatchInput {
            mainCandidates = conversionResult.mainResults.filter {
                $0.data.reduce(into: "", {$0.append(contentsOf: $1.ruby)}) == wholeMatchInput.toKatakana()
            }
        } else {
            mainCandidates = conversionResult.mainResults
        }
        let projected = SessionCandidateResults(
            conversionResult: conversionResult,
            composingText: projectedComposingText,
            liveConversionState: &self.liveConversionState,
            mainCandidates: mainCandidates
        )
        self.outputs = .init(
            conversionResult: conversionResult,
            mainCandidates: projected.mainCandidates,
            predictionCandidates: projected.predictionCandidates,
            firstClauseCandidates: conversionResult.firstClauseResults,
            liveConversionSnapshot: projected.liveConversionSnapshot
        )
        return self.outputs
    }

    @discardableResult
    public mutating func selectCandidate(_ candidate: Candidate) -> CandidateSelectionResult {
        let result = self.converter.completePrefixCandidate(candidate, composingText: &self.composingText)
        self.leftSideContext += candidate.text
        switch result {
        case .compositionEnded:
            self.composingText.stopComposition()
            self.outputs = .init()
            self.liveConversionState.stopComposition()
            return .compositionEnded
        case .compositionContinues:
            self.liveConversionState.updateAfterFirstClauseCompletion()
            return .compositionContinues
        }
    }

    private func requestOptions(leftSideContext: String?) -> ConvertRequestOptions {
        var options = self.configuration.requestOptions
        switch options.zenzaiMode.versionDependentMode {
        case let .v2(mode):
            options.zenzaiMode.versionDependentMode = .v2(.init(
                profile: mode.profile,
                leftSideContext: leftSideContext,
                maxLeftSideContextLength: mode.maxLeftSideContextLength
            ))
        case let .v3(mode):
            options.zenzaiMode.versionDependentMode = .v3(.init(
                profile: mode.profile,
                topic: mode.topic,
                style: mode.style,
                preference: mode.preference,
                leftSideContext: leftSideContext,
                maxLeftSideContextLength: mode.maxLeftSideContextLength
            ))
        }
        return options
    }

    private mutating func clearOutputsAfterEditing() {
        self.outputs = .init()
        guard self.composingText.isEmpty else {
            return
        }
        self.liveConversionState.stopComposition()
        self.converter.stopComposition()
    }
}
