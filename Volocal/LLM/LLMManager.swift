import Foundation

/// Manages LLM inference using llama.cpp via the LlamaContext actor.
@MainActor
final class LLMManager: ObservableObject {
    @Published var response: String = ""
    @Published var isGenerating: Bool = false
    @Published var error: String?
    @Published var tokensPerSecond: Double = 0

    private var llamaContext: LlamaContext?
    private var generationTask: Task<Void, Never>?

    private let systemPrompt = """
    You are Volocal, a helpful voice assistant running entirely on-device. \
    The user speaks Thai. Their input is Thai speech transcribed by an ASR model \
    and may contain romanization artifacts or minor transcription errors. \
    You MUST respond ONLY in English. \
    Infer the intended Thai meaning even if the transcription is imperfect. \
    Handle common Thai speech patterns: polite particles (ครับ/ค่ะ), \
    topic-comment structure, pronoun dropping, and code-switching. \
    If the user mixes Thai and English, respond naturally in English. \
    Keep responses concise and conversational — typically 1-3 sentences. \
    You're speaking out loud, so avoid markdown, code blocks, or lists. \
    Be friendly, direct, and natural.
    """

    init() {}

    func loadModel(path: String) async throws {
        AppLogger.shared.info(.llm, "Loading model from: \(path)")
        let start = CFAbsoluteTimeGetCurrent()
        llamaContext = try LlamaContext.create(path: path, contextSize: 2048)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        AppLogger.shared.info(.llm, "Model loaded in \(String(format: "%.1f", elapsed))s")
    }

    /// Generate response from conversation history.
    /// History should already contain the latest user message.
    func generate(history: [ConversationMessage] = []) -> AsyncStream<String> {
        // Cancel any previous generation first
        generationTask?.cancel()
        generationTask = nil

        return AsyncStream { continuation in
            generationTask = Task {
                guard let ctx = llamaContext else {
                    continuation.finish()
                    return
                }

                await MainActor.run {
                    self.isGenerating = true
                    self.response = ""
                    self.tokensPerSecond = 0
                }

                AppLogger.shared.info(.llm, "Generation started — history: \(history.count) messages")
                if let lastUser = history.last(where: { $0.role == .user }) {
                    AppLogger.shared.logInput(.llm, text: lastUser.text)
                }

                // Build multi-turn ChatML prompt from history
                var fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
                for message in history {
                    let role = message.role == .user ? "user" : "assistant"
                    fullPrompt += "<|im_start|>\(role)\n\(message.text)<|im_end|>\n"
                }
                // Pre-fill past <think> block to force non-thinking mode
                fullPrompt += "<|im_start|>assistant\n<think>\n</think>\n"
                AppLogger.shared.debug(.llm, "Prompt built: \(fullPrompt.count) chars, \(history.count) turns")

                let startTime = CFAbsoluteTimeGetCurrent()
                var tokenCount = 0

                do {
                    await ctx.clear()
                    try await ctx.completionInit(text: fullPrompt)

                    while !Task.isCancelled {
                        guard let token = await ctx.completionLoop() else { break }

                        tokenCount += 1

                        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                        let tps = elapsed > 0 ? Double(tokenCount) / elapsed : 0



                        // Strip non-ASCII characters
                        let cleaned = String(token.unicodeScalars.filter { $0.isASCII })
                        guard !cleaned.isEmpty else { continue }

                        continuation.yield(cleaned)

                        await MainActor.run {
                            self.response += cleaned
                            self.tokensPerSecond = tps
                        }
                    }
                } catch {
                    AppLogger.shared.error(.llm, "Generation error: \(error.localizedDescription)")
                    await MainActor.run {
                        self.error = error.localizedDescription
                    }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let finalTps = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                AppLogger.shared.info(.llm, "Generation complete — \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", finalTps)) tok/s)")
                let finalResponse = await self.response
                if !finalResponse.isEmpty {
                    AppLogger.shared.logOutput(.llm, text: finalResponse)
                }

                await MainActor.run {
                    self.isGenerating = false
                }
                continuation.finish()
            }
        }
    }

    func stopGeneration() {
        AppLogger.shared.info(.llm, "Generation stopped (cancelled)")
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    var isModelLoaded: Bool {
        llamaContext != nil
    }
}
