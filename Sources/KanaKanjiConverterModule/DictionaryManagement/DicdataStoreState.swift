//
//  DicdataStoreState.swift
//  AzooKeyKanaKanjiConverter
//

import Foundation
import SwiftUtils

/// Session-scoped, mutable state for dictionary access and learning.
/// This bundles dynamic user dictionary and the session-local LearningManager.
package final class DicdataStoreState {

    init() {
        self.dynamicUserDict = []
        self.learningManager = LearningManager(configuration: nil)
    }

    private(set) var dynamicUserDict: [DicdataElement]
    var keyboardLanguage: KeyboardLanguage = .ja_JP
    let learningManager: LearningManager

    func setDynamicUserDictionary(_ dicdata: [DicdataElement]) {
        self.dynamicUserDict = dicdata
        self.dynamicUserDict.mutatingForEach { element in
            element.metadata = .isFromUserDictionary
        }
    }

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
