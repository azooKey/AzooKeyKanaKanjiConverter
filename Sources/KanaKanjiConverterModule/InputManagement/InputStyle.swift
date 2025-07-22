public enum InputStyle: Sendable, Equatable, Hashable {
    /// 入力された文字を直接入力するスタイル
    case direct
    /// ローマ字日本語入力とするスタイル
    case roman2kana
    /// カスタムローマ字かな変換テーブルなど、任意のマッピングを管理
    case mapped(id: InputTableID)

    static var frozen: Self {
        .mapped(id: .empty)
    }
}
