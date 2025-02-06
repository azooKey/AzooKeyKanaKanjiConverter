import KanaKanjiConverterModuleWithDefaultDictionary
import ArgumentParser

@main
public struct Anco: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Anco is A(zooKey) Kana-Ka(n)ji (co)nverter",
        subcommands: [
            Subcommands.Run.self,
            Subcommands.Dict.self,
            Subcommands.Evaluate.self,
            Subcommands.ZenzEvaluate.self,
            Subcommands.Session.self,
            Subcommands.ExperimentalPredict.self
        ],
        defaultSubcommand: Subcommands.Run.self
    )

    public init() {}
}
