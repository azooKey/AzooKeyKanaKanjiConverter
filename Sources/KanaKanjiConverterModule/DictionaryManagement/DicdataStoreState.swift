import Foundation
import SwiftUtils

package final class DicdataStoreState {
    init(dictionaryURL: URL) {
        self.learningMemoryManager = LearningManager(dictionaryURL: dictionaryURL)
    }

    var keyboardLanguage: KeyboardLanguage = .ja_JP
    private(set) var dynamicUserDictionary: [DicdataElement] = []
    var learningMemoryManager: LearningManager

    var userDictionaryURL: URL?
    var memoryURL: URL? {
        self.learningMemoryManager.config.memoryURL
    }

    private(set) var userDictionaryHasLoaded: Bool = false
    private(set) var userDictionaryLOUDS: LOUDS?

    // user_shortcuts 辞書
    private(set) var userShortcutsHasLoaded: Bool = false
    private(set) var userShortcutsLOUDS: LOUDS?

    private(set) var memoryHasLoaded: Bool = false
    private(set) var memoryLOUDS: LOUDS?

    func updateUserDictionaryURL(_ newURL: URL, forceReload: Bool) {
        if self.userDictionaryURL != newURL || forceReload {
            self.userDictionaryURL = newURL
            self.userDictionaryLOUDS = nil
            self.userDictionaryHasLoaded = false
            self.userShortcutsLOUDS = nil
            self.userShortcutsHasLoaded = false
        }
    }

    func updateKeyboardLanguage(_ newLanguage: KeyboardLanguage) {
        self.keyboardLanguage = newLanguage
    }

    func updateLearningConfig(_ newConfig: LearningConfig) {
        if self.learningMemoryManager.config != newConfig {
            let updated = self.learningMemoryManager.updateConfig(newConfig)
            if updated {
                self.resetMemoryLOUDSCache()
            }
        }
    }

    func updateMemoryLOUDS(_ newLOUDS: LOUDS?) {
        self.memoryLOUDS = newLOUDS
        self.memoryHasLoaded = true
    }

    func updateUserDictionaryLOUDS(_ newLOUDS: LOUDS?) {
        self.userDictionaryLOUDS = newLOUDS
        self.userDictionaryHasLoaded = true
    }

    func updateUserShortcutsLOUDS(_ newLOUDS: LOUDS?) {
        self.userShortcutsLOUDS = newLOUDS
        self.userShortcutsHasLoaded = true
    }

    @available(*, deprecated, message: "This API is deprecated. Directly update the state instead.")
    func updateIfRequired(options: ConvertRequestOptions) {
        if options.keyboardLanguage != self.keyboardLanguage {
            self.keyboardLanguage = options.keyboardLanguage
        }
        self.updateUserDictionaryURL(options.sharedContainerURL, forceReload: false)
        let learningConfig = LearningConfig(learningType: options.learningType, maxMemoryCount: options.maxMemoryCount, memoryURL: options.memoryDirectoryURL)
        self.updateLearningConfig(learningConfig)
    }

    func importDynamicUserDictionary(_ dicdata: [DicdataElement]) {
        self.dynamicUserDictionary = dicdata
        self.dynamicUserDictionary.mutatingForEach {
            $0.metadata = .isFromUserDictionary
        }
    }

    private func resetMemoryLOUDSCache() {
        self.memoryLOUDS = nil
        self.memoryHasLoaded = false
    }

    func saveMemory() {
        self.learningMemoryManager.save()
        self.resetMemoryLOUDSCache()
    }

    func resetMemory() {
        self.learningMemoryManager.resetMemory()
        self.resetMemoryLOUDSCache()
    }

    func forgetMemory(_ candidate: Candidate) {
        self.learningMemoryManager.forgetMemory(data: candidate.data)
        self.resetMemoryLOUDSCache()
    }

    // 学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with previous: DicdataElement?) {
        // 学習対象外の候補は無視
        if !candidate.isLearningTarget {
            return
        }
        if let previous {
            self.learningMemoryManager.update(data: [previous] + candidate.data)
        } else {
            self.learningMemoryManager.update(data: candidate.data)
        }
    }
    // 予測変換に基づいて学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        // 学習対象外の候補は無視
        if !candidate.isLearningTarget {
            return
        }
        switch predictionCandidate.type {
        case .additional(data: let data):
            self.learningMemoryManager.update(data: candidate.data, updatePart: data)
        case .replacement(targetData: let targetData, replacementData: let replacementData):
            self.learningMemoryManager.update(data: candidate.data.dropLast(targetData.count), updatePart: replacementData)
        }
    }
}
