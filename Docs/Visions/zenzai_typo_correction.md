# Zenzai Typo Correction を ON にする設計メモ（検証と実装計画）

## 背景と目的
- 現状、Zenzai 経路では Typo Correction を常に無効化している（draft 構築で `needTypoCorrection: false` を強制）。そのため、ローマ字タイプミスや濁点誤りを Zenzai 併用時に救えない。
- 目的は、Typo Correction を確率的に扱いつつ Zenzai の再評価で品質を底上げし、候補の網羅性と並び順の両立を図ること。

## 確率モデル（整理）
- 記号:
  - `X`: ノイジーな入力（タイプミスを含む）
  - `Y`: 真の入力候補（Typo Correction 後の“正”入力）
  - `Z`: 変換候補（表層語列）
- 目的: `argmax_{Y, Z} P((Y, Z) | X)` を求める。
- 分解: `P((Y, Z) | X) = P(Z | Y, X) P(Y | X)`
- 実装近似（方針）:
  1) まず統計的かな漢字変換（既存エンジン）で `P(Y, Z | X)` を粗く近似してサンプル（draft 生成に Typo Correction を使う）
  2) 上位候補に対し、`P(Z | Y)` を Zenzai で評価し再サンプリング（Zenzai のスコアでリランク）

このとき `P(Z | Y, X) ≈ P(Z | Y)` とみなす（入力ノイズ構造を Z 側では見ない近似）。`P(Y | X)` の近似は既存 Typo Correction のペナルティ（および Viterbi スコア）で担保する。

## 方式案（サンプリング＋再評価）
- ステップA: 粗サンプリング（既存エンジンで Typo Correction 有効）
  - `kana2lattice_all(..., needTypoCorrection: true, ...)` を用いて上位 `K` 個（`K` は N-best 相当＋α）の `(Y, Z)` 候補を取得。
  - Typo Correction ペナルティは `P(Y | X)` の擬似対数尤度として機能。
- ステップB: Zenzai による再評価（`P(Z | Y)`）
  - サンプル済み候補の `Z` を `zenz.candidateEvaluate(...)` で評価しスコアを取得。
  - 返却される `alternativeConstraints` が高確率（例: `probabilityRatio > τ`）なら、
    - `kana2lattice_all_with_prefix_constraint(..., constraint: ...)` を Typo 有効で追加入力し、N-best を拡張（再サンプリング）。
- ステップC: リランク
  - スコアのブレンディング（初期実装の推奨値）:
    - `S = w_zenz * score_zenz + w_stat * score_stat`
      - `score_zenz`: `candidateEvaluate` のスコア（正規化/切り詰め要検討）
      - `score_stat`: 既存エンジンの候補スコア（Typo ペナルティ込み）を線形正規化
    - 初期: `w_zenz = 1.0, w_stat = 0.3` 程度から開始。
  - 単純化の第一段階としては、「既存順位を prior、Zenzai スコアを強い補正」にするだけでも十分に効く見込み。

## 実装計画
1. Zenzai 経路に Typo フラグを配線

   - `ConvertRequestOptions.needTypoCorrection` または Zenzai 専用新フラグ（例: `ZenzaiMode.enableTypoCorrection`）を尊重。

   - `Zenzai/zenzai.swift`
     - draft 生成時の `kana2lattice_all` へ `needTypoCorrection` を反映。
       - 制約付き検索でも Typo を通せるよう、
         - `FullInputProcessingWithPrefixConstraint` 側の `lookupDicdata(... needTypoCorrection: false)` を引数化し、呼び出し側から渡す。

2. 再評価フローの拡張（最初は軽量）

   - 既存の `candidateEvaluate` 結果を取り込み、
     - `alternativeConstraints` のうち高確率のものを（既存と同様の閾値ロジックで）拡張探索。ただしこの探索でも Typo を許容。
     
     - リランク（簡易版）
       - 既存の並びに対し Zenzai スコアで再並べ替え（安定ソート）。

3. CLI/API

   - `CliTool` に `--enable_typo_correction`（bool）を追加。

   - 既定は OFF。

## パラメータと上限
- `K`（粗サンプル数）: 初期は N-best=2〜3 のまま、Typo ON で候補多様性を確保。必要なら 4 まで拡張。
- `inferenceLimit`（Zenzai 推論上限）: 既存既定を尊重しつつ、Typo ON 時は 1〜2 回だけ追加の再評価を許可。
- `τ`（代替制約の確率比しきい値）: 0.5 以上を推奨（現実装のヒューリスティクスと整合）。
- 重み `w_zenz, w_stat` は実計測で微調整。

## 評価計画
- データ: 既存評価セット＋Typo を含む追加ケース（ローマ字誤打、濁点/半濁点、促音/拗音、近傍キー誤り など）。
- 指標: Top-1/Top-3 精度、候補リスト MRR、平均レイテンシ、95%タイルレイテンシ。
- 期待: Typo を含むクエリでの Top-1/Top-3 改善。全体レイテンシは +5〜15% 以内。

## リスクと対策
- レイテンシ増: Zenzai 呼び出しが増える。`inferenceLimit` と `K` を抑制、既存のラティス再利用（キャッシュ）を活用。
- ノイズ拡散: Typo ON で候補が増える。prefix 制約と `probabilityRatio` 閾値で枝刈り。
- スコアのスケーリング: Zenzai スコアと統計スコアのレンジ差。min-max 正規化または温度付与で吸収（要 AB）。

## ロールアウト
- Phase 1（安全版）: Zenzai 経路で Typo を通すだけ（並びは既存優先、Zenzai スコアは許容判定のみに利用）。
- Phase 2: 代替制約の再探索（Typo 許容）を有効化し、候補の厚みを増す。
- Phase 3: スコアブレンディング導入。重みを AB テストで最適化。デフォルト ON を検討。

