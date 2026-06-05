// Volocal/STT/ParakeetASRProvider.swift
// FluidAudio Parakeet EOU adapter — streaming ASR on the Apple Neural Engine.
// Replaces the original STTManager.  English only; lowest latency; built-in EOU.

import Foundation
import FluidAudio
import AVFoundation

// MARK: - Errors

enum ParakeetASRError: LocalizedError {
    case notPrepared
    case unsupportedLanguage(ASRLanguage)
    case modelLoadFailed(underlying: Error)
    case streamingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "ParakeetASRProvider: call prepare() before streaming."
        case .unsupportedLanguage(let lang):
            return "ParakeetASRProvider: \(lang.displayName) is not supported. Use WhisperASRProvider."
        case .modelLoadFailed(let err):
            return "ParakeetASRProvider: model load failed — \(err.localizedDescription)"
        case .streamingFailed(let err):
            return "ParakeetASRProvider: streaming error — \(err.localizedDescription)"
        }
    }
}

// MARK: - ParakeetASRProvider

/// Wraps FluidAudio's `SlidingWindowAsrManager` (Parakeet EOU 120M).
/// Runs entirely on the Apple Neural Engine — leaves GPU free for the LLM.
///
/// Memory: ~200 MB peak.
/// Languages: English only.
/// EOU: Built-in end-of-utterance detection (no separate VAD needed).
public final class ParakeetASRProvider: ASRProvider {

    // MARK: ASRProvider

    public let name = "Parakeet EOU (FluidAudio)"
    public let supportedLanguages: [ASRLanguage] = [.english]
    public var estimatedMemoryMB: Int { 200 }

    public var onResult: ((ASRResult) -> Void)?
    public var onEndOfUtterance: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public private(set) var isReady = false

    // MARK: Private State

    // FluidAudio managers — initialised in prepare()
    private var asrManager: SlidingWindowAsrManager?
    private var asrModels: AsrModels?

    // Chunk-size setting (160 ms = lowest latency, 320 ms = balanced)
    private let chunkSizeMs: Int

    // Accumulates partial text between EOU events
    private var partialBuffer = ""
    private var isStreaming = false

    // MARK: Init

    /// - Parameter chunkSizeMs: 160 (default, lowest latency), 320, or 1600.
    public init(chunkSizeMs: Int = 160) {
        self.chunkSizeMs = chunkSizeMs
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        guard !isReady else { return }
        do {
            // Download (or load from cache) the Parakeet EOU 120M CoreML bundle.
            // This is the same model fikrikarim/volocal uses — no change here.
            let models = try await AsrModels.downloadAndLoad(model: .parakeetEou)
            let config = SlidingWindowConfig(
                chunkSizeMs: chunkSizeMs,
                networkDisabled: false   // set true for air-gapped; model is already local
            )
            let manager = SlidingWindowAsrManager(config: config)
            try await manager.loadModels(models)

            self.asrModels = models
            self.asrManager = manager
            self.isReady = true
        } catch {
            throw ParakeetASRError.modelLoadFailed(underlying: error)
        }
    }

    public func unload() async {
        asrManager = nil
        asrModels = nil
        isReady = false
        isStreaming = false
        partialBuffer = ""
    }

    // MARK: Streaming

    public func startStreaming(language: ASRLanguage) async throws {
        guard language == .english else {
            throw ParakeetASRError.unsupportedLanguage(language)
        }
        guard let manager = asrManager, isReady else {
            throw ParakeetASRError.notPrepared
        }
        partialBuffer = ""
        isStreaming = true

        // Wire result callbacks from FluidAudio → our protocol callbacks.
        manager.onPartialResult = { [weak self] result in
            guard let self else { return }
            let asrResult = ASRResult(
                text: result.text,
                confidence: result.confidence ?? 1.0,
                isEndOfUtterance: false,
                providerName: self.name
            )
            DispatchQueue.main.async { self.onResult?(asrResult) }
        }

        manager.onEndOfUtterance = { [weak self] result in
            guard let self else { return }
            let asrResult = ASRResult(
                text: result.text,
                confidence: result.confidence ?? 1.0,
                isEndOfUtterance: true,
                providerName: self.name
            )
            DispatchQueue.main.async {
                self.onResult?(asrResult)
                self.onEndOfUtterance?()
            }
        }

        try await manager.startStreaming()
    }

    public func appendAudioSamples(_ samples: [Float]) async throws {
        guard isStreaming, let manager = asrManager else { return }
        do {
            try await manager.appendAudioSamples(samples)
        } catch {
            throw ParakeetASRError.streamingFailed(underlying: error)
        }
    }

    public func stopStreaming() async throws {
        guard isStreaming, let manager = asrManager else { return }
        isStreaming = false
        try await manager.stopStreaming()
    }
}
