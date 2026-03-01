import Foundation
#if canImport(SwiftyMarisa) && Zenzai
import SwiftyMarisa

private struct NGramKey: Hashable {
    private static let inlineCapacity = 8

    private let count: Int
    private let t0: Int
    private let t1: Int
    private let t2: Int
    private let t3: Int
    private let t4: Int
    private let t5: Int
    private let t6: Int
    private let t7: Int
    private let overflow: [Int]?

    init(_ tokens: some Collection<Int>) {
        let tokenCount = tokens.count
        self.count = tokenCount
        if tokenCount <= Self.inlineCapacity {
            var i = 0
            var v0 = 0
            var v1 = 0
            var v2 = 0
            var v3 = 0
            var v4 = 0
            var v5 = 0
            var v6 = 0
            var v7 = 0
            for token in tokens {
                switch i {
                case 0: v0 = token
                case 1: v1 = token
                case 2: v2 = token
                case 3: v3 = token
                case 4: v4 = token
                case 5: v5 = token
                case 6: v6 = token
                case 7: v7 = token
                default: break
                }
                i += 1
            }
            self.t0 = v0
            self.t1 = v1
            self.t2 = v2
            self.t3 = v3
            self.t4 = v4
            self.t5 = v5
            self.t6 = v6
            self.t7 = v7
            self.overflow = nil
        } else {
            self.t0 = 0
            self.t1 = 0
            self.t2 = 0
            self.t3 = 0
            self.t4 = 0
            self.t5 = 0
            self.t6 = 0
            self.t7 = 0
            self.overflow = Array(tokens)
        }
    }

    func toArray() -> [Int] {
        if let overflow {
            return overflow
        }
        var result: [Int] = []
        result.reserveCapacity(count)
        if count > 0 { result.append(t0) }
        if count > 1 { result.append(t1) }
        if count > 2 { result.append(t2) }
        if count > 3 { result.append(t3) }
        if count > 4 { result.append(t4) }
        if count > 5 { result.append(t5) }
        if count > 6 { result.append(t6) }
        if count > 7 { result.append(t7) }
        return result
    }

    @inline(__always)
    var tokenCount: Int { count }

    @inline(__always)
    func forEachToken(_ body: (Int) -> Void) {
        if let overflow {
            for token in overflow {
                body(token)
            }
            return
        }
        if count > 0 { body(t0) }
        if count > 1 { body(t1) }
        if count > 2 { body(t2) }
        if count > 3 { body(t3) }
        if count > 4 { body(t4) }
        if count > 5 { body(t5) }
        if count > 6 { body(t6) }
        if count > 7 { body(t7) }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        if let overflow {
            for token in overflow {
                hasher.combine(token)
            }
            return
        }
        if count > 0 { hasher.combine(t0) }
        if count > 1 { hasher.combine(t1) }
        if count > 2 { hasher.combine(t2) }
        if count > 3 { hasher.combine(t3) }
        if count > 4 { hasher.combine(t4) }
        if count > 5 { hasher.combine(t5) }
        if count > 6 { hasher.combine(t6) }
        if count > 7 { hasher.combine(t7) }
    }

    static func == (lhs: NGramKey, rhs: NGramKey) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if let lo = lhs.overflow, let ro = rhs.overflow {
            return lo == ro
        }
        if lhs.overflow != nil || rhs.overflow != nil {
            return lhs.toArray() == rhs.toArray()
        }
        if lhs.count > 0, lhs.t0 != rhs.t0 { return false }
        if lhs.count > 1, lhs.t1 != rhs.t1 { return false }
        if lhs.count > 2, lhs.t2 != rhs.t2 { return false }
        if lhs.count > 3, lhs.t3 != rhs.t3 { return false }
        if lhs.count > 4, lhs.t4 != rhs.t4 { return false }
        if lhs.count > 5, lhs.t5 != rhs.t5 { return false }
        if lhs.count > 6, lhs.t6 != rhs.t6 { return false }
        if lhs.count > 7, lhs.t7 != rhs.t7 { return false }
        return true
    }
}

final class SwiftTrainer {
    static let keyValueDelimiter: Int8 = Int8.min
    static let predictiveDelimiter: Int8 = Int8.min + 1
    let n: Int
    let minCount: Int
    let tokenizer: ZenzTokenizer

    private var c_abc = [NGramKey: Int]()
    private var c_bc  = Set<NGramKey>()
    private var u_abx = [NGramKey: Int]()
    private var u_xbc = [NGramKey: Int]()
    private var r_xbx = [NGramKey: Int]()

    init(n: Int, tokenizer: ZenzTokenizer, minCount: Int = 1) {
        self.n = n
        self.minCount = max(1, minCount)
        self.tokenizer = tokenizer
    }

    init(baseFilePattern: String, n: Int, tokenizer: ZenzTokenizer, minCount: Int = 1) {
        self.tokenizer = tokenizer
        self.n = n
        self.minCount = max(1, minCount)
        self.c_abc = Self.loadDictionary(from: "\(baseFilePattern)_c_abc.marisa", minCount: self.minCount)
        self.c_bc  = Self.loadKeySet(from: "\(baseFilePattern)_c_bc.marisa")
        self.u_abx = Self.loadDictionary(from: "\(baseFilePattern)_u_abx.marisa", minCount: self.minCount)
        self.u_xbc = Self.loadDictionary(from: "\(baseFilePattern)_u_xbc.marisa", minCount: self.minCount)
        self.r_xbx = Self.loadDictionary(from: "\(baseFilePattern)_r_xbx.marisa", minCount: self.minCount)
    }

    @inline(__always)
    private static func incrementAndCheckFirst(_ value: inout Int) -> Bool {
        let isFirst = (value == 0)
        value += 1
        return isFirst
    }

    /// 単一 n-gram (abc など) をカウント
    /// Python の count_ngram に対応
    private func countNGram(_ ngram: ArraySlice<Int>) {
        // n-gram は最低 2 token 必要 (式的に aB, Bc, B, c のような分割を行う)
        guard ngram.count >= 2 else { return }

        let aBc = NGramKey(ngram)             // abc
        let Bc  = NGramKey(ngram.dropFirst()) // bc
        let isFirstABC = Self.incrementAndCheckFirst(&c_abc[aBc, default: 0])
        let isFirstBC = c_bc.insert(Bc).inserted

        if isFirstABC {
            let aB  = NGramKey(ngram.dropLast())  // ab
            // U(ab・)
            u_abx[aB, default: 0] += 1
            // U(・bc)
            u_xbc[Bc, default: 0] += 1
        }

        if isFirstBC {
            // s_xbx[B] = s_xbx[B] ∪ {c}
            let B = NGramKey(ngram.dropFirst().dropLast())
            r_xbx[B, default: 0] += 1
        }
    }

    /// 文から n-gram をカウント
    /// Python の count_sent_ngram に対応
    private func countSentNGram(n: Int, sent: [Int]) {
        // 先頭に (n-1) 個の <s>、末尾に </s> を追加
        let padded = Array(repeating: self.tokenizer.startTokenID, count: n - 1) + sent + [self.tokenizer.endTokenID]
        // スライディングウィンドウで n 個ずつ
        for i in 0..<(padded.count - n + 1) {
            countNGram(padded[i..<i + n])
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
        Int(v1 - 1) * Int(Int8.max - 1) + Int(v2 - 1)
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

    @inline(__always)
    private func appendEncodedKey(_ key: NGramKey, to output: inout [Int8], forBulkGet: Bool) {
        let div = Int(Int8.max - 1)
        let insertBeforeLastTokenIndex = (forBulkGet && key.tokenCount > 0) ? (key.tokenCount - 1) : -1
        var i = 0
        key.forEachToken { token in
            if i == insertBeforeLastTokenIndex {
                output.append(Self.predictiveDelimiter)
            }
            let (q, r) = token.quotientAndRemainder(dividingBy: div)
            output.append(Int8(q + 1))
            output.append(Int8(r + 1))
            i += 1
        }
    }

    private func encodeKeyValue(key: NGramKey, value: Int) -> [Int8] {
        var output: [Int8] = []
        output.reserveCapacity(key.tokenCount * 2 + 1 + 5)
        appendEncodedKey(key, to: &output, forBulkGet: false)
        output.append(Self.keyValueDelimiter)
        output.append(contentsOf: Self.encodeValue(value: value))
        return output
    }

    private func encodeKeyValueForBulkGet(key: NGramKey, value: Int) -> [Int8] {
        var output: [Int8] = []
        output.reserveCapacity(key.tokenCount * 2 + 2 + 5)
        appendEncodedKey(key, to: &output, forBulkGet: true)
        output.append(Self.keyValueDelimiter)
        output.append(contentsOf: Self.encodeValue(value: value))
        return output
    }

    private static func loadDictionary(from path: String, minCount: Int = 1) -> [NGramKey: Int] {
        let trie = Marisa()
        trie.load(path)
        // 空キーで predict 検索するとうまくいかないので、分割して検索する
        var dict = [NGramKey: Int]()
        for i in Int8(0) ..< Int8.max {
            for encodedEntry in trie.search([i], .predictive) {
                if let (key, value) = Self.decodeEncodedEntry(encoded: encodedEntry) {
                    if value >= minCount {
                        dict[NGramKey(key)] = value
                    }
                }
            }
        }
        return dict
    }

    private static func loadKeySet(from path: String) -> Set<NGramKey> {
        let trie = Marisa()
        trie.load(path)
        var keys = Set<NGramKey>()
        for i in Int8(0) ..< Int8.max {
            for encodedEntry in trie.search([i], .predictive) {
                if let (key, _) = Self.decodeEncodedEntry(encoded: encodedEntry) {
                    keys.insert(NGramKey(key))
                }
            }
        }
        return keys
    }

    /// エンコードされたエントリを [key, value] に復元
    private static func decodeEncodedEntry(encoded: [Int8]) -> ([Int], Int)? {
        guard let delimiterIndex = encoded.firstIndex(of: keyValueDelimiter) else {
            return nil
        }
        let keyEncoded = encoded[..<delimiterIndex]
        let valueEncoded = encoded[(delimiterIndex + 1)...]

        // bulk get 用の delimiter は削除（存在しなければ無視）
        let filteredKeyEncoded = keyEncoded.filter { $0 != predictiveDelimiter }

        // key は (v1, v2) ペアの繰り返しでエンコードしていた
        guard filteredKeyEncoded.count % 2 == 0 else {
            return nil
        }
        var key: [Int] = []
        var index = filteredKeyEncoded.startIndex
        while index < filteredKeyEncoded.endIndex {
            let token = decodeKey(
                v1: filteredKeyEncoded[index],
                v2: filteredKeyEncoded[filteredKeyEncoded.index(after: index)]
            )
            key.append(token)
            index = filteredKeyEncoded.index(index, offsetBy: 2)
        }

        // value は常に5バイト
        guard valueEncoded.count == 5 else { return nil }
        let d = Int(Int8.max - 1)
        var value = 0
        for item in valueEncoded {
            value = value * d + (Int(item) - 1)
        }

        return (key, value)
    }

    /// 指定した [[Int]: Int] を Trie に登録して保存
    private func buildAndSaveTrie(from dict: [NGramKey: Int], to path: String, forBulkGet: Bool = false) {
        let trie = Marisa()
        trie.build { builder in
            if forBulkGet {
                for (key, value) in dict {
                    builder(encodeKeyValueForBulkGet(key: key, value: value))
                }
            } else {
                for (key, value) in dict {
                    builder(encodeKeyValue(key: key, value: value))
                }
            }
        }
        trie.save(path)
        print("Saved \(path): \(dict.count) entries")
    }

    /// キー集合を value=1 で保存（c_bc 用）
    private func buildAndSaveTrie(from keys: Set<NGramKey>, to path: String, forBulkGet: Bool = false) {
        let trie = Marisa()
        trie.build { builder in
            if forBulkGet {
                for key in keys {
                    builder(encodeKeyValueForBulkGet(key: key, value: 1))
                }
            } else {
                for key in keys {
                    builder(encodeKeyValue(key: key, value: 1))
                }
            }
        }
        trie.save(path)
        print("Saved \(path): \(keys.count) entries")
    }

    private static func filteredByMinCount(_ dict: [NGramKey: Int], minCount: Int) -> [NGramKey: Int] {
        guard minCount > 1 else { return dict }
        var filtered: [NGramKey: Int] = [:]
        filtered.reserveCapacity(dict.count)
        for (key, value) in dict where value >= minCount {
            filtered[key] = value
        }
        return filtered
    }

    /// 上記のカウント結果を marisa ファイルとして保存
    func saveToMarisaTrie(baseFilePattern: String, outputDir: String? = nil) {
        let fileManager = FileManager.default

        // 出力フォルダの設定（デフォルト: ~/Library/Application Support/SwiftNGram/marisa/）
        let marisaDir: URL
        if let outputDir {
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
            "\(baseFilePattern)_c_abc.marisa",
            "\(baseFilePattern)_c_bc.marisa",
            "\(baseFilePattern)_u_abx.marisa",
            "\(baseFilePattern)_u_xbc.marisa",
            "\(baseFilePattern)_r_xbx.marisa"
        ].map { file in
            marisaDir.appendingPathComponent(file).path
        }

        // 各 Trie ファイルを保存
        let cABCToSave = Self.filteredByMinCount(c_abc, minCount: self.minCount)
        let uABXToSave = Self.filteredByMinCount(u_abx, minCount: self.minCount)
        let uXBCToSave = Self.filteredByMinCount(u_xbc, minCount: self.minCount)
        let rXBXToSave = Self.filteredByMinCount(r_xbx, minCount: self.minCount)

        buildAndSaveTrie(from: cABCToSave, to: paths[0], forBulkGet: true)
        // c_bc は resume 時の既知BC管理に使うため、しきい値で削らず保存する
        buildAndSaveTrie(from: c_bc, to: paths[1])
        buildAndSaveTrie(from: uABXToSave, to: paths[2])
        buildAndSaveTrie(from: uXBCToSave, to: paths[3], forBulkGet: true)
        buildAndSaveTrie(from: rXBXToSave, to: paths[4])

        // **絶対パスでの出力**
        print("All saved files (absolute paths):")
        for path in paths {
            print(path)
        }
    }
}

private func streamUTF8Lines(filePath: String, handleLine: (String) -> Void) -> Bool {
    guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
        print("[Error] ファイルを開けませんでした: \(filePath)")
        return false
    }
    defer {
        try? fileHandle.close()
    }

    let chunkSize = 1 << 20  // 1 MiB
    var buffer = Data()
    buffer.reserveCapacity(chunkSize * 2)

    while true {
        let chunk = fileHandle.readData(ofLength: chunkSize)
        if chunk.isEmpty {
            break
        }
        buffer.append(chunk)

        var lineStart = buffer.startIndex
        while let lineBreak = buffer[lineStart...].firstIndex(of: 0x0A) {  // '\n'
            var lineEnd = lineBreak
            if lineEnd > lineStart, buffer[buffer.index(before: lineEnd)] == 0x0D {  // '\r\n'
                lineEnd = buffer.index(before: lineEnd)
            }
            let line = String(decoding: buffer[lineStart..<lineEnd], as: UTF8.self)
            handleLine(line)
            lineStart = buffer.index(after: lineBreak)
        }

        if lineStart > buffer.startIndex {
            buffer.removeSubrange(..<lineStart)
        }
    }

    if !buffer.isEmpty {
        let line = String(decoding: buffer, as: UTF8.self)
        handleLine(line)
    }
    return true
}

/// ファイルを読み込み、行ごとの文字列配列を返す関数
public func readLinesFromFile(filePath: String) -> [String]? {
    var lines: [String] = []
    let success = streamUTF8Lines(filePath: filePath) { line in
        if !line.isEmpty {
            lines.append(line)
        }
    }
    return success ? lines : nil
}

/// 文章の配列から n-gram を学習し、Marisa-Trie を保存する関数
public func trainNGram(
    lines: [String],
    n: Int,
    baseFilePattern: String,
    outputDir: String? = nil,
    resumeFilePattern: String? = nil,
    minCount: Int = 1
) {
    let printInterval = 1000
    let tokenizer = ZenzTokenizer()
    let effectiveMinCount = max(1, minCount)
    let trainer = if let resumeFilePattern {
        SwiftTrainer(baseFilePattern: resumeFilePattern, n: n, tokenizer: tokenizer, minCount: effectiveMinCount)
    } else {
        SwiftTrainer(n: n, tokenizer: tokenizer, minCount: effectiveMinCount)
    }

    for (i, line) in lines.enumerated() {
        if i % printInterval == 0 {
            print(i, "/", lines.count)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            trainer.countSent(trimmed)
        }
    }

    // Trie ファイルを保存（出力フォルダを渡す）
    trainer.saveToMarisaTrie(baseFilePattern: baseFilePattern, outputDir: outputDir)
}

/// 実行例: ファイルを読み込み、n-gram を学習して保存
public func trainNGramFromFile(
    filePath: String,
    n: Int,
    baseFilePattern: String,
    outputDir: String? = nil,
    resumeFilePattern: String? = nil,
    minCount: Int = 1
) {
    let tokenizer = ZenzTokenizer()
    let effectiveMinCount = max(1, minCount)
    let trainer = if let resumeFilePattern {
        SwiftTrainer(baseFilePattern: resumeFilePattern, n: n, tokenizer: tokenizer, minCount: effectiveMinCount)
    } else {
        SwiftTrainer(n: n, tokenizer: tokenizer, minCount: effectiveMinCount)
    }

    var index = 0
    let success = streamUTF8Lines(filePath: filePath) { line in
        if index % 100 == 0 {
            print(index)
        }
        index += 1

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            trainer.countSent(trimmed)
        }
    }
    guard success else {
        return
    }

    trainer.saveToMarisaTrie(baseFilePattern: baseFilePattern, outputDir: outputDir)
}
#else
public func trainNGramFromFile(filePath _: String, n _: Int, baseFilePattern _: String, outputDir _: String? = nil, resumeFilePattern _: String? = nil, minCount _: Int = 1) {
    fatalError("[Error] trainNGramFromFile is unsupported.")
}
#endif
