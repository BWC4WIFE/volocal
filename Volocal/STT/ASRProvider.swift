// Volocal/STT/ASRProvider.swift
// Protocol-based ASR abstraction.
// Swap Parakeet EOU ↔ WhisperKit (Thai) without touching VoicePipeline.

import Foundation
import AVFoundation

// MARK: - Language Support

/// Languages supported across ASR providers.
/// Each provider declares which set it can handle.
public enum ASRLanguage: String, CaseIterable, Identifiable, Codable {
    case english   = "en"
    case thai      = "th"
    case japanese  = "ja"
    case chinese   = "zh"
    case french    = "fr"
    case german    = "de"
    case spanish   = "es"
    case italian   = "it"
    case portuguese = "pt"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english:    return "English"
        case .thai:       return "Thai (ภาษาไทย)"
        case .japanese:   return "Japanese (日本語)"
        case .chinese:    return "Chinese (中文)"
        case .french:     return "French"
        case .german:     return "German"
        case .spanish:    return "Spanish"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese"
        }
    }
}

// MARK: - ASR Result

/// A single transcription result delivered by any ASR provider.
public struct ASRResult {
    /// The recognised text, normalised to written form where possible.
    public let text: String
    /// Confidence in [0, 1].  Providers that don't expose confidence set this to 1.
    public let confidence: Float
    /// True when the provider has detected end-of-utterance and the turn is complete.
    public let isEndOfUtterance: Bool
    /// Wall-clock timestamp of first audio sample in this chunk.
    public let timestamp: Date
    /// Provider that produced this result (for debug overlay).
    public let providerName: String

    public init(
        text: String,
        confidence: Float = 1.0,
        isEndOfUtterance: Bool = false,
        timestamp: Date = .now,
        providerName: String = "unknown"
    ) {
        self.text = text
        self.confidence = confidence
        self.isEndOfUtterance = isEndOfUtterance
        self.timestamp = timestamp
        self.providerName = providerName
    }
}

// MARK: - ASR Provider Protocol

/// Every ASR back-end conforms to this protocol.
/// VoicePipeline holds only an `ASRProvider`, never a concrete type.
public protocol ASRProvider: AnyObject {

    /// Human-readable name shown in the debug overlay and settings.
    var name: String { get }

    /// Languages this provider can handle.
    var supportedLanguages: [ASRLanguage] { get }

    /// Whether the provider is ready to accept audio.
    var isReady: Bool { get }

    /// Approximate peak RAM usage in megabytes (used by MemoryPressureMonitor).
    var estimatedMemoryMB: Int { get }

    // MARK: Lifecycle

    /// Download model assets if needed, then compile and warm up.
    /// Call once before the first `startStreaming` call.
    func prepare() async throws

    /// Release all model memory.  The provider may be re-prepared later.
    func unload() async

    // MARK: Streaming

    /// Begin accepting 16 kHz mono PCM audio chunks.
    /// - Parameter language: Must be in `supportedLanguages`.
    func startStreaming(language: ASRLanguage) async throws

    /// Feed the next chunk of 16 kHz mono Float32 samples.
    /// The provider accumulates context internally.
    func appendAudioSamples(_ samples: [Float]) async throws

    /// Stop streaming and flush any pending audio.
    /// The provider delivers a final result with `isEndOfUtterance = true`.
    func stopStreaming() async throws

    // MARK: Callbacks (set before startStreaming)

    /// Called on the main actor whenever a partial or final transcript arrives.
    var onResult: ((ASRResult) -> Void)? { get set }

    /// Called when the provider detects end-of-utterance.
    var onEndOfUtterance: (() -> Void)? { get set }

    /// Called if the provider encounters a non-fatal error mid-stream.
    var onError: ((Error) -> Void)? { get set }
}

// MARK: - Default No-Op Implementations

public extension ASRProvider {
    /// Default: provider supports English only (override in multilingual providers).
    var supportedLanguages: [ASRLanguage] { [.english] }

    /// Whether a given language is usable with this provider.
    func supports(language: ASRLanguage) -> Bool {
        supportedLanguages.contains(language)
    }
}
