#if !Zenzai && !ZenzaiCPU
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
package func llama_init_from_model(_: llama_model, _: llama_context_params) -> llama_context? { unimplemented() }
package func llama_free(_: llama_context) {}

package typealias llama_model = OpaquePointer
package typealias llama_vocab = OpaquePointer

package func llama_model_free(_: llama_model) {}

package func llama_backend_init() {}
package func llama_backend_free() {}

package struct llama_model_params {
    package var use_mmap: Bool
}
package func llama_model_default_params() -> llama_model_params { unimplemented() }

package func llama_model_get_vocab(_: llama_model) -> llama_vocab? { unimplemented() }

package func llama_model_load_from_file(_: String, _: llama_model_params) -> llama_model? { unimplemented() }

package func llama_kv_cache_seq_rm(_: llama_context, _: llama_seq_id, _: llama_pos, _: llama_pos) {}
package func llama_kv_cache_seq_cp(_: llama_context, _: llama_seq_id, _: llama_seq_id, _: llama_pos, _: llama_pos) {}
package func llama_kv_cache_seq_pos_max(_: llama_context, _: llama_seq_id) -> Int { unimplemented() }

package struct llama_batch {
    package var token: [llama_token]
    package var pos: [llama_pos]
    package var n_seq_id: [llama_seq_id]
    package var seq_id: [[llama_seq_id]?]
    package var logits: UnsafeMutablePointer<Float>
    package var n_tokens: Int
}
package func llama_batch_init(_: Int, _: Int, _: Int) -> llama_batch { unimplemented() }
package func llama_batch_free(_: llama_batch) {}

package func llama_n_ctx(_: llama_context) -> Int { unimplemented() }
package func llama_vocab_n_tokens(_: llama_vocab) -> Int { unimplemented() }

package func llama_tokenize(_: llama_model, _: String, _: Int32, _: UnsafeMutablePointer<llama_token>, _: Int32, _: Bool, _: Bool) -> Int { unimplemented() }
package func llama_vocab_eos(_: llama_vocab) -> llama_token { unimplemented() }
package func llama_vocab_bos(_: llama_vocab) -> llama_token { unimplemented() }
package func llama_token_to_piece(_: llama_vocab, _: llama_token, _: UnsafeMutablePointer<Int8>, _: Int32, _: Int32, _: Bool) -> Int32 { unimplemented() }

package func llama_decode(_: llama_context, _: llama_batch) -> Int { unimplemented() }
package func llama_get_logits(_: llama_context) -> UnsafeMutablePointer<Float>? { unimplemented() }
#endif
