import Foundation
#if canImport(SwiftyMarisa)
import SwiftyMarisa

/// Base64 でエンコードされた Key-Value をデコードする関数
private func decodeKeyValue(_ suffix: some Collection<Int8>) -> UInt32? {
    // 最初の5個が値をエンコードしている
    let d = Int(Int8.max - 1)
    var value = 0
    for item in suffix.prefix(5) {
        value *= d
        value += Int(item) - 1
    }
    return UInt32(value)
}

/// Kneser-Ney 言語モデル
public struct EfficientNGram {
    public let n: Int
    public let d: Double

    // Tries
    let c_abc: Marisa
    let u_abx: Marisa
    let u_xbc: Marisa
    let r_xbx: Marisa

    private var tokenizer: ZenzTokenizer

    public init(baseFilename: String, n: Int, d: Double, tokenizer: ZenzTokenizer) {
        self.tokenizer = tokenizer
        // ストアドプロパティを一度に全て初期化（“仮”の値で OK）
        self.n = n
        self.d = d

        self.c_abc = Marisa()
        self.u_abx = Marisa()
        self.u_xbc = Marisa()
        self.r_xbx = Marisa()

        c_abc.load("\(baseFilename)_c_abc.marisa")
        u_abx.load("\(baseFilename)_u_abx.marisa")
        u_xbc.load("\(baseFilename)_u_xbc.marisa")
        r_xbx.load("\(baseFilename)_r_xbx.marisa")
    }

    /// Trie から Key に対応する Value を取得する関数
    private func getValue(from trie: Marisa, key: [Int]) -> UInt32? {
        let int8s = SwiftTrainer.encodeKey(key: key) + [SwiftTrainer.keyValueDelimiter] // delimiter ( as it is negative, it must not appear in key part)
        let results = trie.search(int8s, .predictive)
        for result in results {
            if let decoded = decodeKeyValue(result.dropFirst(int8s.count)) {
                return decoded
            }
        }
        return nil
    }

    /// 「prefix + 次の1文字」を扱うケースでbulk処理で高速化する
    private func bulkGetValueWithSum(from trie: Marisa, prefix: [Int]) -> (values: [UInt32], sum: UInt32) {
        let int8s = SwiftTrainer.encodeKey(key: prefix) + [SwiftTrainer.predictiveDelimiter]  // 予測用のdelimiter
        let results = trie.search(int8s, .predictive)
        var dict = [UInt32](repeating: 0, count: self.tokenizer.vocabSize)
        var sum: UInt32 = 0
        for result in results {
            var suffix = result.dropFirst(int8s.count)
            let v1 = suffix.removeFirst()
            let v2 = suffix.removeFirst()
            // delimiterを除去
            if suffix.first != SwiftTrainer.keyValueDelimiter {
                continue
            }
            suffix.removeFirst()
            if let decoded = decodeKeyValue(suffix) {
                let word = SwiftTrainer.decodeKey(v1: v1, v2: v2)
                dict[word] = decoded
                sum += decoded
            }
        }
        return (dict, sum)
    }

    /// Kneser-Ney Smoothingを入れたNgram LMの実装
    func predict(
        nextWord: Int,
        c_abx_ab: UInt32,
        u_abx_ab: UInt32,
        c_abc_abc: UInt32,
        plf_items: [(
            u_xbc_abc: [UInt32],
            u_xbx_ab: UInt32,
            r_xbx_ab: UInt32
        )]
    ) -> Double {
        // ngram = [a, b, c]
        // abc = "a|b|c"
        // ab  = "a|b"
        let alpha, gamma: Double
        if c_abx_ab != 0 {
            alpha = max(0, Double(c_abc_abc) - self.d) / Double(c_abx_ab)
            gamma = self.d * Double(u_abx_ab) / Double(c_abx_ab)
        } else {
            alpha = 0
            gamma = 1
        }

        // predict_lowerの処理
        var plf = 0.0
        var coef = 1.0
        for (u_xbc_abc, u_xbx_ab, r_xbx_ab) in plf_items {
            let alpha, gamma: Double
            if u_xbx_ab > 0 {
                alpha = max(0, Double(u_xbc_abc[nextWord]) - self.d) / Double(u_xbx_ab)
                gamma = self.d * Double(r_xbx_ab) / Double(u_xbx_ab)
            } else {
                alpha = 0
                gamma = 1
            }
            plf += alpha * coef
            coef *= gamma
        }
        plf += coef / Double(self.tokenizer.vocabSize)

        let prob = alpha + gamma * plf
        return prob
    }

    /// Kneser-Ney の確率を求める
    public func bulkPredict(_ ngram: some BidirectionalCollection<Int>) -> [Double] {
        // abがn-1個の要素を持つように調整する
        let ab = if ngram.count > self.n - 1 {
            Array(ngram.suffix(self.n - 1))
        } else if ngram.count == self.n - 1 {
            Array(ngram)
        } else {
            Array(repeating: self.tokenizer.startTokenID, count: self.n - 1 - ngram.count) + Array(ngram)
        }
        let u_abx_ab  = self.getValue(from: u_abx, key: ab) ?? 0
        let (c_abc_abc, c_abx_ab) = self.bulkGetValueWithSum(from: self.c_abc, prefix: ab)
        var plf_items: [(u_xbc_abc: [UInt32], u_xbx_ab: UInt32, r_xbx_ab: UInt32)] = []
        for i in 1 ..< self.n - 1 {
            let ab = Array(ab.dropFirst(i))
            let r_xbx_ab = self.getValue(from: self.r_xbx, key: ab) ?? 0
            let (u_xbc_abc, u_xbx_ab) = self.bulkGetValueWithSum(from: self.u_xbc, prefix: ab)
            plf_items.append((u_xbc_abc: u_xbc_abc, u_xbx_ab: u_xbx_ab, r_xbx_ab: r_xbx_ab))
        }
        // 全候補を探索
        var results = [Double]()
        results.reserveCapacity(tokenizer.vocabSize)
        for w in 0 ..< tokenizer.vocabSize {
            results.append(self.predict(nextWord: w, c_abx_ab: c_abx_ab, u_abx_ab: u_abx_ab, c_abc_abc: c_abc_abc[w], plf_items: plf_items))
        }
        return results
    }
}

/// テキスト生成
package func generateText(
    inputText: String,
    mixAlpha: Double,
    lmBase: EfficientNGram,
    lmPerson: EfficientNGram,
    tokenizer: ZenzTokenizer,
    maxCount: Int = 100
) -> String
{
    // もともとの文字列を配列化
    var tokens = tokenizer.encode(text: inputText)
    // suffix を事前に取り出す
    var suffix = tokens.suffix(lmBase.n - 1)

    while tokens.count < maxCount {
        var maxProb = -Double.infinity
        var nextWord = -1

        // 全候補を探索
        let pBases = lmBase.bulkPredict(suffix)
        let pPersons = lmPerson.bulkPredict(suffix)
        for (w, (pBase, pPerson)) in zip(pBases, pPersons).enumerated() {
            // どちらかが 0 ならスキップ
            if pBase == 0.0 || pPerson == 0.0 {
                continue
            }

            let mixLogProb = (1 - mixAlpha) * log2(pBase) + mixAlpha * log2(pPerson)

            if mixLogProb > maxProb {
                maxProb = mixLogProb
                nextWord = w
            }
        }

        // 候補なし or EOS なら生成終了
        if nextWord == -1 || nextWord == tokenizer.endTokenID {
            break
        }

        // 1文字単位のモデルなら append で文字列に追加
        // (単語単位なら間にスペースを入れる等の工夫が必要)
        tokens.append(nextWord)

        // suffix を更新
        suffix.append(nextWord)
        if suffix.count > (lmBase.n - 1) {
            suffix.removeFirst()
        }
    }
    return tokenizer.decode(tokens: tokens)
}
#else
/// Mock Implementation
public struct EfficientNGram {
    public init(baseFilename: String, n: Int, d: Double, tokenizer: ZenzTokenizer) {}
    public func bulkPredict(_ ngram: some BidirectionalCollection<Int>) -> [Double] {
        // FIXME: avoid hard-coding
        return [Double].init(repeating: 1/6000, count: 6000)
    }
}

package func generateText(
    inputText: String,
    mixAlpha: Double,
    lmBase: EfficientNGram,
    lmPerson: EfficientNGram,
    tokenizer: ZenzTokenizer,
    maxCount: Int = 100
) -> String {
    return "[Error] Unsupported"
}
#endif
