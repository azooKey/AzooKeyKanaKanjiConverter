import Foundation
import SwiftUtils

package final class DicdataStoreState {
    init(dictionaryURL: URL) {
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
    private var staticConversionCacheEligibility: Bool?

    func updateUserDictionaryURL(_ newURL: URL, forceReload: Bool) {
        if self.userDictionaryURL != newURL || forceReload {
            self.userDictionaryURL = newURL
            self.staticConversionCacheEligibility = nil
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
            self.staticConversionCacheEligibility = nil
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
        self.staticConversionCacheEligibility = nil
        self.dynamicUserDictionary = dicdata
        self.dynamicUserDictionary.mutatingForEach {
            $0.metadata = .isFromUserDictionary
        }
        self.dynamicUserShortcuts = shortcuts
        self.dynamicUserShortcuts.mutatingForEach {
            $0.metadata = .isFromUserDictionary
        }
    }

    /// 辞書状態を跨いで変換結果を共有しても安全かを返す。
    ///
    /// 学習・動的辞書・永続ユーザ辞書のいずれかが有効な場合は、同じ入力でも
    /// 候補列が変わり得るため共有しない。
    func canShareStaticConversionResults() -> Bool {
        if let staticConversionCacheEligibility {
            return staticConversionCacheEligibility
        }
        guard self.learningMemoryManager.config.learningType == .nothing,
              self.dynamicUserDictionary.isEmpty,
              self.dynamicUserShortcuts.isEmpty else {
            self.staticConversionCacheEligibility = false
            return false
        }
        guard let userDictionaryURL else {
            self.staticConversionCacheEligibility = true
            return true
        }
        let userDictionaryFiles = [
            "user.loudschars2",
            "user.louds",
            "user_shortcuts.loudschars2",
            "user_shortcuts.louds"
        ]
        let hasUserDictionaryFile = userDictionaryFiles.contains {
            FileManager.default.fileExists(
                atPath: userDictionaryURL.appendingPathComponent($0).path
            )
        }
        self.staticConversionCacheEligibility = !hasUserDictionaryFile
        return !hasUserDictionaryFile
    }

    private func resetMemoryLOUDSCache() {
        self.memoryLOUDS = nil
        self.memoryHasLoaded = false
    }

    func saveMemory() {
        if self.learningMemoryManager.save() {
            self.resetMemoryLOUDSCache()
        }
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
