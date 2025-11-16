import Foundation
import SwiftUtils

enum ZenzPromptBuilder {
    static func buildPrompt(
        convertTarget: String,
        candidate: ZenzCandidateSnapshot,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> String {
        let userDictionaryPrompt = candidate.elements.compactMap { element -> String? in
            guard element.isFromUserDictionary else { return nil }
            return "\(element.word)(\(element.ruby.toHiragana()))"
        }.joined()

        var conditions: [String] = []
        if !userDictionaryPrompt.isEmpty {
            conditions.append("辞書:\(userDictionaryPrompt)")
        }

        switch versionDependentConfig {
        case .v1: break
        case .v2(let mode):
            if let profile = mode.profile?.suffix(25), !profile.isEmpty {
                conditions.append("プロフィール:\(profile)")
            }
        case .v3(let mode):
            if let profile = mode.profile?.suffix(25), !profile.isEmpty {
                conditions.append("\u{EE03}\(profile)")
            }
            if let topic = mode.topic?.suffix(25), !topic.isEmpty {
                conditions.append("\u{EE04}\(topic)")
            }
            if let style = mode.style?.suffix(25), !style.isEmpty {
                conditions.append("\u{EE05}\(style)")
            }
            if let preference = mode.preference?.suffix(25), !preference.isEmpty {
                conditions.append("\u{EE06}\(preference)")
            }
        }

        let leftSideContext: String = {
            switch versionDependentConfig {
            case .v1:
                return ""
            case .v2(let mode):
                if let context = mode.leftSideContext {
                    return String(context.suffix(mode.maxLeftSideContextLength ?? 40))
                }
                return ""
            case .v3(let mode):
                if let context = mode.leftSideContext {
                    return String(context.suffix(mode.maxLeftSideContextLength ?? 40))
                }
                return ""
            }
        }()

        let inputTag = "\u{EE00}"
        let outputTag = "\u{EE01}"
        let contextTag = "\u{EE02}"

        let prompt: String = switch versionDependentConfig {
        case .v1:
            inputTag + convertTarget + outputTag
        case .v2:
            if !conditions.isEmpty {
                inputTag + convertTarget + contextTag + conditions.joined(separator: "・") + "・発言:\(leftSideContext)" + outputTag
            } else if !leftSideContext.isEmpty {
                inputTag + convertTarget + contextTag + leftSideContext + outputTag
            } else {
                inputTag + convertTarget + outputTag
            }
        case .v3:
            if !leftSideContext.isEmpty {
                conditions.joined() + contextTag + leftSideContext + inputTag + convertTarget + outputTag
            } else {
                conditions.joined() + inputTag + convertTarget + outputTag
            }
        }

        return preprocess(prompt)
    }

    static func preprocess(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }
}
