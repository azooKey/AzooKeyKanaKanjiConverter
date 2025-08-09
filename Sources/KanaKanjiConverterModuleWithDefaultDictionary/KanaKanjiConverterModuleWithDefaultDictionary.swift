public import Foundation
@_exported public import KanaKanjiConverterModule

public extension ConvertRequestOptions {
    static func withDefaultDictionary(
        N_best: Int = 10,
        needTypoCorrection: Bool? = nil,
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
        textReplacer: TextReplacer = .withDefaultEmojiDictionary(),
        preloadDictionary: Bool = false,
        metadata: ConvertRequestOptions.Metadata?
    ) -> Self {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        let dictionaryDirectory = Bundle.module.bundleURL.appendingPathComponent("Dictionary", isDirectory: true)
        #elseif os(macOS)
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #else
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #endif

        var specialCandidateProviders = [any SpecialCandidateProvider]()
        if typographyLetterCandidate {
            specialCandidateProviders.append(.typography)
        }
        if unicodeCandidate {
            specialCandidateProviders.append(.unicode)
        }
        specialCandidateProviders.append(.emailAddress)
        specialCandidateProviders.append(.timeExpression)
        specialCandidateProviders.append(.calendar)
        specialCandidateProviders.append(.version)
        specialCandidateProviders.append(.commaSeparatedNumber)

        return Self(
            N_best: N_best,
            needTypoCorrection: needTypoCorrection,
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: keyboardLanguage,
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
            specialCandidateProviders: specialCandidateProviders,
            zenzaiMode: zenzaiMode,
            preloadDictionary: preloadDictionary,
            metadata: metadata
        )
    }
}

public extension KanaKanjiConverter {
    static func withDefaultDictionary(
        memoryDirectoryURL: URL? = nil,
        userConfigurationDirectoryURL: URL? = nil,
        preloadDictionary: Bool = false,
    ) -> Self {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        let dictionaryDirectory = Bundle.module.bundleURL.appendingPathComponent("Dictionary", isDirectory: true)
        #elseif os(macOS)
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #else
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #endif
        return .init(
            dicdataLocation: .init(
                dictionaryResourceURL: dictionaryDirectory,
                memoryDirectoryURL: memoryDirectoryURL ?? .temporaryDirectory,
                userConfigurationDirectoryURL: userConfigurationDirectoryURL ?? .temporaryDirectory
            ),
            preloadDictionary: preloadDictionary
        )
    }
}

public extension TextReplacer {
    static func withDefaultEmojiDictionary() -> Self {
        self.init {
            let directoryName = "EmojiDictionary"
            #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            let directory = Bundle.module.bundleURL.appendingPathComponent(directoryName, isDirectory: true)
            return if #available(iOS 18.4, *) {
                directory.appendingPathComponent("emoji_all_E16.0.txt", isDirectory: false)
            } else if #available(iOS 17.4, *) {
                directory.appendingPathComponent("emoji_all_E15.1.txt", isDirectory: false)
            } else if #available(iOS 16.4, *) {
                directory.appendingPathComponent("emoji_all_E15.0.txt", isDirectory: false)
            } else if #available(iOS 15.4, *) {
                directory.appendingPathComponent("emoji_all_E14.0.txt", isDirectory: false)
            } else {
                directory.appendingPathComponent("emoji_all_E13.1.txt", isDirectory: false)
            }
            #elseif os(macOS)
            let directory = Bundle.module.resourceURL!.appendingPathComponent(directoryName, isDirectory: true)
            return if #available(macOS 15.3, *) {
                directory.appendingPathComponent("emoji_all_E16.0.txt", isDirectory: false)
            } else if #available(macOS 14.4, *) {
                directory.appendingPathComponent("emoji_all_E15.1.txt", isDirectory: false)
            } else {
                directory.appendingPathComponent("emoji_all_E15.0.txt", isDirectory: false)
            }
            #else
            return Bundle.module.resourceURL!
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent("emoji_all_E16.0.txt", isDirectory: false)
            #endif
        }
    }
}
