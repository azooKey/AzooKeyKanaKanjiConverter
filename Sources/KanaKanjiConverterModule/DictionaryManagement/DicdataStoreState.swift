import Foundation
import SwiftUtils

package final class DicdataStoreState {
    let dictionaryURL: URL

    init(dictionaryURL: URL) {
        self.dictionaryURL = dictionaryURL
        self.learningMemoryManager = LearningManager(dictionaryURL: dictionaryURL)
    }

    var keyboardLanguage: KeyboardLanguage = .ja_JP
    private(set) var dynamicUserDictionary: [DicdataElement] = []
    private(set) var dynamicUserShortcuts: [DicdataElement] = []
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

    func importDynamicUserDictionary(_ dicdata: [DicdataElement], shortcuts: [DicdataElement] = []) {
        self.dynamicUserDictionary = dicdata
        self.dynamicUserDictionary.mutatingForEach {
            $0.metadata = .isFromUserDictionary
        }
        self.dynamicUserShortcuts = shortcuts
        self.dynamicUserShortcuts.mutatingForEach {
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

struct DicdataStoreStateSnapshot: Sendable {
    var dictionaryURL: URL
    var keyboardLanguage: KeyboardLanguage
    var dynamicUserDictionary: [DicdataElement]
    var dynamicUserShortcuts: [DicdataElement]
    var userDictionaryURL: URL?
    var userDictionaryHasLoaded: Bool
    var userDictionaryLOUDS: LOUDS?
    var userShortcutsHasLoaded: Bool
    var userShortcutsLOUDS: LOUDS?
    var memoryHasLoaded: Bool
    var memoryLOUDS: LOUDS?
    var learningSnapshot: LearningManager.Snapshot
}

extension DicdataStoreState {
    func snapshot() -> DicdataStoreStateSnapshot {
        DicdataStoreStateSnapshot(
            dictionaryURL: self.dictionaryURL,
            keyboardLanguage: self.keyboardLanguage,
            dynamicUserDictionary: self.dynamicUserDictionary,
            dynamicUserShortcuts: self.dynamicUserShortcuts,
            userDictionaryURL: self.userDictionaryURL,
            userDictionaryHasLoaded: self.userDictionaryHasLoaded,
            userDictionaryLOUDS: self.userDictionaryLOUDS,
            userShortcutsHasLoaded: self.userShortcutsHasLoaded,
            userShortcutsLOUDS: self.userShortcutsLOUDS,
            memoryHasLoaded: self.memoryHasLoaded,
            memoryLOUDS: self.memoryLOUDS,
            learningSnapshot: self.learningMemoryManager.snapshot()
        )
    }

    convenience init(snapshot: DicdataStoreStateSnapshot) {
        self.init(dictionaryURL: snapshot.dictionaryURL)
        self.keyboardLanguage = snapshot.keyboardLanguage
        self.dynamicUserDictionary = snapshot.dynamicUserDictionary
        self.dynamicUserShortcuts = snapshot.dynamicUserShortcuts
        self.userDictionaryURL = snapshot.userDictionaryURL
        self.userDictionaryHasLoaded = snapshot.userDictionaryHasLoaded
        self.userDictionaryLOUDS = snapshot.userDictionaryLOUDS
        self.userShortcutsHasLoaded = snapshot.userShortcutsHasLoaded
        self.userShortcutsLOUDS = snapshot.userShortcutsLOUDS
        self.memoryHasLoaded = snapshot.memoryHasLoaded
        self.memoryLOUDS = snapshot.memoryLOUDS
        self.learningMemoryManager.apply(snapshot: snapshot.learningSnapshot)
    }
}
