# カスタム入力テーブル

v0.10.0以降のAzooKeyKanaKanjiConverterでは「カスタム入力テーブル」機能をサポートします。

この機能は、標準のローマ字かな変換とは異なる入力テーブルを利用する場合に活用できます。例えば

* AZIK, DvorakJPなどのカスタムローマ字かな変換
* 絵文字入力、記号入力などの特殊機能

などを用途として想定しています。

## 使い方

カスタム入力テーブルを利用するには、`InputStyleManager.registerInputStyle`を呼び出して`InputTable`を名前付きで設定し、`ComposingText`の`inputStyle`として`.tableName(name: String)`を設定します。

## カスタム入力テーブルファイル
カスタム入力テーブルは`.tsv`ファイルとして記述できます。

```tsv
ka\tか
ga\tが
```

\tの含まれない行は無視されます。

特殊な入力を処理するため、`{composition-separator}`および`{any character}`という特殊記号が用意されています。また`{}`のエスケープ文字として`{lbracket}`と`{rbracket}`が用意されています。

例えば次のように書くことで、任意の文字を含むパターンや末尾の区切りに対応できます。

```tsv
# nのあとに任意の入力Aがあれば、それを「んA」で置き換える
n{any character}\tん{any character}
# {any character}は他の具体的な指定がある場合無視される。以下の指定がある場合、`na`の入力では「な」が入力される
na\tな
# 入力末尾には`{composition-separator}`が入力される。そこで「s」で入力が終わって変換キーが押されたら「す」に置き換えるには、以下のように書ける。
s{composition-separator}\tす
```

### PCキーボードのキー入力

特にかな入力などでは「Shift + 0」とただの「0」を区別しますが、表面文字列上はどちらも「0」となるため、`.character(...)`では区別ができません。そこで「キー＋修飾」を入力テーブルのキー側で表現する仕組みを用意しています。これは`ComposingText`では`InputPiece.key(intention: Character?, modifiers: Set<Modifier>)` として扱います。

入力テーブルとしては、暗黙に次のような規則が入っていると考えてください。このため、一度入力されれば修飾キーによる区別は失われ、Shift+0は0に置き換えられます。

```
# pseudo-syntax
{shift {any character}}\t{any character}
```

しかし、以下のように記述することでオーバーライドすることができます。

```
# 単に0が入力された場合は「わ」に置換
0\tわ
# Shift+0のケースでは「を」に置換
{shift 0}\tを
```

現在は`{shift 0}`と`{shift _}`にのみ対応しています。これは、これ以外の文字については表層文字列でシフトあり/なしの区別が可能であるためです。

- `{shift 0}` は「意図文字が `"0"` で、shift が押されたキー入力」にのみ一致します。単なる文字 `0` の入力には一致しません。
- `{shift _}` は「意図文字が `"_"` で、shift が押されたキー入力」にのみ一致します。単なる文字 `_` の入力には一致しません。

これらに関連するマッチング規則は以下のとおりです。

- 文字規則へのフォールバック:
  - キー入力 `.key(intention: c, modifiers: …)` は、テーブルに `c` の文字規則がある場合、それにも一致します。
  - 例: `0\tZ` という規則があると、`{shift 0}` で入力された `.key(intention: "0", [.shift])` も `Z` に一致します。
- 競合時の優先順位:
  - 同じ深さで `{shift 0}` と `0` の両方に一致可能な場合、`{shift 0}`（キー規則）の方を優先します。
  - 同様に `{shift _}` と `_` が並存する場合は `{shift _}` を優先します。
- `{any character}` の挙動:
  - `{any character}` は `.character(c)` だけでなく、`.key(intention: c, …)`（c が存在する場合）にも一致し、出力側の `{any character}` にその `c` が代入されます。
- 末尾記号 `{composition-separator}` の挙動は従来どおりです。

なお、現状、パーサが受け付けるキー書式は `{shift 0}` と `{shift _}` が末尾にあるケースに限ります。暗黙に修飾キーの情報は失われるため、`a{shift 0}b`のようなマッチングは無効です。

## 注意
Google日本語入力などのカスタム入力テーブルとは互換性がありません。そのまま使える場合もありますが、一部修正が必要になると思います。
特に顕著な違いを以下に述べます。

**置換は貪欲に行われ、曖昧なケースがあっても考慮しません**。

このため、以下のように記述すると、`yrsk`と入力した時点で「よろしく」が発生し、「yrskds」に到達できません。
```tsv
yrsk\tよろしく
yrskds\tよろしくです
```

この場合、以下のように記述してください。
```tsv
yrsk\tよろしく
よろしくds\tよろしくです
```

**「出力」と「次の入力」の区別はありません。**
従って、TSVファイルの各行には2つのエントリのみを追加できます。

## フォーマットチェック API

アプリケーションがカスタム入力テーブルを読み込む際に、基本的なフォーマットエラーを検出するための簡易バリデータを用意しています。

- 関数: `InputStyleManager.checkFormat(content: String) -> FormatReport`
- 結果: `FormatReport.fullyValid` または `FormatReport.invalidLines([(line: Int, error: FormatError)])`

チェック項目
- タブ数: 空行以外は「タブちょうど1個（キー/値の2フィールド）」
- 波括弧 `{...}` 内のトークン: 以下以外はエラー
  - キー側: `composition-separator`, `any character`, `lbracket`, `rbracket`, `shift 0`, `shift _`
  - 値側: `any character`, `lbracket`, `rbracket`
  - 未閉鎖/ネスト（`{abc`, `{{x}` など）は `unclosedBrace`。文字として `{`/`}` を使いたい場合は `{lbracket}`/`{rbracket}` を使用してください。
- `{shift 0}`/`{shift _}` はキー列の末尾のみ許容（途中に現れると `shiftTokenNotAtTail`）
- 重複定義: 同一キーが2回以上登場した場合はエラー（値が同じでも `duplicateRule`）

使用例

```swift
let content = """
ka	か
{shift 0}	が
0	お
"""
switch InputStyleManager.checkFormat(content: content) {
case .fullyValid:
    print("OK")
case .invalidLines(let issues):
    for issue in issues {
        print("Line \(issue.line): \(issue.error)")
    }
}
```
