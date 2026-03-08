package enum AncoSessionCommand: Sendable, Equatable {
    package struct HelpItem: Sendable, Equatable {
        package init(usage: String, description: String) {
            self.usage = usage
            self.description = description
        }

        package var usage: String
        package var description: String
    }

    package enum SpecialInput: String, Sendable, Equatable {
        case endOfText = "eot"

        package init?(decoding command: String) {
            self.init(rawValue: command)
        }

        package var encodedCommand: String {
            self.rawValue
        }
    }

    case quit
    case deleteBackward
    case clearComposition
    case nextPage
    case save
    case predictInput(count: Int, maxEntropy: Float?, minLength: Int)
    case help
    case typoCorrection(String)
    case setConfig(key: String, value: String)
    case setContext(String)
    case specialInput(SpecialInput)
    case dumpHistory(String?)
    case selectCandidate(Int)
    case input(String)

    package static let helpItems: [HelpItem] = [
        .init(usage: ":q, :quit", description: "quit session"),
        .init(usage: ":c, :clear", description: "clear composition"),
        .init(usage: ":d, :del", description: "delete one character"),
        .init(usage: ":n, :next", description: "see more candidates"),
        .init(usage: ":s, :save", description: "save memory"),
        .init(usage: ":ip [n] [max_entropy=F] [min_length=N]", description: "predict next input character(s) (zenz-v3)"),
        .init(usage: ":tc [n] [beam=N] [top_k=N] [max_steps=N] [alpha=F] [beta=F] [gamma=F]", description: "typo correction candidates (LM + channel)"),
        .init(usage: ":cfg key=value", description: "update session config"),
        .init(usage: ":%d", description: "select candidate at that index (like :3 to select 3rd candidate)"),
        .init(usage: ":ctx %s", description: "set the string as context"),
        .init(usage: ":input %s", description: "insert special characters to input"),
        .init(usage: "eot", description: "end of text (for finalizing composition)"),
        .init(usage: ":dump %s", description: "dump command history to specified file name (default: history.txt)")
    ]

    package static var helpText: String {
        let body = self.helpItems
            .map { "\($0.usage) - \($0.description)" }
            .joined(separator: "\n")
        return """
        == anco session commands ==
        \(body)
        """
    }

    package init?(decoding command: String) {
        switch command {
        case ":q", ":quit":
            self = .quit
        case ":d", ":del":
            self = .deleteBackward
        case ":c", ":clear":
            self = .clearComposition
        case ":n", ":next":
            self = .nextPage
        case ":s", ":save":
            self = .save
        case ":h", ":help":
            self = .help
        case let command where command == ":tc" || command.hasPrefix(":tc "):
            self = .typoCorrection(command)
        case let command where command.hasPrefix(":cfg "):
            let config = String(command.dropFirst(5))
            guard let separator = config.firstIndex(of: "=") else {
                return nil
            }
            self = .setConfig(
                key: String(config[..<separator]),
                value: String(config[config.index(after: separator)...])
            )
        case let command where command == ":ip" || command.hasPrefix(":ip "):
            let parts = command.split(separator: " ")
            var requestedCount = 1
            var maxEntropy: Float?
            var minLength = 1
            for part in parts.dropFirst() {
                if let count = Int(part) {
                    requestedCount = count
                    continue
                }
                if part.hasPrefix("max_entropy=") {
                    let value = part.dropFirst("max_entropy=".count)
                    if let parsed = Float(value) {
                        maxEntropy = parsed
                    }
                    continue
                }
                if part.hasPrefix("min_length=") {
                    let value = part.dropFirst("min_length=".count)
                    if let parsed = Int(value) {
                        minLength = parsed
                    }
                }
            }
            self = .predictInput(count: requestedCount, maxEntropy: maxEntropy, minLength: minLength)
        case let command where command.hasPrefix(":ctx"):
            self = .setContext(String(command.dropFirst(5)))
        case let command where command.hasPrefix(":input"):
            let specialInput = String(command.dropFirst(7))
            guard let specialInput = SpecialInput(decoding: specialInput) else {
                return nil
            }
            self = .specialInput(specialInput)
        case let command where command.hasPrefix(":dump"):
            self = .dumpHistory(command.count > 6 ? String(command.dropFirst(6)) : nil)
        case let command where command.hasPrefix(":"):
            guard let index = Int(command.dropFirst()) else {
                return nil
            }
            self = .selectCandidate(index)
        default:
            self = .input(command)
        }
    }

    package var encodedCommand: String {
        switch self {
        case .quit:
            return ":q"
        case .deleteBackward:
            return ":d"
        case .clearComposition:
            return ":c"
        case .nextPage:
            return ":n"
        case .save:
            return ":s"
        case let .predictInput(count, maxEntropy, minLength):
            var parts = [":ip"]
            if count != 1 {
                parts.append(String(count))
            }
            if let maxEntropy {
                parts.append("max_entropy=\(maxEntropy)")
            }
            if minLength != 1 {
                parts.append("min_length=\(minLength)")
            }
            return parts.joined(separator: " ")
        case .help:
            return ":h"
        case let .typoCorrection(command):
            return command
        case let .setConfig(key, value):
            return ":cfg \(key)=\(value)"
        case let .setContext(context):
            return ":ctx \(context)"
        case let .specialInput(input):
            return ":input \(input.encodedCommand)"
        case let .dumpHistory(path):
            return path.map { ":dump \($0)" } ?? ":dump"
        case let .selectCandidate(index):
            return ":\(index)"
        case let .input(input):
            return input
        }
    }
}
