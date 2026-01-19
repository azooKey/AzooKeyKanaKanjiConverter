# 開発ガイド

## 必要な環境

- Swift 6.1以上
- iOS 16+, macOS 13+, visionOS 1+, Ubuntu 22.04+ (基本開発用)
- iOS 18+, macOS 15+ (ZenzaiCoreML trait使用時)

## セットアップ

レポジトリをクローンしてください。サブモジュールを含むため、`--recursive`オプションが必要です。

```bash
git clone https://github.com/ensan-hcl/AzooKeyKanaKanjiConverter --recursive
```

## ビルド

### 基本ビルド

```bash
swift build -Xswiftc -strict-concurrency=complete
```

### Zenzai (llama.cpp + GPU) を有効にしてビルド

```bash
swift build --traits Zenzai -Xswiftc -strict-concurrency=complete
```

### ZenzaiCoreML (CoreML + Stateful) を有効にしてビルド

iOS 18+, macOS 15+が必要です。

```bash
swift build --traits ZenzaiCoreML -Xswiftc -strict-concurrency=complete
```

### ZenzaiCPU (llama.cpp + CPU only) を有効にしてビルド

```bash
swift build --traits ZenzaiCPU -Xswiftc -strict-concurrency=complete
```

## テスト

### 基本テスト

```bash
swift test -c release -Xswiftc -strict-concurrency=complete
```

### Zenzai traitでテスト

```bash
swift test --traits Zenzai -c release -Xswiftc -strict-concurrency=complete
```

### ZenzaiCoreML traitでテスト

```bash
swift test --traits ZenzaiCoreML -c release -Xswiftc -strict-concurrency=complete
```

## Cliツール

デバッグ用のCliツールとして`anco`コマンドがあります。`install_cli.sh`を実行してインストールしてください。場合によっては、`sudo`が必要です。

```bash
sh install_cli.sh
```

詳しくは[cli.md](./cli.md)をお読みください。

## DevContainer

開発にDevContainerを利用できます。詳しくは[devcontainer.md](./devcontainer.md)をお読みください。

## Zenzai / CoreML開発

ZenzaiやCoreMLバックエンドの開発については、以下のドキュメントを参照してください：
- [zenzai.md](./zenzai.md) - Zenzai使用方法
- [ZenzAvailability.md](./ZenzAvailability.md) - CoreML可用性ガイドライン

## コントリビュート

コントリビュートは歓迎です！プルリクエストを送る前に、以下を確認してください：
- Swift 6 strict concurrency checkingでビルドが通ること
- テストが全て成功すること
- コードがSwiftLintのルールに従っていること
