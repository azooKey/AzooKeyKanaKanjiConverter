import Foundation
@_exported public import KanaKanjiConverterModule

public extension DicdataStore {
    static func withDefaultDictionary(preloadDictionary: Bool = false, maxCachedLOUDSBytes: Int? = nil) -> Self {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        let dictionaryDirectory = Bundle.module.bundleURL.appendingPathComponent("Dictionary", isDirectory: true)
        #elseif os(macOS)
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #else
        let dictionaryDirectory = Bundle.module.resourceURL!.appendingPathComponent("Dictionary", isDirectory: true)
        #endif

        return .init(dictionaryURL: dictionaryDirectory, preloadDictionary: preloadDictionary, maxCachedLOUDSBytes: maxCachedLOUDSBytes)
    }
}

public extension KanaKanjiConverter {
    static func withDefaultDictionary(preloadDictionary: Bool = false, maxCachedLOUDSBytes: Int? = nil) -> Self {
        .init(dicdataStore: .withDefaultDictionary(preloadDictionary: preloadDictionary, maxCachedLOUDSBytes: maxCachedLOUDSBytes))
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
