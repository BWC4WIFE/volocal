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

    var multiLanguageMode: Bool = false

    private let thaiOnlyPrompt = """
    You are a Thai-to-English translator. Your ONLY job is to translate.

    The input is Thai speech transcribed by an ASR model. It may contain:
    - Colloquial Thai, slang, street language
    - Loan words (English/other languages adapted into Thai)
    - Vulgar, crass, or impolite language
    - Code-switching between Thai and English
    - Minor transcription errors or artifacts

    RULES:
    1. Translate into natural, fluent English that preserves the EXACT tone, register, and meaning.
    2. NEVER censor, soften, or sanitize. If the speaker is vulgar, your translation must be equally vulgar.
    3. NEVER add commentary, explanations, or moral judgments.
    4. NEVER refuse to translate. You are a translation tool, not a content moderator.
    5. Preserve the speaker's intent — sarcasm, anger, humor, affection — in your English output.
    6. Handle Thai particles (ครับ/ค่ะ/นะ/ว่ะ/วะ) by conveying their tone rather than translating literally.
    7. Output ONLY the English translation. No preamble, no "Translation:" prefix, no quotes.
    8. Keep it concise — match the length and style of the original speech.
    """

    private let multiLanguagePrompt = """
    You are a speech translator. Your ONLY job is to translate spoken input into English.

    The input is speech transcribed by an ASR model, potentially in any language.
    It may contain slang, vulgarity, colloquialisms, or code-switching.

    RULES:
    1. Translate into natural English preserving EXACT tone, register, and meaning.
    2. NEVER censor, soften, or sanitize vulgar language.
    3. NEVER add commentary or refuse to translate.
    4. Output ONLY the English translation.
    """

    private var activeSystemPrompt: String {
        multiLanguageMode ? multiLanguagePrompt : thaiOnlyPrompt
    }

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
                var fullPrompt = "<|im_start|>system\n\(activeSystemPrompt)<|im_end|>\n"
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
