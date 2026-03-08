@testable import KanaKanjiConverterModule
import XCTest

final class AncoSessionCoreEventTests: XCTestCase {
    private func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 5,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )
    }

    func testSendInsertDeleteAndMoveCursorUpdatesComposingText() {
        let converter = KanaKanjiConverter.withoutDictionary()
        var core = AncoSessionCore(
            converter: converter,
            configuration: .init(requestOptions: self.requestOptions())
        )

        core.send(AncoSessionCore.Event.insert("かな", inputStyle: .direct))
        core.send(AncoSessionCore.Event.moveCursor(-1))
        core.send(AncoSessionCore.Event.deleteBackward(1))
        core.send(AncoSessionCore.Event.insert("き", inputStyle: .direct))

        XCTAssertEqual(core.snapshot.composingText.convertTarget, "きな")
        XCTAssertEqual(core.snapshot.composingText.convertTargetCursorPosition, 1)
    }

    func testSendInsertCompositionSeparatorPreservesSeparatorElement() {
        let converter = KanaKanjiConverter.withoutDictionary()
        var core = AncoSessionCore(
            converter: converter,
            configuration: .init(requestOptions: self.requestOptions())
        )

        core.send(AncoSessionCore.Event.insert("かな", inputStyle: .direct))
        core.send(AncoSessionCore.Event.insertCompositionSeparator(inputStyle: .direct))

        XCTAssertEqual(core.snapshot.composingText.input.last?.piece, .compositionSeparator)
    }
}
