public struct ConversionResult: Sendable {
    /// 変換候補欄にこのままの順で並べることのできる候補
    public var mainResults: [Candidate]
    /// 入力中の予測変換候補（日本語）
    public var predictionResults: [Candidate] = []
    /// 入力中の英語予測変換候補（`requireEnglishPrediction`由来）
    public var englishPredictionResults: [Candidate] = []
    /// 変換候補のうち最初の文節を変換したもの
    public var firstClauseResults: [Candidate]
}
