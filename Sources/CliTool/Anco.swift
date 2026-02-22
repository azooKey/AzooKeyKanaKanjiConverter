import ArgumentParser
import KanaKanjiConverterModuleWithDefaultDictionary

@main
struct Anco: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Anco is A(zooKey) Kana-Ka(n)ji (co)nverter",
        subcommands: [
            Subcommands.Run.self,
            Subcommands.Dict.self,
            Subcommands.Evaluate.self,
            Subcommands.ZenzEvaluate.self,
            Subcommands.Session.self,
            Subcommands.NGram.self
        ],
        defaultSubcommand: Subcommands.Run.self
    )
}
