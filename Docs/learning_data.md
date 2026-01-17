# 学習データについて

AzooKeyKanaKanjiConverter では、ユーザが変換候補を選択した結果を学習して、次回以降の変換候補の並び替えに利用します。学習結果は `memoryDirectoryURL` で指定したディレクトリに保存されます。

## 保存されるファイル

学習データは内部的に辞書形式のファイルとして保持されます。主なファイルは以下の通りです。

- `memory.louds`
- `memory.loudschars2`
- `memory.loudstxt3`

更新時には一時的に `.2` の拡張子が付いたファイルを作成し、安全に置き換える仕組みになっています。更新処理の詳細は [conversion_algorithms.md](./conversion_algorithms.md) を参照してください。

## ディレクトリの指定と学習設定

`ConvertRequestOptions` の `memoryDirectoryURL` に書き込み可能なディレクトリを指定してください。通常はアプリの書類フォルダなどを指定します。英語用と日本語用など、キーボードのターゲットごとに学習データを分けたい場合は、言語ごとに別のディレクトリを指定してください。

```swift
let documents = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!

// 変換リクエスト時のオプションで学習種別等を指定
let options = ConvertRequestOptions(
    requireJapanesePrediction: .autoMix,
    requireEnglishPrediction: .autoMix,
    keyboardLanguage: .ja_JP,
    learningType: .inputAndOutput,
    maxMemoryCount: 65536,
    memoryDirectoryURL: documents,
    sharedContainerURL: documents,
    textReplacer: .withDefaultEmojiDictionary(),
    specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders
)

// もしくは明示的に学習設定を更新
converter.updateLearningConfig(
    LearningConfig(learningType: .inputAndOutput, maxMemoryCount: 65536, memoryURL: documents)
)
```

## 学習データの保存・リセット

確定候補に応じた学習は `updateLearningData(_:)` で反映されます。永続化は `commitUpdateLearningData()` を呼びます。

```swift
converter.updateLearningData(candidate)
converter.commitUpdateLearningData()    // ディスクへ保存
```

学習データを一括初期化する場合は `resetMemory()` を使用してください。

```swift
converter.resetMemory()
```

（参考）ファイルの完全削除のみを実行したい場合は
`LongTermLearningMemory.reset(directoryURL:)` を直接呼び出してください。
