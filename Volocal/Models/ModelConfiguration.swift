// Volocal/Models/ModelConfiguration.swift
// Single source of truth for all model metadata, download sizes, and runtime decisions.
//
// Usage:
//   let config = ModelConfiguration.default       // standard (English, 2B LLM)
//   let config = ModelConfiguration.thai          // Thai ASR, lite LLM
//   let config = ModelConfiguration.current       // loads from UserDefaults
//
// The configuration is passed into VoicePipeline which instantiates the
// correct ASRProvider and LLMProvider concrete types.

import Foundation
import Combine

// MARK: - ASR Backend

public enum ASRBackend: String, CaseIterable, Codable, Identifiable {
    /// Parakeet EOU via FluidAudio — English only, ultra-low latency, ANE.
    case parakeet = "parakeet_eou"
    /// Whisper Small via WhisperKit — multilingual including Thai, chunk-based.
    case whisperSmall = "whisper_small"
    /// Whisper Medium via WhisperKit — highest accuracy, heavier on RAM.
    case whisperMedium = "whisper_medium"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeet:     return "Parakeet EOU (English, ANE)"
        case .whisperSmall: return "Whisper Small (Multilingual, 290 MB)"
        case .whisperMedium:return "Whisper Medium (Multilingual, 780 MB)"
        }
    }

    public var supportedLanguages: [ASRLanguage] {
        switch self {
        case .parakeet:              return [.english]
        case .whisperSmall, .whisperMedium: return ASRLanguage.allCases
        }
    }

    public var downloadSizeMB: Int {
        switch self {
        case .parakeet:      return 450
        case .whisperSmall:  return 290
        case .whisperMedium: return 780
        }
    }

    public var estimatedRAMMB: Int {
        switch self {
        case .parakeet:      return 200
        case .whisperSmall:  return 290
        case .whisperMedium: return 780
        }
    }
}

// MARK: - LLM Backend

public enum LLMBackend: String, CaseIterable, Codable, Identifiable {
    /// Qwen3.5-2B Q4_K_S via llama.cpp — standard quality/speed.
    case qwen2B = "qwen3.5_2b"
    /// Qwen3.5-0.8B Q4_K_S via llama.cpp — memory-efficient, faster.
    case qwen0_8B = "qwen3.5_0.8b"
    /// Apple Foundation Models — iOS 26+, no download required.
    case appleFoundation = "apple_foundation"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen2B:          return "Qwen3.5-2B (1.26 GB, ~32 tok/s)"
        case .qwen0_8B:        return "Qwen3.5-0.8B (520 MB, ~70 tok/s)"
        case .appleFoundation: return "Apple Foundation Models (iOS 26+, 0 MB)"
        }
    }

    public var downloadSizeMB: Int {
        switch self {
        case .qwen2B:          return 1260
        case .qwen0_8B:        return 520
        case .appleFoundation: return 0
        }
    }

    public var estimatedRAMMB: Int {
        switch self {
        case .qwen2B:          return 1260
        case .qwen0_8B:        return 520
        case .appleFoundation: return 0
        }
    }

    public var memoryTier: LLMMemoryTier {
        switch self {
        case .qwen2B, .appleFoundation: return .standard
        case .qwen0_8B:                 return .lite
        }
    }

    public var isAvailable: Bool {
        if self == .appleFoundation {
            return FoundationModelProvider.isSupported
        }
        return true
    }
}

// MARK: - ModelConfiguration

/// Immutable snapshot of the user's chosen model stack.
/// Build one, pass it to VoicePipeline, and regenerate when the user changes settings.
public struct ModelConfiguration: Codable, Equatable {

    // MARK: Properties

    public let asrBackend: ASRBackend
    public let asrLanguage: ASRLanguage
    public let llmBackend: LLMBackend

    // MARK: Derived

    /// Total download size in MB for a fresh install.
    public var totalDownloadMB: Int {
        asrBackend.downloadSizeMB + llmBackend.downloadSizeMB + 600   // PocketTTS ~600 MB
    }

    /// Estimated peak RAM in MB when all three models are loaded.
    public var peakRAMMB: Int {
        asrBackend.estimatedRAMMB + llmBackend.estimatedRAMMB + 600   // PocketTTS
    }

    // MARK: Presets

    /// Default English configuration — matches original Volocal.
    public static let `default` = ModelConfiguration(
        asrBackend: .parakeet,
        asrLanguage: .english,
        llmBackend: .qwen2B
    )

    /// Thai-focused — WhisperKit Small ASR + lighter LLM.
    public static let thai = ModelConfiguration(
        asrBackend: .whisperSmall,
        asrLanguage: .thai,
        llmBackend: .qwen0_8B
    )

    /// Maximum quality — Whisper Medium + 2B LLM (device must have ≥ 4 GB budget).
    public static let highQuality = ModelConfiguration(
        asrBackend: .whisperMedium,
        asrLanguage: .english,
        llmBackend: .qwen2B
    )

    /// Memory-efficient — lite LLM, Parakeet EOU.
    public static let lite = ModelConfiguration(
        asrBackend: .parakeet,
        asrLanguage: .english,
        llmBackend: .qwen0_8B
    )

    // MARK: UserDefaults Persistence

    private static let udKey = "volocal.modelConfiguration"

    public static var current: ModelConfiguration {
        get {
            guard
                let data = UserDefaults.standard.data(forKey: udKey),
                let config = try? JSONDecoder().decode(ModelConfiguration.self, from: data)
            else { return .default }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: udKey)
            }
        }
    }

    // MARK: Factory — Provider Instantiation

    /// Build the correct ASRProvider for this configuration.
    public func makeASRProvider() -> any ASRProvider {
        switch asrBackend {
        case .parakeet:
            return ParakeetASRProvider(chunkSizeMs: 160)
        case .whisperSmall:
            return WhisperASRProvider(modelVariant: .small)
        case .whisperMedium:
            return WhisperASRProvider(modelVariant: .medium)
        }
    }

    /// Build the correct LLMProvider for this configuration.
    public func makeLLMProvider() -> any LLMProvider {
        switch llmBackend {
        case .qwen2B:
            return LlamaLLMProvider(tier: .standard)
        case .qwen0_8B:
            return LlamaLLMProvider(tier: .lite)
        case .appleFoundation:
            if FoundationModelProvider.isSupported {
                return FoundationModelProvider()
            }
            // Graceful fallback — should not reach here if UI checks isAvailable
            return LlamaLLMProvider(tier: .lite)
        }
    }
}
