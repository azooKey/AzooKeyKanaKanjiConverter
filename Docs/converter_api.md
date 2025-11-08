#  KanaKanjiConverter API

KanaKanjiConverterの主要APIを示します。以下の例ではデフォルト辞書版を利用しています。

```swift
import KanaKanjiConverterModuleWithDefaultDictionary
let converter = KanaKanjiConverter.withDefaultDictionary()
```
なお、`KanaKanjiConverter.withDefaultDictionary(preloadDictionary: true)`とすることでメモリを大きく消費する代わりに辞書データをすべて読み込んだ状態になります。
## `setKeyboardLanguage(_:)`

これから入力しようとしている言語を設定します。このAPIは日本語/英語をサポートするアプリケーションでは必須です。
なお、AzooKeyKanaKanjiConverterは通常デフォルトで日本語の設定となっています。英語入力への切り替えの際、ユーザの入力より先にこの関数を呼び出すことでデータがプリロードされ、応答性が向上する可能性があります。

## 辞書・学習関連のAPI

### `importDynamicUserDictionary(_:shortcuts:)`
動的ユーザ辞書と動的ショートカットを登録します。`DicdataElement` の配列を直接渡します。

```swift
converter.importDynamicUserDictionary(
    [
        DicdataElement(word: "anco", ruby: "アンコ", cid: 1288, mid: 501, value: -5),
    ],
    shortcuts: [
        DicdataElement(word: "ありがとうございます", ruby: "アザス", cid: 1288, mid: 501, value: -5),
    ]
)
```
`ruby` はカタカナで指定してください。`value` は `-5`〜`-10` 程度が目安です。`shortcuts` は全文一致ショートカット用の語彙を登録します（省略可能）。

### `updateUserDictionaryURL(_:)`
ユーザ辞書（`user.louds*` 等）が置かれているディレクトリURLを更新します。

```swift
converter.updateUserDictionaryURL(documents)
```

### `updateLearningConfig(_:)`
学習設定を更新します。

```swift
converter.updateLearningConfig(
    LearningConfig(learningType: .inputAndOutput, maxMemoryCount: 65536, memoryURL: documents)
)
```

### `updateLearningData(_:)`, `commitUpdateLearningData()`, `resetMemory()`
確定候補に基づく学習データを反映・保存・リセットします。

```swift
converter.updateLearningData(candidate)
converter.commitUpdateLearningData()   // 永続化
// 全学習のリセット
converter.resetMemory()
```

### `stopComposition()`
内部状態のキャッシュをリセットします。入力の区切りで呼ぶと安定します。
