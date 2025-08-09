//
//  DicdataStoreState.swift
//  AzooKeyKanaKanjiConverter
//

import Foundation

/// Session-scoped, mutable state for dictionary access and learning.
/// This bundles dynamic user dictionary and the session-local LearningManager.
package final class DicdataStoreState {

    init() {
        self.dynamicUserDict = []
        self.learningManager = LearningManager(configuration: nil)
    }

    var dynamicUserDict: [DicdataElement]
    var keyboardLanguage: KeyboardLanguage = .ja_JP
    let learningManager: LearningManager

    func save() {
        self.learningManager.save()
    }

    func forget(_ candidate: Candidate) {
        self.learningManager.forgetMemory(data: candidate.data)
    }

    func resetLearning() -> Bool {
        self.learningManager.reset()
    }
}
