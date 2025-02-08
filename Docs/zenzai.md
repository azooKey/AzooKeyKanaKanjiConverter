# Zenzai

ニューラルかな漢字変換エンジン「Zenzai」を有効化することで、高精度な変換を提供できます。利用するには変換オプションの`zenzaiMode`を設定します。

```swift
let options = ConvertRequestOptions.withDefaultDictionary(
    // ...
    zenzaiMode: .on(
        weight: url,
        inferenceLimit: 1,
        versionDependentMode: .v3(.init(profile: "三輪/azooKeyの開発者", leftSideContext: "私の名前は"))
    )
    // ...
)
```

* `weight`には`gguf`形式の重みファイルを指定します。重みファイルは[Hugging Face](https://huggingface.co/Miwa-Keita/zenz-v2-gguf)からダウンロードできます。
* `inferenceLimit`には推論回数の上限を指定します。通常`1`で十分ですが、低速でも高精度な変換を得たい場合は`10`程度の値にすることもできます。

## 動作環境
* M1以上のスペックのあるmacOS環境が望ましいです。GPUを利用します。
* モデルサイズに依存しますが、現状150MB程度のメモリを必要とします
* Linux環境・Windows環境でもCUDAを用いて動作します。

## 仕組み
[Zennのブログ](https://zenn.dev/azookey/articles/ea15bacf81521e)をお読みいただくのが最もわかりやすい解説です。

## 制約
現状、Zenzaiを用いた場合ユーザ辞書が使えません。また、予測変換にはニューラル言語モデルは用いられていません。

## 用語
* Zenzai: ニューラルかな漢字変換システム
* zenz-v1: Zenzaiで用いることのできるかな漢字変換モデル「zenz」の第1世代。`\uEE00<input_katakana>\uEE01<output></s>`というフォーマットでかな漢字変換タスクを行う機能に特化。
* zenz-v2: Zenzaiで用いることのできるかな漢字変換モデル「zenz」の第2世代。第1世代の機能に加えて`\uEE00<input_katakana>\uEE02<context>\uEE01<output></s>`というフォーマットで、左文脈を読み込む機能を追加。
