// Volocal/LLM/LlamaLLMProvider.swift
// llama.cpp GGUF adapter — the existing LLM back-end, refactored behind LLMProvider.
//
// WHY GGUF IS STILL HERE:
//   The Apple Neural Engine and CoreML do not support generative LLM inference
//   at runtime (as of iOS 17-18; iOS 26 adds Apple Foundation Models).
//   llama.cpp is the only mature iOS path for streaming text generation:
//     • Runs on Metal GPU → leaves ANE free for FluidAudio STT/TTS
//     • GGUF Q4_K_S quantisation: 2B = 1.26 GB, 0.8B = 520 MB
//     • llama.swift SPM package wraps the C++ API cleanly in Swift
//
// MEMORY TIERS (selected by ModelConfiguration):
//   .standard → Qwen3.5-2B Q4_K_S   (~1.26 GB, ~32 tok/s)
//   .lite     → Qwen3.5-0.8B Q4_K_S (~520 MB,  ~70 tok/s)
//   MemoryPressureMonitor auto-selects .lite when < 1500 MB available.

import Foundation
import Llama                  // llama.swift SPM package — re-exports llama.cpp C API

// MARK: - Errors

enum LlamaLLMError: LocalizedError {
    case notPrepared
    case modelNotFound(url: URL)
    case contextCreationFailed
    case downloadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "LlamaLLMProvider: call prepare() before generating."
        case .modelNotFound(let url):
            return "LlamaLLMProvider: GGUF not found at \(url.path)"
        case .contextCreationFailed:
            return "LlamaLLMProvider: failed to create llama_context."
        case .downloadFailed(let err):
            return "LlamaLLMProvider: download failed — \(err.localizedDescription)"
        }
    }
}

// MARK: - Memory Tier

public enum LLMMemoryTier {
    case standard   // Qwen3.5-2B  Q4_K_S — 1.26 GB
    case lite       // Qwen3.5-0.8B Q4_K_S — 520 MB

    var huggingFaceRepo: String {
        switch self {
        case .standard: return "bartowski/Qwen_Qwen3.5-2B-GGUF"
        case .lite:     return "bartowski/Qwen_Qwen3.5-0.8B-GGUF"
        }
    }

    var filename: String {
        switch self {
        case .standard: return "Qwen3.5-2B-Q4_K_S.gguf"
        case .lite:     return "Qwen3.5-0.8B-Q4_K_S.gguf"
        }
    }

    var estimatedMB: Int {
        switch self {
        case .standard: return 1260
        case .lite:     return 520
        }
    }
}

// MARK: - LlamaLLMProvider

/// Wraps llama.cpp via `llama.swift` to deliver streaming text generation.
/// Uses Metal GPU, leaving the ANE fully available for FluidAudio.
public final class LlamaLLMProvider: LLMProvider {

    // MARK: LLMProvider

    public var name: String { "llama.cpp / \(tier.filename)" }
    public var estimatedMemoryMB: Int { tier.estimatedMB }
    public var maxContextTokens: Int { 4096 }
    public private(set) var isReady = false
    public private(set) var tokensPerSecond: Double = 0

    // MARK: Private State

    private let tier: LLMMemoryTier
    private var modelURL: URL?
    private var llamaModel: OpaquePointer?      // llama_model*
    private var llamaContext: OpaquePointer?    // llama_context*
    private var isCancelled = false

    // Serialise generation; llama.cpp context is not thread-safe.
    private let generationQueue = DispatchQueue(label: "com.volocal.llama", qos: .userInitiated)

    // MARK: Init

    public init(tier: LLMMemoryTier = .standard) {
        self.tier = tier
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        guard !isReady else { return }

        let url = try await ensureModelDownloaded()

        // llama_backend_init is idempotent
        llama_backend_init()

        var mParams = llama_model_default_params()
        mParams.n_gpu_layers = 999   // offload all layers to Metal

        guard let model = llama_model_load_from_file(url.path, mParams) else {
            throw LlamaLLMError.modelNotFound(url: url)
        }

        var cParams = llama_context_default_params()
        cParams.n_ctx     = UInt32(maxContextTokens)
        cParams.n_batch   = 512
        cParams.n_ubatch  = 512
        cParams.flash_attn = true   // ~20% speed boost on Apple Silicon

        guard let context = llama_init_from_model(model, cParams) else {
            llama_model_free(model)
            throw LlamaLLMError.contextCreationFailed
        }

        llamaModel   = model
        llamaContext = context
        modelURL     = url
        isReady      = true
    }

    public func unload() async {
        if let ctx = llamaContext { llama_free(ctx) }
        if let mdl = llamaModel  { llama_model_free(mdl) }
        llamaContext = nil
        llamaModel   = nil
        isReady      = false
    }

    // MARK: Generation

    public func generate(
        messages: [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<LLMToken, Error> {

        AsyncThrowingStream { continuation in
            guard isReady, let model = llamaModel, let context = llamaContext else {
                continuation.finish(throwing: LlamaLLMError.notPrepared)
                return
            }

            isCancelled = false
            let startTime = Date()

            generationQueue.async { [weak self] in
                guard let self else { return }

                do {
                    // 1. Build chat prompt using Qwen3.5 chat template
                    let prompt = self.buildChatMLPrompt(
                        systemPrompt: systemPrompt,
                        messages: self.trimmedMessages(messages)
                    )

                    // 2. Tokenise
                    let vocab = llama_model_get_vocab(model)
                    let maxTokens = 2048
                    var tokens = [llama_token](repeating: 0, count: maxTokens)
                    let nTokens = llama_tokenize(
                        vocab,
                        prompt,
                        Int32(prompt.utf8.count),
                        &tokens,
                        Int32(maxTokens),
                        true,   // add_special
                        true    // parse_special
                    )
                    guard nTokens > 0 else {
                        continuation.finish()
                        return
                    }
                    tokens = Array(tokens.prefix(Int(nTokens)))

                    // 3. Eval prompt
                    var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
                    guard llama_decode(context, batch) == 0 else {
                        continuation.finish(throwing: LlamaLLMError.contextCreationFailed)
                        return
                    }

                    // 4. Sample tokens until EOS or cancel
                    var nGenerated = 0
                    var samplerChain = llama_sampler_chain_init(llama_sampler_chain_default_params())
                    llama_sampler_chain_add(samplerChain, llama_sampler_init_top_k(40))
                    llama_sampler_chain_add(samplerChain, llama_sampler_init_top_p(0.9, 1))
                    llama_sampler_chain_add(samplerChain, llama_sampler_init_temp(0.7))
                    llama_sampler_chain_add(samplerChain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))

                    while !self.isCancelled {
                        let newToken = llama_sampler_sample(samplerChain, context, -1)
                        if llama_token_is_eog(vocab, newToken) { break }

                        // Decode token to text
                        var buf = [CChar](repeating: 0, count: 256)
                        let nChars = llama_token_to_piece(vocab, newToken, &buf, 256, 0, true)
                        guard nChars > 0 else { break }
                        let piece = String(cString: buf)

                        nGenerated += 1
                        let isLast = nGenerated >= 512   // safety cap
                        continuation.yield(LLMToken(text: piece, isLast: isLast))
                        if isLast { break }

                        // Decode next token
                        var nextToken = newToken
                        var nextBatch = llama_batch_get_one(&nextToken, 1)
                        guard llama_decode(context, nextBatch) == 0 else { break }
                    }

                    llama_sampler_free(samplerChain)
                    llama_kv_cache_clear(context)

                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        self.tokensPerSecond = Double(nGenerated) / elapsed
                    }

                    continuation.yield(LLMToken(text: "", isLast: true))
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancelGeneration() {
        isCancelled = true
    }

    // MARK: Private — Model Download

    private func ensureModelDownloaded() async throws -> URL {
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volocal/LLM", isDirectory: true)

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let modelFile = cacheDir.appendingPathComponent(tier.filename)
        if FileManager.default.fileExists(atPath: modelFile.path) {
            return modelFile
        }

        // Download from HuggingFace (same pattern as ModelDownloadManager)
        let hfURL = URL(string: "https://huggingface.co/\(tier.huggingFaceRepo)/resolve/main/\(tier.filename)")!
        let (tempURL, _) = try await URLSession.shared.download(from: hfURL)
        try FileManager.default.moveItem(at: tempURL, to: modelFile)
        return modelFile
    }

    // MARK: Private — Prompt Building

    /// Qwen3.5 uses ChatML format with a thinking-mode control token.
    private func buildChatMLPrompt(systemPrompt: String, messages: [ChatMessage]) -> String {
        var parts: [String] = []
        parts.append("<|im_start|>system\n\(systemPrompt)<|im_end|>")
        for msg in messages {
            let role = msg.role == .user ? "user" : "assistant"
            parts.append("<|im_start|>\(role)\n\(msg.content)<|im_end|>")
        }
        parts.append("<|im_start|>assistant\n/no_think\n")  // disable chain-of-thought for speed
        return parts.joined(separator: "\n")
    }
}
