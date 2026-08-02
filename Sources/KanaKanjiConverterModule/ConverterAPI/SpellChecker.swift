//
//  SpellChecker.swift
//
//
//  Created by ensan on 2023/05/20.
//

import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class SpellChecker {
    init() {}

    private final class CompletionCacheEntry {
        init(_ completions: [String]?) {
            self.completions = completions
        }

        let completions: [String]?
    }

    private final class CompletionCache: @unchecked Sendable {
        init() {
            self.storage.countLimit = 128
            self.storage.totalCostLimit = 1 * 1024 * 1024
        }

        let storage = NSCache<NSString, CompletionCacheEntry>()
    }

    /// OSの補完器は同じ接頭辞に対しても比較的高コストなため、複数の変換器で共有する。
    /// NSCacheによりメモリプレッシャー時は自動的に破棄される。
    private static let completionCache = CompletionCache()

    #if os(iOS) || os(tvOS) || os(visionOS)
    // UITextChecker is main-actor isolated on iOS-family platforms.
    // Use a static instance to avoid capturing `self` in main-actor closures.
    @MainActor private static let checker = UITextChecker()
    #elseif os(macOS)
    private let checker = NSSpellChecker.shared
    #endif

    func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]? {
        let cacheKey = "\(language)\u{0}\(range.location):\(range.length)\u{0}\(string)" as NSString
        if let cached = Self.completionCache.storage.object(forKey: cacheKey) {
            return cached.completions
        }
        let completions: [String]?
        #if os(iOS) || os(tvOS) || os(visionOS)
        if Thread.isMainThread {
            // Already on main thread: enter main-actor context synchronously.
            completions = MainActor.assumeIsolated {
                Self.checker.completions(
                    forPartialWordRange: range,
                    in: string,
                    language: language
                )
            }
        } else {
            // Hop to main thread synchronously and run in main-actor context.
            var result: [String]?
            DispatchQueue.main.sync {
                result = MainActor.assumeIsolated { Self.checker.completions(forPartialWordRange: range, in: string, language: language) }
            }
            completions = result
        }
        #elseif os(macOS)
        completions = checker.completions(
            forPartialWordRange: range,
            in: string,
            language: language,
            inSpellDocumentWithTag: 0
        )
        #else
        completions = nil
        #endif
        let cost = completions?.reduce(32) { $0 + 16 + $1.utf8.count } ?? 16
        Self.completionCache.storage.setObject(
            CompletionCacheEntry(completions),
            forKey: cacheKey,
            cost: cost
        )
        return completions
    }
}
