#  anco (azooKey CLI)

`anco`コマンドにより、AzooKeyKanaKanjiConverterをコマンドライン上で利用することができます。`anco`はデバッグ用ツールの位置付けです。

`anco`を利用するには、最初にinstallが必要です。`/usr/local/bin/`に`anco`が追加されます。

```bash
./install_cli.sh
```

Zenzaiを利用する場合は、`--zenzai`オプションを付けてください。

```bash
./install_cli.sh --zenzai
```

デフォルトでは、ほとんどの情報は出力されません。デバッグモードで実行するには`--debug`オプションを付けてください。

```bash
./install_cli.sh --debug
```

例えば以下のように利用できます。

```bash
your@pc Desktop % anco にほんごにゅうりょく --disable_prediction -n 10
日本語入力
にほんご入力
2本ご入力
2本後入力
2本語入力
日本語
2本
日本
にほんご
2本後
```

## 変換API

`anco run`コマンドを利用して変換を行うことが出来ます。`run`はデフォルトコマンドなので、`anco`だけでも`run`相当の動作をします。

## 評価API

`anco evaluate`コマンドを利用して変換器の評価を行うことが出来ます。

以下のようなフォーマットの`.tsv`ファイルを用意します。
```tsv
しかくとさんかく	四角と三角
かんたんなさんすう	簡単な算数
しけんにでないえいたんご	試験に出ない英単語
しごととごらくとべんきょう	仕事と娯楽と勉強
しかいをつとめる	司会を務める
```

これを入力し、変換器を評価します。

```bash
$ anco evaluate ./evaluation.tsv --config_n_best 1
```

出力はJSONフォーマットです。出力内容の安定が必要な場合`--stable`を指定することで比較的安定した出力を得られます。ただしスコアやエントロピーは辞書バージョンに依存します。

## 対話的実行API

少しずつ入力を進めるような実用的な場面を模した環境として`anco session`コマンドが用意されています。

```bash
$ anco session --roman2kana -n 10 --disable_prediction

== Type :q to end session, type :d to delete character, type :c to stop composition. For other commands, type :h ==
```

通常の入力文字は1文字ごとに即時処理され、変換候補が更新されます。`:`で始まる特殊コマンドはコマンド全体を入力してEnterで実行します。通常の入力文字もEnterを押してから処理したい場合は`--disable-immediate-input`を指定します。

### リプレイ

`--replay`を用いると、セッションの中での一連の動作を再現することができます。

```yaml
anco session --roman2kana -n 10 --disable_prediction --replay history.txt
```

`history.txt`は例えば以下のような内容が含まれます。

```
a
i
u
e
e
:del
o
:0
```

現在実行中のセッションから`history.txt`を作成するには`:dump history.txt`と入力します。

### 学習機能のデバッグ
学習機能のデバッグのため、セッションコマンドには複数の機能が用意されています。`--enable_memory`の状態では、デフォルトで学習が有効になり、一時ディレクトリに学習データが蓄積されます。

```bash
$ anco session --roman2kana -n 10 --disable_prediction --enable_memory
```

セーブを実施するには以下のように`:save`を入力します。

```txt
rime
:h
:n
:14
:4
:save
```

すでに存在する学習データをread onlyで読み込むこともできます。

```bash
$ anco session --roman2kana -n 10 --disable_prediction --readonly_memory ./memory
```

この場合、`:save`コマンドは何も行いません。

## 辞書リーダ

`anco dict`コマンドを利用して辞書データを解析することが出来ます。

```bash
your@pc Desktop % anco dict read ア -d ./Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/                       
=== Summary for target ア ===
- directory: ./Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/
- target: ア
- memory?: false
- count of entry: 24189
- time for execute: 0.0378040075302124
```

`--ruby`および`--word`オプションを利用して、正規表現でフィルターをかけることが出来ます。

```bash
your@pc Desktop % anco dict read ア -d ./Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/ --word ".*全"
=== Summary for target ア ===
- directory: ./Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/
- target: ア
- memory?: false
- count of entry: 24189
- time for execute: 0.07062792778015137
=== Found Entries ===
- count of found entry: 3
Ruby: アキラ Word: 全 Value: -11.7107 CID: (1291, 1291) MID: 424
Ruby: アンゼン Word: 安全 Value: -7.241 CID: (1287, 1287) MID: 169
Ruby: アンシンアンゼン Word: 安心安全 Value: -11.7638 CID: (1283, 1287) MID: 17
```

`--sort`オプションを使うとエントリーの並び替えが可能です。
