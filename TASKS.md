-[ ] 既存APIの委譲化: `KanaKanjiConverter`に`defaultSession`を持たせ、`requestCandi
dates`/`requestPostCompositionPredictionCandidates`/`setCompletedData`/`updateLe
arningData`/`stopComposition`を全て`defaultSession`へ委譲。2系統の実装が並立しな
いようにする。
-[ ] CLIの移行: `SessionCommand`などで`converter`直呼びしている箇所を`session = con
verter.makeSession()`へ移行し、確定/リセットも`session`経由に。複数セッションの
実験も容易になる。
-[ ] オプション変更時のセッションリセット: `KanaKanjiConverterSession`が直近の`opti
ons`を保持しているので、`dictionaryResourceURL`や学習設定が変わった場合は`stop()
`でセッション内キャッシュをリセット（`DicdataStore`は既に内部で再ロード済み）。
小さなガードを`requestCandidates`に追加。

