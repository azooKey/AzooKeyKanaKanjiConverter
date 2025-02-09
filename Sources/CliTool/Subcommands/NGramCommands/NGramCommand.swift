import Foundation
import ArgumentParser

extension Subcommands {
    struct NGram: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ngram",
            abstract: "Use EfficientNGram Implementation",
            subcommands: [Self.Train.self, Self.Inference.self]
        )
    }
}
