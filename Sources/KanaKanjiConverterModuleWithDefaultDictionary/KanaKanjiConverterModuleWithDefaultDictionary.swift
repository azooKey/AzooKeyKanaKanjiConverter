@_exported import KanaKanjiConverterModule
import Foundation

public extension ConvertRequestOptions {
    static func withDefaultDictionary(
        N_best: Int = 10,
        requireJapanesePrediction: Bool,
        requireEnglishPrediction: Bool,
        keyboardLanguage: KeyboardLanguage,
        typographyLetterCandidate: Bool = false,
        unicodeCandidate: Bool = true,
        englishCandidateInRoman2KanaInput: Bool = false,
        fullWidthRomanCandidate: Bool = false,
        halfWidthKanaCandidate: Bool = false,
        learningType: LearningType,
        maxMemoryCount: Int = 65536,
        shouldResetMemory: Bool = false,
        memoryDirectoryURL: URL,
        sharedContainerURL: URL,
        zenzaiMode: ZenzaiMode = .off,
        textReplacer: TextReplacer = TextReplacer(withDefaultEmojiDictionary: true),
        metadata: ConvertRequestOptions.Metadata?
    ) -> Self {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        let dictionaryDirectory = Bundle.module.bundleURL.appendingPathComponent("Dictionary", isDirectory: true)
        #elseif os(macOS)
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #else
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #endif
        return Self(
            N_best: N_best,
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: keyboardLanguage,
            typographyLetterCandidate: typographyLetterCandidate,
            unicodeCandidate: unicodeCandidate,
            englishCandidateInRoman2KanaInput: englishCandidateInRoman2KanaInput,
            fullWidthRomanCandidate: fullWidthRomanCandidate,
            halfWidthKanaCandidate: halfWidthKanaCandidate,
            learningType: learningType,
            maxMemoryCount: maxMemoryCount,
            shouldResetMemory: shouldResetMemory,
            dictionaryResourceURL: dictionaryDirectory,
            memoryDirectoryURL: memoryDirectoryURL,
            sharedContainerURL: sharedContainerURL,
            textReplacer: textReplacer,
            zenzaiMode: zenzaiMode,
            metadata: metadata
        )
    }
}


public extension TextReplacer {
    init(withDefaultEmojiDictionary: Bool) {
        assert(withDefaultEmojiDictionary, "withDefaultEmojiDictionary must be true!")
        self.init(emojiDataProvider: {
            #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            Bundle.module.bundleURL.appendingPathComponent("Dictionary", isDirectory: true)
            #elseif os(macOS)
            Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
            #else
            Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
            #endif
            }
        )
    }
}
