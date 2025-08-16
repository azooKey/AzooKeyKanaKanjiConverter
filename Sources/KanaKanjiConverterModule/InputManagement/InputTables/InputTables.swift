enum InputTables {
    enum Helper {
        static func constructPieceMap(_ base: [String: String], additionalMapping: [[InputTable.KeyElement]: [InputTable.ValueElement]] = [:]) -> [[InputTable.KeyElement]: [InputTable.ValueElement]] {
            var map: [[InputTable.KeyElement]: [InputTable.ValueElement]] = Dictionary(uniqueKeysWithValues: base.map { key, value in
                (key.map { .piece(.character($0)) }, value.map(InputTable.ValueElement.character))
            })
            map.merge(additionalMapping, uniquingKeysWith: { (first, _) in first })
            return map
        }
    }
}
