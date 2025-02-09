import Foundation
#if canImport(SwiftyMarisa)
import SwiftyMarisa

final class SwiftTrainer {
    static let keyValueDelimiter: Int8 = Int8.min
    static let predictiveDelimiter: Int8 = Int8.min + 1
    let n: Int
    let tokenizer: ZenzTokenizer

    /// Python の defaultdict(int) 相当
    private var c_abc = [[Int]: Int]()
    private var u_abx = [[Int]: Int]()
    private var u_xbc = [[Int]: Int]()
    /// Python の defaultdict(set) 相当
    private var s_xbx = [[Int]: Set<Int>]()

    init(n: Int, tokenizer: ZenzTokenizer) {
        self.n = n
        self.tokenizer = tokenizer
    }

    /// 単一 n-gram (abc など) をカウント
    /// Python の count_ngram に対応
    private func countNGram(_ ngram: some BidirectionalCollection<Int>) {
        // n-gram は最低 2 token 必要 (式的に aB, Bc, B, c のような分割を行う)
        guard ngram.count >= 2 else { return }

        let aBc = Array(ngram)             // abc
        let aB  = Array(ngram.dropLast())  // ab
        let Bc  = Array(ngram.dropFirst()) // bc
        // 中央部分 B, 末尾単語 c
        let B   = Array(ngram.dropFirst().dropLast())
        let c   = ngram.last!

        // C(abc)
        c_abc[aBc, default: 0] += 1

        // 初回登場なら U(...) を更新
        if c_abc[aBc] == 1 {
            // U(ab・)
            u_abx[aB, default: 0] += 1
            // U(・bc)
            u_xbc[Bc, default: 0] += 1
        }
        // s_xbx[B] = s_xbx[B] ∪ {c}
        s_xbx[B, default: Set()].insert(c)
    }

    /// 文から n-gram をカウント
    /// Python の count_sent_ngram に対応
    private func countSentNGram(n: Int, sent: [Int]) {
        // 先頭に (n-1) 個の <s>、末尾に </s> を追加
        let padded = Array(repeating: self.tokenizer.startTokenID, count: n - 1) + sent + [self.tokenizer.endTokenID]
        // スライディングウィンドウで n 個ずつ
        for i in 0..<(padded.count - n + 1) {
            countNGram(padded[i..<i+n])
        }
    }

    /// 文全体をカウント (2-gram～N-gram までをまとめて処理)
    /// Python の count_sent に対応
    func countSent(_ sentence: String) {
        let tokens = self.tokenizer.encode(text: sentence)
        for k in 2...n {
            countSentNGram(n: k, sent: tokens)
        }
    }

    static func encodeKey(key: [Int]) -> [Int8] {
        var int8s: [Int8] = []
        int8s.reserveCapacity(key.count * 2 + 1)
        for token in key {
            let (q, r) = token.quotientAndRemainder(dividingBy: Int(Int8.max - 1))
            int8s.append(Int8(q + 1))
            int8s.append(Int8(r + 1))
        }
        return int8s
    }
    static func encodeValue(value: Int) -> [Int8] {
        let div = Int(Int8.max - 1)
        let (q1, r1) = value.quotientAndRemainder(dividingBy: div)  // value = q1 * div + r1
        let (q2, r2) = q1.quotientAndRemainder(dividingBy: div)  // value = (q2 * div + r2) * div + r1 = q2 d² + r2 d + r1
        let (q3, r3) = q2.quotientAndRemainder(dividingBy: div)  // value = q3 d³ + r3 d² + r2 d + r1
        let (q4, r4) = q3.quotientAndRemainder(dividingBy: div)  // value = q4 d⁴ + r4 d³ + r3 d² + r2 d + r1
        return [Int8(q4 + 1), Int8(r4 + 1), Int8(r3 + 1), Int8(r2 + 1), Int8(r1 + 1)]
    }

    static func decodeKey(v1: Int8, v2: Int8) -> Int {
        return Int(v1-1) * Int(Int8.max-1) + Int(v2-1)
    }
    /// 文字列 + 4バイト整数を Base64 にエンコードした文字列を作る
    /// Python の encode_key_value(key, value) 相当
    private func encodeKeyValue(key: [Int], value: Int) -> [Int8] {
        let key = Self.encodeKey(key: key)
        return key + [Self.keyValueDelimiter] + Self.encodeValue(value: value)
    }

    private func encodeKeyValueForBulkGet(key: [Int], value: Int) -> [Int8] {
        var key = Self.encodeKey(key: key)
        key.insert(Self.predictiveDelimiter, at: key.count - 2)  // 1トークンはInt8が2つで表せる。最後のトークンの直前にデリミタ`Int8.min + 1`を入れ、これを用いて予測検索をする
        return key + [Self.keyValueDelimiter] + Self.encodeValue(value: value)
    }

    /// 指定した [[Int]: Int] を Trie に登録して保存
    private func buildAndSaveTrie(from dict: [[Int]: Int], to path: String, forBulkGet: Bool = false) {
        let encode = forBulkGet ? encodeKeyValueForBulkGet : encodeKeyValue
        let encodedStrings: [[Int8]] = dict.map(encode)
        let trie = Marisa()
        trie.build { builder in
            for entry in encodedStrings {
                builder(entry)
            }
        }
        trie.save(path)
        print("Saved \(path): \(encodedStrings.count) entries")
    }


    /// 上記のカウント結果を marisa ファイルとして保存
    func saveToMarisaTrie(baseFilename: String, outputDir: String? = nil) {
        let fileManager = FileManager.default

        // 出力フォルダの設定（デフォルト: ~/Library/Application Support/SwiftNGram/marisa/）
        let marisaDir: URL
        if let outputDir = outputDir {
            marisaDir = URL(fileURLWithPath: outputDir)
        } else {
            let libraryDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            marisaDir = libraryDir.appendingPathComponent("SwiftNGram/marisa", isDirectory: true)
        }

        // フォルダがない場合は作成
        do {
            try fileManager.createDirectory(
                at: marisaDir,
                withIntermediateDirectories: true,  // 中間ディレクトリも作成
                attributes: nil
            )
        } catch {
            print("ディレクトリ作成エラー: \(error)")
            return
        }
        
        // ファイルパスの生成（marisa ディレクトリ内に配置）
        let paths = [
            "\(baseFilename)_c_abc.marisa",
            "\(baseFilename)_u_abx.marisa",
            "\(baseFilename)_u_xbc.marisa",
            "\(baseFilename)_r_xbx.marisa",
        ].map { file in
            marisaDir.appendingPathComponent(file).path
        }

        // 各 Trie ファイルを保存
        buildAndSaveTrie(from: c_abc, to: paths[0], forBulkGet: true)
        buildAndSaveTrie(from: u_abx, to: paths[1])
        buildAndSaveTrie(from: u_xbc, to: paths[2], forBulkGet: true)

        let r_xbx: [[Int]: Int] = s_xbx.mapValues { $0.count }
        buildAndSaveTrie(from: r_xbx, to: paths[3])

        // **絶対パスでの出力**
        print("All saved files (absolute paths):")
        for path in paths {
            print(path)
        }
    }

}

/// ファイルを読み込み、行ごとの文字列配列を返す関数
public func readLinesFromFile(filePath: String) -> [String]? {
    guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
        print("[Error] ファイルを開けませんでした: \(filePath)")
        return nil
    }
    defer {
        try? fileHandle.close()
    }
    // UTF-8 でデータを読み込む
    let data = fileHandle.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        print("[Error] UTF-8 で読み込めませんでした: \(filePath)")
        return nil
    }
    // 改行で分割し、空行を除去
    return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
}

/// 文章の配列から n-gram を学習し、Marisa-Trie を保存する関数
public func trainNGram(
    lines: [String],
    n: Int,
    baseFilename: String,
    outputDir: String? = nil
) {
    let tokenizer = ZenzTokenizer()
    let trainer = SwiftTrainer(n: n, tokenizer: tokenizer)

    for (i, line) in lines.enumerated() {
        if i % 100 == 0 {
            print(i, "/", lines.count)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            trainer.countSent(trimmed)
        }
    }

    // Trie ファイルを保存（出力フォルダを渡す）
    trainer.saveToMarisaTrie(baseFilename: baseFilename, outputDir: outputDir)
}

/// 実行例: ファイルを読み込み、n-gram を学習して保存
public func trainNGramFromFile(filePath: String, n: Int, baseFilename: String, outputDir: String? = nil) {
    guard let lines = readLinesFromFile(filePath: filePath) else {
        return
    }
    trainNGram(lines: lines, n: n, baseFilename: baseFilename, outputDir: outputDir)
}
#else
public func trainNGramFromFile(filePath: String, n: Int, baseFilename: String, outputDir: String? = nil) {
    fatalError("[Error] trainNGramFromFile is unsupported.")
}
#endif
