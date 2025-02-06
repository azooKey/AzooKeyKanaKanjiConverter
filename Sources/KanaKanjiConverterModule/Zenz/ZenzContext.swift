#if canImport(llama)
import llama
#else
import llama_mock
#endif
import SwiftUtils
import HeapModule
import Algorithms
import Foundation

struct FixedSizeHeap<Element: Comparable> {
    private var size: Int
    private var heap: Heap<Element>

    init(size: Int) {
        self.size = size
        self.heap = []
    }

    mutating func removeMax() {
        self.heap.removeMax()
    }

    mutating func removeMin() {
        self.heap.removeMin()
    }

    @discardableResult
    mutating func insertIfPossible(_ element: Element) -> Bool {
        if self.heap.count < self.size {
            self.heap.insert(element)
            return true
        } else if let min = self.heap.min, element > min {
            self.heap.replaceMin(with: element)
            return true
        } else {
            return false
        }
    }

    var unordered: [Element] {
        self.heap.unordered
    }

    var max: Element? {
        self.heap.max
    }

    var min: Element? {
        self.heap.min
    }

    var isEmpty: Bool {
        self.heap.isEmpty
    }
}

enum ZenzError: LocalizedError {
    case couldNotLoadModel(path: String)
    case couldNotLoadContext

    var errorDescription: String? {
        switch self {
        case .couldNotLoadContext: "failed to load context"
        case .couldNotLoadModel(path: let path): "could not load model weight at \(path)"
        }
    }
}

class ZenzContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var prevInput: [llama_token] = []

    private let n_len: Int32 = 512

    init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
    }

    deinit {
        llama_free(context)
        llama_free_model(model)
        llama_backend_free()
    }

    private static var ctx_params: llama_context_params {
        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        debug("Using \(n_threads) threads")
        var ctx_params = llama_context_default_params()
        ctx_params.seed = 1234
        ctx_params.n_ctx = 512
        ctx_params.n_threads       = UInt32(n_threads)
        ctx_params.n_threads_batch = UInt32(n_threads)
        ctx_params.n_batch = 512
        return ctx_params
    }

    static func createContext(path: String) throws -> ZenzContext {
        llama_backend_init()
        var model_params = llama_model_default_params()
        model_params.use_mmap = true
        let model = llama_load_model_from_file(path, model_params)
        guard let model else {
            debug("Could not load model at \(path)")
            throw ZenzError.couldNotLoadModel(path: path)
        }

        let context = llama_new_context_with_model(model, ctx_params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }

        return ZenzContext(model: model, context: context)
    }

    func reset_context() throws {
        llama_free(self.context)
        let context = llama_new_context_with_model(self.model, Self.ctx_params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }
        self.context = context
    }

    private func get_logits(tokens: [llama_token], logits_start_index: Int = 0) -> UnsafeMutablePointer<Float>? {
        // manage kv_cache
        do {
            let commonTokens = self.prevInput.commonPrefix(with: tokens)
            llama_kv_cache_seq_rm(context, 0, llama_pos(commonTokens.count), -1)
        }
        var batch = llama_batch_init(512, 0, 1)
        let n_ctx = llama_n_ctx(context)
        let n_kv_req = tokens.count + (Int(n_len) - tokens.count)
        if n_kv_req > n_ctx {
            debug("error: n_kv_req > n_ctx, the required KV cache size is not big enough")
        }
        for i in tokens.indices {
            llama_batch_add(&batch, tokens[i], Int32(i), [0], logits: logits_start_index <= i)
        }
        // 評価
        if llama_decode(context, batch) != 0 {
            debug("llama_decode() failed")
            return nil
        }
        return llama_get_logits(context)
    }

    func evaluate(text: String, ignorePrompt: String = "") -> Float {
        let tokens_list = self.tokenize(text: text, add_bos: true, add_eos: true)
        guard let logits = self.get_logits(tokens: tokens_list) else {
            debug("logits unavailable")
            return .nan
        }
        let tokenizedPromptCount = ignorePrompt.isEmpty ? 1 : tokenize(text: ignorePrompt, add_bos: true, add_eos: false).count
        let n_vocab = llama_n_vocab(model)

        var sum: Float = 0
        // 最初のプロンプト部分は無視する
        for (i, token_id) in tokens_list.indexed().dropFirst(tokenizedPromptCount) {
            // FIXME: there can be more efficient implementations, poossibly using Accelerate or other frameworks.
            var log_prob: Float = 0
            for index in ((i - 1) * Int(n_vocab)) ..< (i * Int(n_vocab)) {
                log_prob += expf(logits[index])
            }
            log_prob = logf(log_prob)
            log_prob = logits[Int((i - 1) * Int(n_vocab) + Int(token_id))] - log_prob
            sum += log_prob
        }
        return sum
    }

    enum CandidateEvaluationResult: Sendable, Equatable, Hashable {
        case error
        case pass(score: Float, alternativeConstraints: [AlternativeConstraint])
        case fixRequired(prefixConstraint: [UInt8])
        case wholeResult(String)

        struct AlternativeConstraint: Sendable, Equatable, Hashable {
            var probabilityRatio: Float
            var prefixConstraint: [UInt8]
        }
    }

    func getLearningPriority(data: DicdataElement) -> Float {
        // 文字数の長い候補ほど優先的に適用されるようにする
        // 積極的な複合語化の効果を期待
        return if 1 <= data.ruby.count && data.ruby.count <= 4 {
            Float(data.ruby.count + 2)
        } else if 5 <= data.ruby.count && data.ruby.count <= 15 {
            Float(data.ruby.count * 2)
        } else {
            30
        }
    }

    func predict_next_character(leftSideContext: String, count: Int) -> [(character: Character, value: Float)] {
        struct NextCharacterCandidate: Comparable {
            static func < (lhs: NextCharacterCandidate, rhs: NextCharacterCandidate) -> Bool {
                lhs.value < rhs.value
            }
            var character: Character
            var value: Float
        }

        // 文末を目指して生成するためのプロンプト
        // \u{EE01}を停止トークンとみなせる
        let prompt_tokens = self.tokenize(text: "\u{EE00}。\u{EE02}\(leftSideContext)", add_bos: false)
        let startOffset = prompt_tokens.count - 1

        guard let logits = self.get_logits(tokens: prompt_tokens, logits_start_index: startOffset) else {
            print("logits unavailable")
            return []
        }

        let n_vocab = llama_n_vocab(model)
        var exp_sum: Float = 0
        let startIndex = (prompt_tokens.count - 1 - startOffset) * Int(n_vocab)
        let endIndex = (prompt_tokens.count - startOffset) * Int(n_vocab)

        // Min-Heapを使用してn-bestを計算
        var minHeap: FixedSizeHeap<NextCharacterCandidate> = .init(size: count)
        let token_to_penalty_weight: [llama_token: Float] = prompt_tokens.indexed().reduce(into: [:]) { dict, item in
            let (index, token) = item
            // 現在位置から遠いほど減衰させる
            dict[token, default: 0] += 2 / Float(prompt_tokens.count - index)
        }

        for index in startIndex..<endIndex {
            let token = llama_token(index - startIndex)
            let repeat_penalty = Float(1.0 + token_to_penalty_weight[token, default: 0])
            let v = expf(logits[index] / repeat_penalty)
            exp_sum += v

            let tokenPieceData = Data((token_to_piece(token: token)).map(UInt8.init))
            let character: Character
            if let validCharacter = String(data: tokenPieceData, encoding: .utf8), let c = validCharacter.first {
                character = c
            } else {
                continue
            }
            minHeap.insertIfPossible(NextCharacterCandidate(character: character, value: v))
        }

        // Heapからソートして結果を取り出す
        return minHeap.unordered.sorted { $0.value > $1.value }.map { ($0.character, $0.value / exp_sum) }
    }

    func evaluate_candidate(input: String, candidate: Candidate, requestRichCandidates: Bool, versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode) -> CandidateEvaluationResult {
        print("Evaluate", candidate)
        // For zenz-v1 model, \u{EE00} is a token used for 'start query', and \u{EE01} is a token used for 'start answer'
        // We assume \u{EE01}\(candidate) is always splitted into \u{EE01}_\(candidate) by zenz-v1 tokenizer
        var userDictionaryPrompt: String = ""
        for item in candidate.data where item.metadata.contains(.isFromUserDictionary) {
            userDictionaryPrompt += "\(item.word)(\(item.ruby.toHiragana()))"
        }
        var conditions: [String] = []
        // ユーザ辞書の内容がある場合はこれを条件に追加
        if !userDictionaryPrompt.isEmpty {
            conditions.append("辞書:\(userDictionaryPrompt)")
        }
        // プロフィールがある場合はこれを条件に追加
        switch versionDependentConfig {
        case .v1: break
        case .v2(let mode):
            if let profile = mode.profile, !profile.isEmpty {
                let pf = profile.suffix(25)
                conditions.append("プロフィール:\(pf)")
            }
        case .v3(let mode):
            if let profile = mode.profile, !profile.isEmpty {
                let pf = profile.suffix(25)
                conditions.append("\u{EE03}\(pf)")
            }
            if let topic = mode.topic, !topic.isEmpty {
                let tp = topic.suffix(25)
                conditions.append("\u{EE04}\(tp)")
            }
            if let style = mode.style, !style.isEmpty {
                let st = style.suffix(25)
                conditions.append("\u{EE05}\(st)")
            }
            if let preference = mode.preference, !preference.isEmpty {
                let pr = preference.suffix(25)
                conditions.append("\u{EE06}\(pr)")
            }
        }
        // 左文脈を取得
        // プロフィールがある場合はこれを条件に追加
        let leftSideContext: String = switch versionDependentConfig {
        case .v1: ""
        case .v2(let mode):
            if let leftSideContext = mode.leftSideContext {
                String(leftSideContext.suffix(40))
            } else {
                ""
            }
        case .v3(let mode):
            if let leftSideContext = mode.leftSideContext {
                String(leftSideContext.suffix(40))
            } else {
                ""
            }
        }
        let inputTag = "\u{EE00}"
        let outputTag = "\u{EE01}"
        let contextTag = "\u{EE02}"
        // プロンプトを作成
        let prompt: String = switch versionDependentConfig {
        case .v1:
            inputTag + input + outputTag
        case .v2:
            if !conditions.isEmpty {
                // 条件がemptyでない場合は「・」でつなぎ、「発言:」を末尾に追加
                inputTag + input + contextTag + conditions.joined(separator: "・") + "・発言:\(leftSideContext)" + outputTag
            } else if !leftSideContext.isEmpty {
                // 条件がemptyの場合、単にleftSideContextを追加
                inputTag + input + contextTag + leftSideContext + outputTag
            } else {
                // そのまま
                inputTag + input + outputTag
            }
        case .v3:
            if !leftSideContext.isEmpty {
                // leftSideContextがEmptyでなければ下記の通り処理
                // contextがinputに前置されるように変更された(KV-cachingの効率化のため)
                conditions.joined(separator: "") + contextTag + leftSideContext + inputTag + input + outputTag
            } else {
                // そのまま
                conditions.joined(separator: "") + inputTag + input + outputTag
            }
        }
        // Therefore, tokens = prompt_tokens + candidate_tokens is an appropriate operation.
        let prompt_tokens = self.tokenize(text: prompt, add_bos: true, add_eos: false)
        let candidate_tokens = self.tokenize(text: candidate.text, add_bos: false, add_eos: false)
        let tokens = prompt_tokens + candidate_tokens
        let startOffset = prompt_tokens.count - 1
        let pos_max = llama_kv_cache_seq_pos_max(self.context, 0)
        print("pos max:", pos_max)
        guard let logits = self.get_logits(tokens: tokens, logits_start_index: startOffset) else {
            debug("logits unavailable")
            return .error
        }
        let n_vocab = llama_n_vocab(model)
        let is_learned_token: [(isLearned: Bool, priority: Float)] = Array(repeating: (false, 0), count: prompt_tokens.count) + candidate.data.flatMap {
            // priorityは文字数にする→文字数が長いほど優先される
            Array(repeating: ($0.metadata.contains(.isLearned), getLearningPriority(data: $0)), count: self.tokenize(text: $0.word, add_bos: false).count)
        }

        var score: Float = 0

        struct AlternativeHighProbToken: Comparable {
            static func < (lhs: AlternativeHighProbToken, rhs: AlternativeHighProbToken) -> Bool {
                lhs.probabilityRatioToMaxProb < rhs.probabilityRatioToMaxProb
            }

            var token: llama_token
            var constraint: [UInt8]
            // 最大probabilityに対しての割合
            var probabilityRatioToMaxProb: Float
        }

        var altTokens = FixedSizeHeap<AlternativeHighProbToken>(size: requestRichCandidates ? 5 : 0)
        for (i, token_id) in tokens.indexed().dropFirst(prompt_tokens.count) {
            // それぞれのトークンが、一つ前の予測において最も確率の高いトークンであるかをチェックする
            // softmaxはmaxなので、単にlogitsの中で最も大きいものを選べば良い
            // 一方実用的にはlog_probも得ておきたい。このため、ここでは明示的にsoftmaxも計算している
            struct TokenAndExpLogit: Comparable {
                static func < (lhs: TokenAndExpLogit, rhs: TokenAndExpLogit) -> Bool {
                    lhs.expLogit < rhs.expLogit
                }

                var token: llama_token
                var expLogit: Float
            }
            var exp_sum: Float = 0
            let startIndex = (i - 1 - startOffset) * Int(n_vocab)
            let endIndex = (i - startOffset) * Int(n_vocab)
            var tokenHeap = FixedSizeHeap<TokenAndExpLogit>(size: requestRichCandidates ? 3 : 1)
            for index in startIndex ..< endIndex {
                let v = expf(logits[index])
                exp_sum += v
                tokenHeap.insertIfPossible(TokenAndExpLogit(token: llama_token(index - startIndex), expLogit: v))
            }
            guard let maxItem = tokenHeap.max else {
                print("Max Item could not be found for unknown reason")
                return .error
            }
            // ここで最も良い候補であったかをチェックする
            if maxItem.token != token_id {
                if maxItem.token == llama_token_eos(model) {
                    var cchars = tokens[..<i].reduce(into: []) {
                        $0.append(contentsOf: token_to_piece(token: $1))
                    }
                    // adding "\0"
                    cchars.append(0)
                    let string = String(cString: cchars)
                    // 要求するべき制約を記述する
                    let wholeResult = String(string.dropFirst(prompt.count))
                    return .wholeResult(wholeResult)
                } else {
                    let actual_exp: Float = expf(logits[startIndex + Int(token_id)])
                    // 学習されたトークンであり、なおかつactual_expのある程度大きければ、学習されたトークンを優先する
                    let preferLearnedToken = is_learned_token[i].isLearned && actual_exp * is_learned_token[i].priority > maxItem.expLogit
                    if !preferLearnedToken {
                        // adding "\0"
                        let cchars = tokens[..<i].reduce(into: []) {
                            $0.append(contentsOf: token_to_piece(token: $1))
                        } + token_to_piece(token: maxItem.token)
                        return .fixRequired(prefixConstraint: cchars.dropFirst(prompt.utf8.count).map(UInt8.init))
                    }
                }
            } else if !tokenHeap.isEmpty {
                tokenHeap.removeMax()
                let prefix = tokens[..<i].reduce(into: []) {
                    $0.append(contentsOf: token_to_piece(token: $1))
                }.dropFirst(prompt.utf8.count)

                for item in tokenHeap.unordered {
                    altTokens.insertIfPossible(
                        AlternativeHighProbToken(
                            token: item.token,
                            constraint: prefix.map(UInt8.init) + token_to_piece(token: item.token).map(UInt8.init),
                            probabilityRatioToMaxProb: item.expLogit / maxItem.expLogit
                        )
                    )
                }
            }
            score += logf(maxItem.expLogit) - logf(exp_sum)
        }
        return .pass(score: score, alternativeConstraints: altTokens.unordered.sorted(by: >).map {.init(probabilityRatio: $0.probabilityRatioToMaxProb, prefixConstraint: $0.constraint)})
    }

    private func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], logits: Bool) {
        batch.token   [Int(batch.n_tokens)] = id
        batch.pos     [Int(batch.n_tokens)] = pos
        batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
        for i in 0..<seq_ids.count {
            batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
        }
        batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func tokenize(text: String, add_bos: Bool, add_eos: Bool = false) -> [llama_token] {
        // replace space into ideographic space (\u3000) for zenz tokenizer
        // replace newline into null for zenz tokenizer
        let text = text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(model, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)
        var swiftTokens: [llama_token] = if tokenCount < 0 {
            [llama_token_bos(model)]
        } else {
            (0..<tokenCount).map {tokens[Int($0)]}
        }
        tokens.deallocate()
        if add_eos {
            swiftTokens.append(llama_token_eos(model))
        }
        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(model, token, result, 8, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(model, token, newResult, -nTokens, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
