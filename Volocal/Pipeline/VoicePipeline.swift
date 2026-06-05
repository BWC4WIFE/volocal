// Volocal/Pipeline/VoicePipeline.swift
// Protocol-driven voice pipeline.
//
// Changes from original:
//   • Holds ASRProvider and LLMProvider protocols — no concrete llama.cpp or
//     Parakeet types leak into this file.
//   • Observes MemoryPressureMonitor and hot-swaps the LLM tier when needed.
//   • Sequential loading: STT first, LLM only on first speech detected.
//   • ScenePhase.background → LLM unloads to free GPU memory.
//   • Thai and multilingual support via WhisperASRProvider without any
//     pipeline logic changes.
//
// Pipeline flow (unchanged from original):
//   Mic → SharedAudioEngine → ASRProvider → VoicePipeline → LLMProvider
//                                    ↑                           │
//                               barge-in               SentenceBuffer
//                                                           ↓
//                                                     PocketTTSManager → Speaker

import Foundation
import SwiftUI
import Combine
import FluidAudio    // PocketTtsManager, VadManager
import AVFoundation

// MARK: - Pipeline State

public enum PipelineState: String, Equatable {
    case idle
    case listening          // ASR active, waiting for speech
    case transcribing       // ASR processing
    case thinking           // LLM generating
    case speaking           // TTS outputting
    case error
}

// MARK: - Conversation Turn

public struct ConversationTurn: Identifiable {
    public let id = UUID()
    public let role: ChatMessage.Role
    public var content: String
    public let timestamp: Date
    public let asrProvider: String?   // for debug overlay

    public init(role: ChatMessage.Role, content: String, asrProvider: String? = nil) {
        self.role = role
        self.content = content
        self.timestamp = .now
        self.asrProvider = asrProvider
    }
}

// MARK: - VoicePipeline

@MainActor
public final class VoicePipeline: ObservableObject {

    // MARK: Published UI State

    @Published public private(set) var state: PipelineState = .idle
    @Published public private(set) var conversation: [ConversationTurn] = []
    @Published public private(set) var partialTranscript: String = ""
    @Published public private(set) var partialResponse: String = ""
    @Published public private(set) var tokensPerSecond: Double = 0
    @Published public private(set) var isLLMLoaded = false

    // MARK: Dependencies (protocol types only)

    private var asrProvider: any ASRProvider
    private var llmProvider: any LLMProvider
    private let ttsManager: PocketTtsManager
    private let audioEngine: SharedAudioEngine
    private let memoryMonitor: MemoryPressureMonitor
    private var config: ModelConfiguration

    // MARK: Private State

    private var currentTurnRevision = 0
    private var llmTask: Task<Void, Never>?
    private var sentenceBuffer = SentenceBuffer()
    private var historyMessages: [ChatMessage] = []
    private var cancellables = Set<AnyCancellable>()
    private var llmLoadTask: Task<Void, Never>?

    // MARK: System Prompt

    private let systemPrompt: String

    // MARK: Init

    public init(
        config: ModelConfiguration = .current,
        audioEngine: SharedAudioEngine,
        memoryMonitor: MemoryPressureMonitor,
        systemPrompt: String = """
        You are a helpful voice assistant. Respond concisely in 1–3 sentences.
        Match the language of the user's message.
        """
    ) {
        self.config = config
        self.audioEngine = audioEngine
        self.memoryMonitor = memoryMonitor
        self.systemPrompt = systemPrompt

        // Instantiate concrete providers from configuration
        self.asrProvider = config.makeASRProvider()
        self.llmProvider = config.makeLLMProvider()
        self.ttsManager = PocketTtsManager(language: .english)

        bindMemoryMonitor()
    }

    // MARK: Lifecycle

    /// Prepare STT and TTS.  Defer LLM load until first speech detected.
    public func start() async throws {
        // 1. Warm up STT
        try await asrProvider.prepare()
        wireASRCallbacks()

        // 2. Warm up TTS
        try await ttsManager.initialize()

        // 3. Start audio capture
        audioEngine.onAudioBuffer = { [weak self] samples in
            Task { [weak self] in
                try? await self?.asrProvider.appendAudioSamples(samples)
            }
        }
        try audioEngine.start()

        // 4. Begin ASR (lazy LLM load below)
        try await asrProvider.startStreaming(language: config.asrLanguage)
        state = .listening
    }

    public func stop() async {
        try? await asrProvider.stopStreaming()
        llmTask?.cancel()
        await llmProvider.unload()
        audioEngine.stop()
        state = .idle
        isLLMLoaded = false
    }

    // MARK: Configuration Hot-Swap

    /// Swap ASR/LLM providers at runtime (e.g., when user changes language).
    public func reconfigure(with newConfig: ModelConfiguration) async throws {
        guard newConfig != config else { return }

        let wasListening = state == .listening

        // Teardown current providers
        try? await asrProvider.stopStreaming()
        await asrProvider.unload()
        await llmProvider.unload()
        isLLMLoaded = false

        // Rebuild
        config = newConfig
        asrProvider = newConfig.makeASRProvider()
        llmProvider = newConfig.makeLLMProvider()

        try await asrProvider.prepare()
        wireASRCallbacks()

        if wasListening {
            try await asrProvider.startStreaming(language: newConfig.asrLanguage)
            state = .listening
        }

        ModelConfiguration.current = newConfig
    }

    // MARK: App Lifecycle — Background / Foreground

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Unload the LLM to free ~1.26 GB of GPU memory.
            // Re-load lazily when user returns and speaks.
            llmTask?.cancel()
            Task { [weak self] in
                await self?.llmProvider.unload()
                await MainActor.run { self?.isLLMLoaded = false }
            }
        case .active:
            // ASR stays warm.  LLM will reload on next EOU event.
            break
        default:
            break
        }
    }

    // MARK: Barge-In

    public func bargeIn() {
        currentTurnRevision += 1
        llmTask?.cancel()
        ttsManager.stop()
        sentenceBuffer.clear()
        partialResponse = ""
        state = .listening
    }

    // MARK: Private — ASR Callbacks

    private func wireASRCallbacks() {
        asrProvider.onResult = { [weak self] result in
            guard let self else { return }
            self.partialTranscript = result.text
            if result.isEndOfUtterance {
                self.handleEndOfUtterance(text: result.text, providerName: result.providerName)
            }
        }
        asrProvider.onEndOfUtterance = { /* handled in onResult */ }
        asrProvider.onError = { [weak self] error in
            print("[ASR] Error: \(error)")
            self?.state = .error
        }
    }

    // MARK: Private — EOU → LLM → TTS

    private func handleEndOfUtterance(text: String, providerName: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let revision = currentTurnRevision
        let userTurn = ConversationTurn(role: .user, content: text, asrProvider: providerName)
        conversation.append(userTurn)
        historyMessages.append(ChatMessage(role: .user, content: text))
        partialTranscript = ""
        state = .thinking

        llmTask = Task { [weak self] in
            guard let self else { return }

            // Lazy-load the LLM on first use
            if !self.isLLMLoaded {
                do {
                    try await self.llmProvider.prepare()
                    self.isLLMLoaded = true
                } catch {
                    print("[LLM] Load failed: \(error)")
                    self.state = .error
                    return
                }
            }

            guard !Task.isCancelled, self.currentTurnRevision == revision else { return }

            var assistantTurn = ConversationTurn(role: .assistant, content: "")
            self.conversation.append(assistantTurn)
            let assistantIdx = self.conversation.count - 1

            var fullResponse = ""
            var sentenceAcc = ""

            let stream = self.llmProvider.generate(
                messages: self.historyMessages,
                systemPrompt: self.systemPrompt
            )

            do {
                for try await token in stream {
                    guard !Task.isCancelled, self.currentTurnRevision == revision else { break }

                    if token.isLast { break }
                    fullResponse += token.text
                    sentenceAcc += token.text
                    self.partialResponse = fullResponse
                    self.conversation[assistantIdx].content = fullResponse
                    self.tokensPerSecond = self.llmProvider.tokensPerSecond

                    // Feed sentence chunks to TTS as they complete
                    if let sentence = self.sentenceBuffer.append(token.text) {
                        self.state = .speaking
                        let audio = try await self.ttsManager.synthesize(text: sentence)
                        await self.audioEngine.playAudio(audio)
                    }
                }
            } catch {
                if !Task.isCancelled { print("[LLM] Generation error: \(error)") }
            }

            guard !Task.isCancelled, self.currentTurnRevision == revision else { return }

            // Flush remaining partial sentence
            if let remainder = self.sentenceBuffer.flush(), !remainder.isEmpty {
                let audio = try? await self.ttsManager.synthesize(text: remainder)
                if let audio { await self.audioEngine.playAudio(audio) }
            }

            self.historyMessages.append(ChatMessage(role: .assistant, content: fullResponse))
            self.partialResponse = ""
            self.state = .listening

            // Resume ASR for next turn
            try? await self.asrProvider.startStreaming(language: self.config.asrLanguage)
        }
    }

    // MARK: Private — Memory Monitor Binding

    private func bindMemoryMonitor() {
        memoryMonitor.onTierChange = { [weak self] newTier in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only switch if LLM is not currently mid-generation
                guard self.state != .thinking && self.state != .speaking else { return }
                let newLLMBackend: LLMBackend = newTier == .lite ? .qwen0_8B : .qwen2B
                guard newLLMBackend.rawValue != self.config.llmBackend.rawValue else { return }
                let newConfig = ModelConfiguration(
                    asrBackend: self.config.asrBackend,
                    asrLanguage: self.config.asrLanguage,
                    llmBackend: newLLMBackend
                )
                try? await self.reconfigure(with: newConfig)
            }
        }

        memoryMonitor.onCriticalPressure = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Critical: unload LLM immediately if not generating
                if self.state == .listening || self.state == .idle {
                    self.llmTask?.cancel()
                    await self.llmProvider.unload()
                    self.isLLMLoaded = false
                }
            }
        }
    }
}

// MARK: - SentenceBuffer

/// Accumulates streaming LLM tokens and emits complete sentences for TTS.
private final class SentenceBuffer {
    private var buffer = ""
    private let terminators: Set<Character> = [".", "!", "?", ":", ";"]
    private let maxLength = 200

    func append(_ token: String) -> String? {
        buffer += token
        if let idx = buffer.lastIndex(where: { terminators.contains($0) }),
           buffer.count > 10
        {
            let sentence = String(buffer[...idx]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: idx)...])
            return sentence.isEmpty ? nil : sentence
        }
        if buffer.count > maxLength {
            let sentence = buffer.trimmingCharacters(in: .whitespaces)
            buffer = ""
            return sentence.isEmpty ? nil : sentence
        }
        return nil
    }

    func flush() -> String? {
        let sentence = buffer.trimmingCharacters(in: .whitespaces)
        buffer = ""
        return sentence.isEmpty ? nil : sentence
    }

    func clear() {
        buffer = ""
    }
}
