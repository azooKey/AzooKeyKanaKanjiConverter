#if !Zenzai
// Zenzaiが有効でない場合、このMock実装を有効化する
private func unimplemented<T>() -> T {
    fatalError("unimplemented")
}

package typealias llama_token = Int32
package typealias llama_pos = Int32
package typealias llama_seq_id = Int32

package struct llama_context_params {
    package var seed: Int
    package var n_ctx: Int
    package var n_threads: Int32
    package var n_threads_batch: Int32
    package var n_batch: Int
}
package func llama_context_default_params() -> llama_context_params { unimplemented() }

package typealias llama_context = OpaquePointer
package func llama_init_from_model(_ model: llama_model, _ ctx_params: llama_context_params) -> llama_context? { unimplemented() }
package func llama_free(_ context: llama_context) {}

package typealias llama_model = OpaquePointer
package typealias llama_vocab = OpaquePointer

package func llama_model_free(_ model: llama_model) {}

package func llama_backend_init() {}
package func llama_backend_free() {}

package struct llama_model_params {
    package var use_mmap: Bool
}
package func llama_model_default_params() -> llama_model_params { unimplemented() }

package func llama_model_get_vocab(_ model: llama_model) -> llama_vocab? { unimplemented() }

package func llama_model_load_from_file(_ path: String, _ model_params: llama_model_params) -> llama_model? { unimplemented() }

package func llama_kv_cache_seq_rm(_ ctx: llama_context, _ seq_id: llama_seq_id, _ p0: llama_pos, _ p1: llama_pos) {}
package func llama_kv_cache_seq_pos_max(_ ctx: llama_context, _ seq_id: llama_seq_id) -> Int { unimplemented() }

package struct llama_batch {
    package var token: [llama_token]
    package var pos: [llama_pos]
    package var n_seq_id: [llama_seq_id]
    package var seq_id: [[llama_seq_id]?]
    package var logits: UnsafeMutablePointer<Float>
    package var n_tokens: Int

}
package func llama_batch_init(_ n_tokens: Int, _ embd: Int, _ n_seq_max: Int) -> llama_batch { unimplemented() }

package func llama_n_ctx(_ ctx: llama_context) -> Int { unimplemented() }
package func llama_vocab_n_tokens(_ vocab: llama_vocab) -> Int { unimplemented() }

package func llama_tokenize(_ model: llama_model, _ text: String, _ text_len: Int32, _ tokens: UnsafeMutablePointer<llama_token>, _ n_tokens_max: Int32, _ add_special: Bool, _ parse_special: Bool) -> Int { unimplemented() }
package func llama_vocab_eos(_ vocab: llama_vocab) -> llama_token { unimplemented() }
package func llama_vocab_bos(_ vocab: llama_vocab) -> llama_token { unimplemented() }
package func llama_token_to_piece(_ vocab: llama_vocab, _ token: llama_token, _ buf: UnsafeMutablePointer<Int8>, _ length: Int32, _ lstrip: Int32, _ special: Bool) -> Int32 { unimplemented() }

package func llama_decode(_ ctx: llama_context, _ batch: llama_batch) -> Int { unimplemented() }
package func llama_get_logits(_ ctx: llama_context) -> UnsafeMutablePointer<Float>? { unimplemented() }
#endif
