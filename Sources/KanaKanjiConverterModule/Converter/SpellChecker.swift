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

/// Spell checker utility isolated in its own actor.
actor SpellChecker {
    #if os(iOS) || os(tvOS) || os(visionOS)
    private let checker = UITextChecker()
    #elseif os(macOS)
    private let checker = NSSpellChecker.shared
    #endif

    func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return checker.completions(forPartialWordRange: range, in: string, language: language)
        #elseif os(macOS)
        return checker.completions(forPartialWordRange: range, in: string, language: language, inSpellDocumentWithTag: 0)
        #else
        return nil
        #endif
    }
}
