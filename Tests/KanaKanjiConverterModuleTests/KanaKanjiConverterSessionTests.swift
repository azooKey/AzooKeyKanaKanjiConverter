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

        XCTAssertEqual(directResult.mainResults.first?.text, sessionResult.mainResults.first?.text)
        XCTAssertEqual(directResult.firstClauseResults.first?.text, sessionResult.firstClauseResults.first?.text)
    }

    /// Verify that session can request candidates asynchronously and match converter result.
    func testSessionRequestCandidates() async throws {
        let converter = KanaKanjiConverter()
        let session = converter.startSession()
        let options = requestOptions()
        let input = makeDirectInput(direct: "U+3042")

        let directResult = await converter.requestCandidatesAsync(input, options: options)
        let sessionResult = await session.requestCandidatesAsync(input, options: options)

        XCTAssertEqual(directResult.mainResults.map(\.text), sessionResult.mainResults.map(\.text))
        XCTAssertEqual(directResult.firstClauseResults.map(\.text), sessionResult.firstClauseResults.map(\.text))
    }

    /// Ensure multiple sessions operate independently without interfering states.
    func testMultipleSessionsIndependently() async throws {
        let converter = KanaKanjiConverter()
        let session1 = converter.startSession()
        let session2 = converter.startSession()
        let options = requestOptions()

        var input1 = makeDirectInput(direct: "U+3042")
        var input2 = makeDirectInput(direct: "U+30A2")

        async let r1 = session1.requestCandidatesAsync(input1, options: options)
        async let r2 = session2.requestCandidatesAsync(input2, options: options)

        let direct1 = await converter.requestCandidatesAsync(input1, options: options)
        let direct2 = await converter.requestCandidatesAsync(input2, options: options)
        let result1 = await r1
        let result2 = await r2

        XCTAssertEqual(result1.mainResults.first?.text, direct1.mainResults.first?.text)
        XCTAssertEqual(result2.mainResults.first?.text, direct2.mainResults.first?.text)

        input1 = makeDirectInput(direct: "U+3044")
        input2 = makeDirectInput(direct: "U+30A4")

        async let r3 = session1.requestCandidatesAsync(input1, options: options)
        async let r4 = session2.requestCandidatesAsync(input2, options: options)

        let direct3 = await converter.requestCandidatesAsync(input1, options: options)
        let direct4 = await converter.requestCandidatesAsync(input2, options: options)
        let result3 = await r3
        let result4 = await r4

        XCTAssertEqual(result3.mainResults.first?.text, direct3.mainResults.first?.text)
        XCTAssertEqual(result4.mainResults.first?.text, direct4.mainResults.first?.text)
    }

    func testParallelSessionsRaceFree() async throws {
        let converter = KanaKanjiConverter()
        let options = requestOptions()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                let input = makeDirectInput(direct: "U+3042")
                group.addTask { @Sendable [converter, input] in
                    let session = converter.startSession()
                    var localInput = input
                    _ = await session.requestCandidatesAsync(localInput, options: options)
                }
            }
        }
    }
}
