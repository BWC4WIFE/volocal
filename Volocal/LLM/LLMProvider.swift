// Volocal/LLM/LLMProvider.swift
// Protocol-based LLM abstraction.
// VoicePipeline holds only an `LLMProvider`, never llama.cpp types directly.

import Foundation

// MARK: - Chat Message

public struct ChatMessage: Codable {
    public enum Role: String, Codable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - LLM Token

/// A single streaming token emitted during generation.
public struct LLMToken {
    public let text: String
    public let isLast: Bool
    public init(text: String, isLast: Bool = false) {
        self.text = text
        self.isLast = isLast
    }
}

// MARK: - LLM Provider Protocol

/// Every LLM back-end conforms to this protocol.
/// Concrete types: LlamaLLMProvider, FoundationModelProvider.
public protocol LLMProvider: AnyObject {

    /// Human-readable name for debug overlay and settings.
    var name: String { get }

    /// Whether the provider has models loaded and is ready to generate.
    var isReady: Bool { get }

    /// Peak RAM consumed when loaded (used by MemoryPressureMonitor).
    var estimatedMemoryMB: Int { get }

    /// Tokens generated per second (approximate, updated after each turn).
    var tokensPerSecond: Double { get }

    // MARK: Lifecycle

    /// Load model weights into memory.  Idempotent if already loaded.
    func prepare() async throws

    /// Release model weights from memory.  Can be re-prepared later.
    func unload() async

    // MARK: Generation

    /// Stream a response for the given conversation history.
    /// - Returns: An `AsyncThrowingStream` of `LLMToken` values.
    ///   The final token has `isLast = true`.
    func generate(
        messages: [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<LLMToken, Error>

    /// Cancel an in-progress generation.
    func cancelGeneration()

    // MARK: Context Management

    /// Maximum context window in tokens.
    var maxContextTokens: Int { get }

    /// Trim `messages` to fit within the context window.
    /// Default implementation drops oldest user/assistant pairs.
    func trimmedMessages(_ messages: [ChatMessage]) -> [ChatMessage]
}

// MARK: - Default Context Trimming

public extension LLMProvider {
    func trimmedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        // Very rough token estimate: 4 chars ≈ 1 token
        let limit = maxContextTokens - 256   // reserve space for response
        var totalChars = 0
        var result: [ChatMessage] = []
        for msg in messages.reversed() {
            totalChars += msg.content.count
            if totalChars / 4 > limit { break }
            result.insert(msg, at: 0)
        }
        return result
    }
}
