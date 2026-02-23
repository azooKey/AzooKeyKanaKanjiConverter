import Foundation
import SwiftUtils

enum ZenzPromptBuilder {
    private static let inputTag = "\u{EE00}"
    private static let outputTag = "\u{EE01}"
    private static let contextTag = "\u{EE02}"

    private static func trimmedContext(_ context: String, maxLength: Int?) -> String {
        guard !context.isEmpty else {
            return ""
        }
        return String(context.suffix(maxLength ?? 40))
    }

    private static func trimmedModeContext(_ modeContext: String?, maxLength: Int?) -> String {
        guard let modeContext else {
            return ""
        }
        return String(modeContext.suffix(maxLength ?? 40))
    }

    private static func v3Conditions(_ mode: ConvertRequestOptions.ZenzaiV3DependentMode) -> [String] {
        var conditions: [String] = []
        if let profile = mode.profile, !profile.isEmpty {
            let pf = profile.suffix(25)
            conditions.append("\u{EE03}\(pf)")
        }
        if let topic = mode.topic, !topic.isEmpty {
            let tp = topic.suffix(25)
            conditions.append("\u{EE04}\(tp)")
        }
        if let style = mode.style, !style.isEmpty {
            let st = style.suffix(25)
            conditions.append("\u{EE05}\(st)")
        }
        if let preference = mode.preference, !preference.isEmpty {
            let pr = preference.suffix(25)
            conditions.append("\u{EE06}\(pr)")
        }
        return conditions
    }

    static func inputPredictionPrompt(
        leftSideContext: String,
        composingText: String,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> String? {
        guard case let .v3(mode) = versionDependentConfig else {
            return nil
        }
        let conditions = self.v3Conditions(mode)
        let trimmedLeftContext = self.trimmedContext(leftSideContext, maxLength: mode.maxLeftSideContextLength)
        let input = composingText.toKatakana()
        if trimmedLeftContext.isEmpty {
            return conditions.joined(separator: "") + inputTag + input
        } else {
            return conditions.joined(separator: "") + contextTag + trimmedLeftContext + inputTag + input
        }
    }

    static func candidateEvaluationPrompt(
        input: String,
        userDictionaryPrompt: String,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> String {
        var conditions: [String] = []
        if !userDictionaryPrompt.isEmpty {
            conditions.append("辞書:\(userDictionaryPrompt)")
        }

        let leftSideContext: String
        switch versionDependentConfig {
        case .v2(let mode):
            if let profile = mode.profile, !profile.isEmpty {
                let pf = profile.suffix(25)
                conditions.append("プロフィール:\(pf)")
            }
            leftSideContext = self.trimmedModeContext(mode.leftSideContext, maxLength: mode.maxLeftSideContextLength)
        case .v3(let mode):
            conditions.append(contentsOf: self.v3Conditions(mode))
            leftSideContext = self.trimmedModeContext(mode.leftSideContext, maxLength: mode.maxLeftSideContextLength)
        }

        switch versionDependentConfig {
        case .v2:
            if !conditions.isEmpty {
                return inputTag + input + contextTag + conditions.joined(separator: "・") + "・発言:\(leftSideContext)" + outputTag
            } else if !leftSideContext.isEmpty {
                return inputTag + input + contextTag + leftSideContext + outputTag
            } else {
                return inputTag + input + outputTag
            }
        case .v3:
            if !leftSideContext.isEmpty {
                return conditions.joined(separator: "") + contextTag + leftSideContext + inputTag + input + outputTag
            } else {
                return conditions.joined(separator: "") + inputTag + input + outputTag
            }
        }
    }
}
