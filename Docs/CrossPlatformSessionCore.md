# Cross Platform Session Core

このドキュメントは、`AzooKeyKanaKanjiConverter` を iOS / macOS / CLI で共有できる IME セッション実装の中心にしていくための設計メモです。

## 何をやりたいのか

最終目標は、各クライアントが別々に持っている変換セッション責務をこのリポジトリ側へ寄せることです。

現在は以下のように責務が分散しています。

- `azooKey`
  - `InputManager`
  - `LiveConversionManager`
  - `DisplayedTextManager`
- `azooKey-Desktop`
  - `SegmentsManager`
- `AzooKeyKanaKanjiConverter`
  - `KanaKanjiConverter`
  - `AncoSession` (CLI helper 寄り)

この状態では、同じ種類のロジックが複数の実装に分かれて存在します。

- composing text の更新
- 左文脈の扱い
- 候補の再計算
- 候補確定後の prefix completion
- learning update
- live conversion
- prediction / main / live conversion の見え方の切り替え

やりたいことは、これらを `AzooKeyKanaKanjiConverter` 側の共通 session core に寄せ、各クライアントを UI / OS 連携に集中させることです。

## 目標状態

`AzooKeyKanaKanjiConverter` は単なる変換 engine の提供元ではなく、cross-platform な IME session runtime を提供する。

責務の分け方は次を想定します。

- `KanaKanjiConverter`
  - 変換 engine
  - 辞書
  - 候補探索
- `AncoSessionCore`
  - shared session runtime
  - composing text
  - surrounding context
  - candidate update
  - candidate selection 後の状態遷移
  - commit / learning update
  - live conversion
- `AncoSession`
  - CLI adapter
  - command parse / encode
  - paging や debug 表示
- iOS / macOS / CLI 側
  - UI 表示
  - marked text / preedit / candidate window
  - surrounding text の取得
  - OS event の橋渡し

## AncoSessionCore をどうしたいか

`AncoSessionCore` は iOS / macOS / CLI が共有する session state machine 本体にしたい。

そのために、以下を持てるようにする。

- 入力中テキスト
- 左文脈や surrounding text
- main candidates
- prediction candidates
- live conversion state
- commit 済み prefix に基づく継続状態
- session config

現在は `AncoSessionCore` が

- candidate update
- candidate selection
- live conversion projection

を持つところまで進んでいる。

次の段階では、入力編集そのものも `AncoSessionCore` に寄せる。

また、session runtime は複数の公式な「見え方」を返せるべきです。

- `view=main`
- `view=prediction`
- `view=liveConversion`

ここでいう `view` は CLI の表示オプションではなく、session runtime が提供する正式な projection です。

## preset / config / view

プラットフォーム差を `enum ios/macos/cli` のような固定列挙で扱うのではなく、以下を分離して扱います。

- `preset`
  - 推奨設定の束
  - 例: `ios-default`, `macos-default`, `cli-debug`
- `config`
  - 現在の実効設定
- `view`
  - その状態をどう見るか

`preset` は単なる初期値テンプレートであり、実行環境の列挙ではありません。
Ubuntu や Windows などのサードパーティ利用もあるため、この形のほうが拡張しやすいです。

設定は概ね以下のレイヤで解決する想定です。

1. default
2. preset values
3. user overrides
4. runtime overrides

## CLI で再現可能にしたいこと

理想は、iOS / macOS の session 挙動を CLI で再現できることです。

そのためには、CLI が単なる manual debug tool ではなく、session replay / inspection tool になる必要があります。

必要な性質は以下です。

- `view` を切り替えて同じ session state を観察できる
- surrounding text を入力できる
- candidate selection や prefix completion を再現できる
- live conversion の安定判定を再現できる
- replayable な event 列として保存できる

## 今回なぜ live conversion から始めたのか

今回の変更は、本来の目的全体から見ると一部です。

`live conversion` から始めた理由は次の通りです。

- iOS と macOS の両方に同種の責務がある
- UI ではなく session policy に属する
- 単独でも切り出しやすい
- `AncoSession` に `view=liveConversion` を生やす入口になる

つまり、live conversion 共通化は本丸ではなく、cross-platform session core 化の最初の縦切りです。

## 今回の変更でやったこと

今回の refactor では、まず `live conversion` の state / policy を `AzooKeyKanaKanjiConverter` 側へ移しました。

- `LiveConversionState`
- `LiveConversionConfig`
- `LiveConversionSnapshot`

これを

- `AncoSession`
- `azooKey` の `LiveConversionManager`
- `azooKey-Desktop` の `SegmentsManager`

から利用する形にしています。

これにより、live conversion の判定ロジック自体はクライアント側の独自実装ではなくなりました。

その次の段階として、`AncoSessionCore` を追加し、少なくとも以下の orchestration を core 側へ移しました。

- `requestCandidates -> outputs 更新 -> live conversion projection`
- `selectCandidate -> prefix completion -> 次状態`

現時点では次の利用形態になっています。

- `AncoSession`
  - `AncoSessionCore` を内部に持つ
- `azooKey`
  - `InputManager.setResult` と `complete` が `AncoSessionCore` を使う
- `azooKey-Desktop`
  - `SegmentsManager.updateRawCandidate` と `prefixCandidateCommited` が `AncoSessionCore` を使う

ただし、入力編集そのものはまだ client 側に残っています。

## まだ session core 化できていないもの

以下はまだクライアント側に強く残っています。

- `ComposingText` の直接編集
  - `insertAtCursorPosition`
  - `deleteBackwardFromCursorPosition`
  - `moveCursorFromCursorPosition`
- iOS の `InputManager` が持つ session orchestration
- macOS の `SegmentsManager` が持つ candidate / selection / commit orchestration
- surrounding text の取り回し
- learning update の呼び出し順
- `KanaKanjiConverter` に残っている session-local state

したがって、現時点では「candidate runtime を共通化し始めた」段階であり、「入力イベントから commit までの session runtime を完成させた」状態ではありません。

## 次にやるべきこと

次の段階は以下を想定します。

### 1. `AncoSessionCore` の event-driven 化

今の `AncoSessionCore` は candidate runtime としては機能しているが、client がまだ `ComposingText` を直接編集している。

次に以下の API を `AncoSessionCore` に持たせる。

- `insert`
- `deleteBackward`
- `deleteForward`
- `moveCursor`
- `setContext`
- `selectCandidate`
- `stopComposition`

つまり、client は `ComposingText` を直接 mutate するのではなく、`SessionEvent` を送る形にする。

### 2. `ComposingText` の所有権を `AncoSessionCore` に寄せる

iOS / macOS / CLI から `insertAtCursorPosition` や `deleteBackwardFromCursorPosition` を直接呼ばない構成にする。

この段階に入ると、`InputManager` と `SegmentsManager` から入力編集コードが大きく減り始める。

### 3. `AncoSession` を CLI adapter に痩せさせる

今の `AncoSession` は session runtime と CLI helper の責務が混ざっている。

次の形に分解していく。

- `AncoSessionCore`
  - typed event API を持つ本体
- `AncoSession`
  - `AncoSessionRequest` を `SessionEvent` に変換する CLI adapter

`AncoSessionRequest`, `:cfg`, `:dump`, paging, help 表示などは `AncoSession` 側に残す。

### 4. iOS / macOS helper の薄型化

- `InputManager`
- `SegmentsManager`

から session logic をさらに削り、OS / UI event を `AncoSessionCore` に流す adapter に近づける。

### 5. CLI の replay/runtime 化

CLI は最終的に `AncoSessionCore` を叩く debugger 兼 replay runner として整理する。

この時点で、iOS / macOS の挙動を同じ event stream で再現できる状態を目指す。

## 設計上の原則

この refactor では、以下を原則とする。

- 変換 engine と session runtime を分ける
- `view` は session の公式 projection として扱う
- platform の違いは固定 enum ではなく `preset + overrides` で扱う
- UI 表示責務は client 側に残す
- session semantics に影響するものだけを core に入れる

## まとめ

やりたいことの本質は `live conversion` 共通化ではなく、`AzooKeyKanaKanjiConverter` を cross-platform IME session core にすることです。

今回の変更はその第一歩として、iOS / macOS で重複していた `live conversion` を共通 state / policy に移したものです。

今後は `AncoSessionCore` を中心に、

- session state
- views
- config resolution
- replayable event model

を整理していくことで、iOS / macOS / CLI の挙動を同じ runtime の上に載せられるようにしていきます。
