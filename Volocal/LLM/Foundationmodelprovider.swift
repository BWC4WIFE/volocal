// Volocal/LLM/FoundationModelProvider.swift
// Apple Foundation Models adapter — zero-GGUF LLM path for iOS 26+.
//
// WHY THIS EXISTS:
//   Apple Intelligence (iOS 26) ships ~3B parameter on-device models
//   accessed through the FoundationModels framework.  No GGUF download,
//   no Metal GPU contention — inference runs through the system daemon
//   on dedicated Silicon paths.
//
//   This provider replaces LlamaLLMProvider entirely when available,
//   saving ~1.26 GB of download and eliminating GPU/LLM competition.
//
// STATUS:  Guarded by @available(iOS 26, *).
//   On iOS 17-25, the pipeline falls back to LlamaLLMProvider automatically.
//   Stub out the body if FoundationModels isn't in your SDK yet;
//   the availability guard prevents compilation issues on earlier toolchains.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - FoundationModelProvider

public final class FoundationModelProvider: LLMProvider {

    public let name = "Apple Foundation Models (iOS 26+)"
    public let maxContextTokens = 8192
    public var estimatedMemoryMB: Int { 0 }   // managed by system daemon
    public private(set) var tokensPerSecond: Double = 0
    public private(set) var isReady = false

    private var isCancelled = false
    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    public init() {}

    // MARK: Availability Check

    /// Returns true when Foundation Models are available and eligible on this device.
    public static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            // FoundationModels loads lazily — just mark ready.
            isReady = true
            return
        }
        #endif
        // Should not reach here if isSupported was checked first.
        isReady = false
    }

    public func unload() async {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            session = nil
        }
        #endif
        isReady = false
    }

    // MARK: Generation

    public func generate(
        messages: [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<LLMToken, Error> {

        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                Task {
                    do {
                        // Build a FoundationModels prompt from ChatMessage history
                        var instructions = Instructions(systemPrompt)
                        var transcript = Transcript()
                        for msg in self.trimmedMessages(messages) {
                            switch msg.role {
                            case .user:
                                transcript.append(.prompt(msg.content))
                            case .assistant:
                                transcript.append(.response(msg.content))
                            case .system:
                                break  // handled above
                            }
                        }

                        let model = SystemLanguageModel.default
                        let newSession = LanguageModelSession(
                            model: model,
                            instructions: instructions,
                            transcript: transcript
                        )
                        self.session = newSession

                        let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""
                        let startTime = Date()
                        var nTokens = 0

                        for try await partialResponse in newSession.streamResponse(to: lastUser) {
                            guard !self.isCancelled else { break }
                            nTokens += 1
                            continuation.yield(LLMToken(text: partialResponse, isLast: false))
                        }

                        let elapsed = Date().timeIntervalSince(startTime)
                        if elapsed > 0 { self.tokensPerSecond = Double(nTokens) / elapsed }

                        continuation.yield(LLMToken(text: "", isLast: true))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            } else {
                continuation.finish(throwing: FoundationModelError.unavailable)
            }
            #else
            continuation.finish(throwing: FoundationModelError.unavailable)
            #endif
        }
    }

    public func cancelGeneration() {
        isCancelled = true
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            session?.cancel()
        }
        #endif
    }
}

// MARK: - Error

enum FoundationModelError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Apple Foundation Models require iOS 26+ and Apple Intelligence eligibility."
    }
}
