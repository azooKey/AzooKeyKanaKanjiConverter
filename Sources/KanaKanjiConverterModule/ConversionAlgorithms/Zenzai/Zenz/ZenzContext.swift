#if Zenzai || ZenzaiCPU
// Zenzai/ZenzaiCPU が有効でない場合、llama-mock.swift の実装が利用される
import llama
#endif
#if canImport(Darwin)
import Darwin
#endif

import Algorithms
import Foundation
import SwiftUtils

enum ZenzError: LocalizedError {
    case couldNotLoadModel(path: String)
    case couldNotLoadContext
    case couldNotLoadVocab

    var errorDescription: String? {
        switch self {
        case .couldNotLoadContext: return "failed to load context"
        case .couldNotLoadModel(path: let path): return "could not load model weight at \(path)"
        case .couldNotLoadVocab: return "failed to load vocab"
        }
    }
}

/// llama.cpp のバックエンドはプロセス単位で一度だけ初期化する。
///
/// `llama_backend_free()` は現在 MPI 用の後始末にしか使われないため、モデルや
/// コンテキストより先に解放される可能性があるプロセス終了時の明示解放は行わない。
private enum ZenzBackend {
    private static let initialized: Void = {
        #if ZenzaiCPU && canImport(Darwin)
        // llama.cpp b9637ではbackend registry生成時にMetalも初期化される。
        // CPU推論ではMetal shaderの初期ロードを避ける。
        setenv("GGML_DISABLE_METAL", "1", 0)
        #endif
        llama_backend_init()
    }()

    static func initializeIfNeeded() {
        _ = self.initialized
    }
}

private final class ZenzTokenArrayBox {
    init(_ tokens: [llama_token]) {
        self.tokens = tokens
    }

    let tokens: [llama_token]
}

struct ZenzResolvedConversionCacheKey: Equatable, Hashable {
    var input: [ComposingText.InputElement]
    var convertTarget: String
    var convertTargetCursorPosition: Int?
    var keyboardLanguage: KeyboardLanguage
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var inferenceLimit: Int
}

struct ZenzDraftConversionCacheKey: Equatable, Hashable {
    var input: [ComposingText.InputElement]
    var convertTarget: String
    var convertTargetCursorPosition: Int?
    var keyboardLanguage: KeyboardLanguage
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var prefixConstraint: Kana2Kanji.PrefixConstraint
}

struct ZenzDraftConversion {
    var resultPrevs: [RegisteredNode]
    var resultLatticeHead: ZenzResolvedLatticeHead
}

struct ZenzResolvedConversion {
    var resultPrevs: [RegisteredNode]
    var resultLatticeHead: ZenzResolvedLatticeHead
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var satisfyingCandidate: Candidate
}

struct ZenzResolvedLatticeNode: Hashable {
    var data: DicdataElement
    var range: Lattice.LatticeRange
}

final class ZenzResolvedLatticeHead: @unchecked Sendable {
    init(nodes: [ZenzResolvedLatticeNode]) {
        self.nodes = nodes
        self.fingerprint = nodes.hashValue
    }

    let nodes: [ZenzResolvedLatticeNode]
    let fingerprint: Int
}

private final class ZenzResolvedConversionCache: @unchecked Sendable {
    private struct Entry {
        var value: ZenzResolvedConversion
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: ZenzResolvedConversionCacheKey) -> ZenzResolvedConversion? {
        self.lock.withLock {
            guard var entry = self.entries[key] else {
                return nil
            }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: ZenzResolvedConversion, for key: ZenzResolvedConversionCacheKey) {
        var value = value
        self.lock.withLock {
            // 逐次入力では最大辞書長を超えた後の先頭候補が同一になる。
            // 不変配列を既存entryと共有し、prefixごとの重複保持を避ける。
            if let sharedHead = self.entries.values.lazy.map({
                $0.value.resultLatticeHead
            }).first(where: {
                $0.fingerprint == value.resultLatticeHead.fingerprint
                    && $0.nodes == value.resultLatticeHead.nodes
            }) {
                value.resultLatticeHead = sharedHead
            }
            self.accessIndex &+= 1
            self.entries[key] = Entry(value: value, accessIndex: self.accessIndex)
            if self.entries.count > self.capacity,
               let oldestKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries.removeValue(forKey: oldestKey)
            }
        }
    }

    private let capacity: Int
    private var entries: [ZenzResolvedConversionCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

/// 同じ辞書状態・入力・制約から得た不変のdraft経路を共有するLRU cache。
/// 可変な探索状態を含むlattice本体は保持しない。
final class ZenzDraftConversionCache: @unchecked Sendable {
    private struct Entry {
        var value: ZenzDraftConversion
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: ZenzDraftConversionCacheKey) -> ZenzDraftConversion? {
        self.lock.withLock {
            guard var entry = self.entries[key] else { return nil }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: ZenzDraftConversion, for key: ZenzDraftConversionCacheKey) {
        var value = value
        self.lock.withLock {
            if let sharedHead = self.entries.values.lazy.map({
                $0.value.resultLatticeHead
            }).first(where: {
                $0.fingerprint == value.resultLatticeHead.fingerprint
                    && $0.nodes == value.resultLatticeHead.nodes
            }) {
                value.resultLatticeHead = sharedHead
            }
            self.accessIndex &+= 1
            self.entries[key] = Entry(value: value, accessIndex: self.accessIndex)
            if self.entries.count > self.capacity,
               let oldestKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries.removeValue(forKey: oldestKey)
            }
        }
    }

    private let capacity: Int
    private var entries: [ZenzDraftConversionCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

/// 1つの変換セッション内だけで再利用するZenzaiのメモ化キャッシュ。
///
/// モデルやnative contextとは所有者を分け、Converterのセッション終了時に確実に
/// 破棄されるようにする。これにより、別セッションや別テストの同一入力が以前の
/// 変換結果を引き継がない。
final class ZenzaiSessionCache: @unchecked Sendable {
    init(
        evaluationCapacity: Int = 256,
        resolvedConversionCapacity: Int = 64,
        draftConversionCapacity: Int = 128,
        promptTokenCapacity: Int = 128
    ) {
        self.evaluationCache = ZenzEvaluationCache(capacity: evaluationCapacity)
        self.resolvedConversionCache = ZenzResolvedConversionCache(
            capacity: resolvedConversionCapacity
        )
        self.draftConversionCache = ZenzDraftConversionCache(
            capacity: draftConversionCapacity
        )
        self.evaluationPromptTokenCache.countLimit = promptTokenCapacity
    }

    func cachedEvaluation(for key: ZenzEvaluationCacheKey) -> CandidateEvaluationResult? {
        self.evaluationCache.value(for: key)
    }

    func cacheEvaluation(_ result: CandidateEvaluationResult, for key: ZenzEvaluationCacheKey) {
        self.evaluationCache.insert(result, for: key)
    }

    func cachedResolvedConversion(
        for key: ZenzResolvedConversionCacheKey
    ) -> ZenzResolvedConversion? {
        self.resolvedConversionCache.value(for: key)
    }

    func cacheResolvedConversion(
        _ value: ZenzResolvedConversion,
        for key: ZenzResolvedConversionCacheKey
    ) {
        self.resolvedConversionCache.insert(value, for: key)
    }

    func cachedDraftConversion(for key: ZenzDraftConversionCacheKey) -> ZenzDraftConversion? {
        self.draftConversionCache.value(for: key)
    }

    func cacheDraftConversion(
        _ value: ZenzDraftConversion,
        for key: ZenzDraftConversionCacheKey
    ) {
        self.draftConversionCache.insert(value, for: key)
    }

    func cachedEvaluationPromptTokens(for prompt: String) -> [llama_token]? {
        self.evaluationPromptTokenCache.object(forKey: prompt as NSString)?.tokens
    }

    func cacheEvaluationPromptTokens(_ tokens: [llama_token], for prompt: String) {
        self.evaluationPromptTokenCache.setObject(
            ZenzTokenArrayBox(tokens),
            forKey: prompt as NSString
        )
    }

    private let evaluationCache: ZenzEvaluationCache
    private let resolvedConversionCache: ZenzResolvedConversionCache
    private let draftConversionCache: ZenzDraftConversionCache
    private let evaluationPromptTokenCache = NSCache<NSString, ZenzTokenArrayBox>()
}

/// 読み取り専用のGGUFモデルを複数の推論コンテキスト間で共有する。
///
/// KV cacheなどの可変状態は`ZenzContext`側に残し、モデルの重みとvocabularyだけを
/// 共有することで、同じモデルを利用するConverterごとの再ロードを避ける。
private final class SharedZenzModel {
    init(path: String) throws {
        ZenzBackend.initializeIfNeeded()
        var modelParams = llama_model_default_params()
        modelParams.use_mmap = true
        #if ZenzaiCPU && os(iOS)
        // b9637のCPU weight repackはモデルと同程度の追加bufferを常駐させる。
        // iOSのメモリ制約を優先し、mmapされた元の量子化weightを直接利用する。
        modelParams.use_extra_bufts = false
        #endif
        #if ZenzaiCPU
        modelParams.n_gpu_layers = 0
        modelParams.split_mode = LLAMA_SPLIT_MODE_NONE
        guard let cpuDevice = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) else {
            debug("Could not find CPU backend")
            throw ZenzError.couldNotLoadModel(path: path)
        }
        // NULL終端のCPU-onlyデバイスリストを渡す。`n_gpu_layers = 0`だけでは
        // llama.cppがMetalデバイスも列挙し、context生成時に初期化してしまう。
        var devices = [cpuDevice, nil]
        let loadedModel = devices.withUnsafeMutableBufferPointer { buffer in
            modelParams.devices = buffer.baseAddress
            return llama_model_load_from_file(path, modelParams)
        }
        #else
        let loadedModel = llama_model_load_from_file(path, modelParams)
        #endif
        guard let model = loadedModel else {
            debug("Could not load model at \(path)")
            throw ZenzError.couldNotLoadModel(path: path)
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            debug("Could not load vocab!")
            throw ZenzError.couldNotLoadVocab
        }
        self.model = model
        self.vocab = vocab
    }

    deinit {
        llama_model_free(self.model)
    }

    let model: OpaquePointer
    let vocab: OpaquePointer
}

/// 同時に強参照するモデルを1個に制限する、プロセス共通のモデルキャッシュ。
///
/// `NSCache`にすることでメモリプレッシャー時にはモデルを解放できる。呼び出し側の
/// `ZenzContext`もモデルを強参照するため、使用中のモデルが解放されることはない。
private final class SharedZenzModelCache: @unchecked Sendable {
    static let shared = SharedZenzModelCache()

    private init() {
        self.cache.countLimit = 1
    }

    func model(path: String) throws -> SharedZenzModel {
        try self.lock.withLock {
            let key = path as NSString
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            let model = try SharedZenzModel(path: path)
            self.cache.setObject(model, forKey: key)
            return model
        }
    }

    private let cache = NSCache<NSString, SharedZenzModel>()
    private let lock = NSLock()
}

final class ZenzContext {
    private let sharedModel: SharedZenzModel
    private var context: OpaquePointer
    private var batch: llama_batch
    private var prevInputBySeq: [llama_seq_id: [llama_token]] = [:]
    private var prevPromptBySeq: [llama_seq_id: String] = [:]

    private let n_len: Int32 = 512
    private let evalSeqId: llama_seq_id = 0
    private let inputPredictionSeqId: llama_seq_id = 1

    private init(sharedModel: SharedZenzModel, context: OpaquePointer) {
        self.sharedModel = sharedModel
        self.context = context
        self.batch = llama_batch_init(512, 0, 1)
    }

    deinit {
        llama_batch_free(self.batch)
        llama_free(context)
    }

    private static var ctx_params: llama_context_params {
        let n_threads = self.inferenceThreadCount
        debug("Using \(n_threads) threads")
        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = 512
        #if os(Linux) || os(Windows)
        ctx_params.flash_attn = true
        #else
        // 評価用(0)と入力予測用(1)の2 sequenceを同一KV cacheで扱う。
        ctx_params.n_seq_max = 2
        // 両sequenceはpromptの大部分を共有する。512 tokenの総容量を分割せず、
        // 従来と同じ容量のKV cacheとして共有する。
        ctx_params.kv_unified = true
        ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        #endif
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        ctx_params.n_batch = 512
        #if Zenzai || ZenzaiCPU
        ctx_params.n_ubatch = 64
        #endif
        // 推論時間は呼び出し側で計測する。llama.cpp内部の統計更新は不要。
        ctx_params.no_perf = true
        return ctx_params
    }

    /// 対話的な推論に使うCPUスレッド数を実行環境のトポロジーから決定する。
    ///
    /// Apple Siliconでは性能の異なるクラスタを跨ぐと短いdecodeのbarrier待ちが
    /// 増えるため、最高性能クラスタの物理コア数を利用する。それ以外の環境では
    /// OSへ応答性の余地を残しつつ、llama.cppの小規模モデルで過剰並列にならない
    /// よう8スレッドを上限とする。
    private static var inferenceThreadCount: Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        #if canImport(Darwin)
        let performanceCoreCount = self.sysctlInt32("hw.perflevel0.physicalcpu")
        #else
        let performanceCoreCount: Int? = nil
        #endif
        return self.selectInferenceThreadCount(
            activeProcessorCount: activeProcessorCount,
            performanceCoreCount: performanceCoreCount
        )
    }

    /// DarwinではmacOS/iOSともに最高性能クラスタを優先し、sysctl値を取得できない
    /// 端末やDarwin以外では論理CPU数から安全なフォールバックを選ぶ。
    static func selectInferenceThreadCount(
        activeProcessorCount: Int,
        performanceCoreCount: Int?
    ) -> Int {
        let activeProcessorCount = max(1, activeProcessorCount)
        if let performanceCoreCount,
           performanceCoreCount > 0,
           performanceCoreCount <= activeProcessorCount {
            return performanceCoreCount
        }
        let reservedProcessorCount = if activeProcessorCount >= 8 {
            2
        } else if activeProcessorCount >= 4 {
            1
        } else {
            0
        }
        return max(1, min(8, activeProcessorCount - reservedProcessorCount))
    }

    #if canImport(Darwin)
    private static func sysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return Int(value)
    }
    #endif

    static func createContext(path: String) throws -> ZenzContext {
        let sharedModel = try SharedZenzModelCache.shared.model(path: path)
        var params = ctx_params
        #if ZenzaiCPU
        // CPU 専用: KV / KQV 等の GPU オフロードを完全に無効化
        params.offload_kqv = false
        #endif
        let context = llama_init_from_model(sharedModel.model, params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }

        return ZenzContext(sharedModel: sharedModel, context: context)
    }

    func resetContext() throws {
        llama_free(self.context)
        var params = Self.ctx_params
        #if ZenzaiCPU
        params.offload_kqv = false
        #endif
        let context = llama_init_from_model(self.sharedModel.model, params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }
        self.context = context
        self.prevInputBySeq = [:]
        self.prevPromptBySeq = [:]
    }

    private func getLogits(tokens: [llama_token], logits_start_index: Int = 0, seqId: llama_seq_id = 0) -> UnsafeMutablePointer<Float>? {
        #if !os(Linux) && !os(Windows)
        let memory = llama_get_memory(self.context)
        #endif
        let currentPrevInput = self.prevInputBySeq[seqId] ?? []
        var effectivePrevInput = currentPrevInput

        // Try to copy KV cache from the other sequence if it gives a longer prefix match.
        let otherSeqId: llama_seq_id? = if seqId == evalSeqId {
            inputPredictionSeqId
        } else if seqId == inputPredictionSeqId {
            evalSeqId
        } else {
            nil
        }
        if let otherSeqId, let otherPrevInput = self.prevInputBySeq[otherSeqId] {
            let currentPrefix = currentPrevInput.commonPrefix(with: tokens).count
            let otherPrefix = otherPrevInput.commonPrefix(with: tokens).count
            if otherPrefix > currentPrefix {
                let copiedPrefixCount = min(otherPrefix, logits_start_index)
                if copiedPrefixCount > 0 {
                    #if os(Linux) || os(Windows)
                    llama_kv_cache_seq_rm(context, seqId, 0, -1)
                    llama_kv_cache_seq_cp(context, otherSeqId, seqId, 0, llama_pos(copiedPrefixCount))
                    #else
                    llama_memory_seq_rm(memory, seqId, 0, -1)
                    llama_memory_seq_cp(memory, otherSeqId, seqId, 0, llama_pos(copiedPrefixCount))
                    #endif
                    effectivePrevInput = otherPrevInput
                }
            }
        }

        // Manage KV cache: remove entries that differ from previous input
        let prefixCacheCount: Int
        do {
            #if os(Linux) || os(Windows)
            let pos_max = llama_kv_cache_seq_pos_max(self.context, seqId)
            #else
            let pos_max = llama_memory_seq_pos_max(memory, seqId)
            #endif
            debug("pos max:", pos_max, "prevInput count:", effectivePrevInput.count, "tokens count:", tokens.count)
            let commonTokens = effectivePrevInput.commonPrefix(with: tokens)
            // Remove KV cache from position commonTokens.count onwards to recompute divergent part
            // removed range: [llama_pos(commonTokens.count), inf)
            prefixCacheCount = min(commonTokens.count, logits_start_index)
            #if os(Linux) || os(Windows)
            llama_kv_cache_seq_rm(context, seqId, llama_pos(prefixCacheCount), -1)
            debug("new pos max:", llama_kv_cache_seq_pos_max(self.context, seqId), "commonTokens:", commonTokens.count)
            #else
            llama_memory_seq_rm(memory, seqId, llama_pos(prefixCacheCount), -1)
            debug("new pos max:", llama_memory_seq_pos_max(memory, seqId), "commonTokens:", commonTokens.count)
            #endif
        }
        self.batch.n_tokens = 0
        let n_ctx = llama_n_ctx(context)
        let n_kv_req = tokens.count + (Int(n_len) - tokens.count)
        if n_kv_req > n_ctx {
            debug("error: n_kv_req > n_ctx, the required KV cache size is not big enough")
        }
        for i in tokens.indices.dropFirst(prefixCacheCount) {
            llama_batch_add(&self.batch, tokens[i], Int32(i), [seqId], logits: logits_start_index <= i)
        }
        // 評価
        if llama_decode(context, self.batch) != 0 {
            debug("llama_decode() failed")
            return nil
        }
        // update cached input for next call (for KV cache management)
        self.prevInputBySeq[seqId] = tokens
        return llama_get_logits(context)
    }

    func previousEvaluationPrompt() -> String {
        self.prevPromptBySeq[evalSeqId] ?? ""
    }

    func setPreviousEvaluationPrompt(_ prompt: String) {
        self.prevPromptBySeq[evalSeqId] = prompt
    }

    func normalizeForModel(_ text: String) -> String {
        self.preprocessText(text: text)
    }

    func encodeEvaluationPrompt(
        _ prompt: String,
        sessionCache: ZenzaiSessionCache
    ) -> [llama_token] {
        if let cached = sessionCache.cachedEvaluationPromptTokens(for: prompt) {
            return cached
        }
        let tokens = self.encode(prompt, addBOS: true, addEOS: false)
        sessionCache.cacheEvaluationPromptTokens(tokens, for: prompt)
        return tokens
    }

    func encode(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: self.preprocessText(text: text), add_bos: addBOS, add_eos: addEOS)
    }

    func encodeRaw(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: text, add_bos: addBOS, add_eos: addEOS)
    }

    func evaluationLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset, seqId: evalSeqId)
    }

    func inputPredictionLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset, seqId: inputPredictionSeqId)
    }

    var vocabSize: Int {
        Int(llama_vocab_n_tokens(self.sharedModel.vocab))
    }

    var eosToken: llama_token {
        llama_vocab_eos(self.sharedModel.vocab)
    }

    func decodeTokens(_ tokens: [llama_token]) -> String {
        let cchars: [CChar] = tokens.flatMap(self.tokenToPiece)
        let data = Data(cchars.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8) ?? ""
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

    private func preprocessText(text: String) -> String {
        // replace space into ideographic space (\u3000) for zenz tokenizer
        // replace newline into null for zenz tokenizer
        text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }
    private func tokenize(text: String, add_bos: Bool, add_eos: Bool = false) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(self.sharedModel.vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)
        var swiftTokens: [llama_token] = if tokenCount < 0 {
            [llama_vocab_bos(self.sharedModel.vocab)]
        } else {
            (0..<tokenCount).map {tokens[Int($0)]}
        }
        tokens.deallocate()
        if add_eos {
            swiftTokens.append(llama_vocab_eos(self.sharedModel.vocab))
        }
        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    func tokenToPiece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(self.sharedModel.vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(self.sharedModel.vocab, token, newResult, Int32(-nTokens), 0, false)
            let bufferPointer: UnsafeBufferPointer<Int8> = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer: UnsafeBufferPointer<Int8> = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
