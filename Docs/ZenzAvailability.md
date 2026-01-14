## Zenz / CoreML の可用性ガイドライン

[English](./ZenzAvailability.en.md) | **日本語** | [한국어](./ZenzAvailability.ko.md)

AzooKey の Zenz 関連コードは複数プラットフォームで動作させる必要があります。
下記のルールを守ることで、`#if` ガードや `@available` が散逸せず、保守性を維持できます。

1. **共通ロジックは常に公開する**  
   `PrefixConstraint` やラティス構築、候補レビューなど CoreML 以外でも使う機能は `#if ZenzaiCoreML` / `@available` で隠さない。`FullInputProcessingWithPrefixConstraint.swift` や `zenzai.swift` は常にビルド対象にする。

2. **CoreML 専用の入口だけをガードする**  
   CoreML バックエンド、`ZenzContext+CoreML`、`ZenzCoreMLService` など実際に CoreML ランタイムを必要とする箇所だけに `#if ZenzaiCoreML && canImport(CoreML)` + `@available(iOS 18, macOS 15, *)` を付ける。呼び出し側は `coreMLService?.convert(...)` のように単一の入口経由で利用する。

3. **実行時判定はサービスに閉じ込める**  
   `KanaKanjiConverter` 本体は CoreML の有無を意識せず、`ZenzCoreMLService` が `#available` 判定やモデルキャッシュ管理を担当する。他プラットフォームではサービスが `nil` となり、既存の処理経路がそのまま使える構成にする。

4. **新しいコードを追加したら本書を更新する**  
   CoreML 専用ファイルや可用性ルールに変更があれば、必ずこのドキュメントを更新して意図を共有する。
