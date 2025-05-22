import XCTest
@testable import KanaKanjiConverterModule

final class KanaKanjiConverterSessionTests: XCTestCase {
    private func makeDirectInput(direct input: String) -> ComposingText {
        ComposingText(
            convertTargetCursorPosition: input.count,
            input: input.map { .init(character: $0, inputStyle: .direct) },
            convertTarget: input
        )
    }

    private func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 5,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            typographyLetterCandidate: false,
            unicodeCandidate: true,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            dictionaryResourceURL: Bundle(for: type(of: self)).bundleURL.appendingPathComponent("DictionaryMock", isDirectory: true),
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            metadata: nil
        )
    }

    func testSessionMatchesConverter() async throws {
        let converter = KanaKanjiConverter()
        let session = converter.startSession()
        let input = makeDirectInput(direct: "U+3042")
        let options = requestOptions()

        let directResult = await converter.requestCandidatesAsync(input, options: options)
        let sessionResult = await session.requestCandidatesAsync(input, options: options)

        XCTAssertEqual(directResult.mainResults.map(\.text), sessionResult.mainResults.map(\.text))
        XCTAssertEqual(directResult.firstClauseResults.map(\.text), sessionResult.firstClauseResults.map(\.text))
    }
}
