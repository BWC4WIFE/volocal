// Volocal/Models/ModelRegistry+Thai.swift
// Extends the existing ModelRegistry with Thai-specific WhisperKit model entries.
//
// These entries drive the download manager UI — the same progress bars and
// storage checks that show for Parakeet/PocketTTS will also appear for
// Whisper Small/Medium when the Thai configuration is active.

import Foundation

// MARK: - Model Entry Extension

extension ModelEntry {
    // MARK: WhisperKit Thai Entries

    /// Whisper Small CoreML — recommended for Thai.
    static let whisperSmallThai = ModelEntry(
        id: "whisper-small-th",
        displayName: "Whisper Small (Thai / Multilingual)",
        description: "OpenAI Whisper Small converted to CoreML. Supports Thai and 99 other languages.",
        sizeBytes: 290 * 1_048_576,
        huggingFaceRepo: "argmaxinc/whisperkit-coreml",
        filename: "openai_whisper-small",
        isDirectory: true,   // WhisperKit downloads a directory of .mlpackage files
        requiredFor: [.thai]
    )

    /// Whisper Medium CoreML — higher accuracy option.
    static let whisperMediumThai = ModelEntry(
        id: "whisper-medium-th",
        displayName: "Whisper Medium (Thai / Multilingual)",
        description: "Higher accuracy multilingual ASR. Recommended for Thai in noisy environments.",
        sizeBytes: 780 * 1_048_576,
        huggingFaceRepo: "argmaxinc/whisperkit-coreml",
        filename: "openai_whisper-medium",
        isDirectory: true,
        requiredFor: [.thai]
    )
}

// MARK: - ModelRegistry Extension

extension ModelRegistry {

    /// All Thai-configuration model entries.
    static var thaiEntries: [ModelEntry] {
        [.whisperSmallThai, .whisperMediumThai]
    }

    /// Returns the correct model entries for a given ModelConfiguration.
    static func entries(for config: ModelConfiguration) -> [ModelEntry] {
        var entries: [ModelEntry] = []

        // STT
        switch config.asrBackend {
        case .parakeet:
            entries.append(.parakeetEou)           // existing entry
        case .whisperSmall:
            entries.append(.whisperSmallThai)
        case .whisperMedium:
            entries.append(.whisperMediumThai)
        }

        // LLM
        switch config.llmBackend {
        case .qwen2B:
            entries.append(.qwen2B)                // existing entry
        case .qwen0_8B:
            entries.append(.qwen0_8B)              // new lite entry
        case .appleFoundation:
            break   // no download needed
        }

        // TTS (always PocketTTS)
        entries.append(.pocketTTS)                 // existing entry

        return entries
    }
}

// MARK: - Qwen 0.8B Entry

extension ModelEntry {
    static let qwen0_8B = ModelEntry(
        id: "qwen3.5-0.8b-q4ks",
        displayName: "Qwen3.5-0.8B (Lite LLM, 520 MB)",
        description: "Smaller, faster language model. Recommended when memory is limited or Thai ASR is active.",
        sizeBytes: 520 * 1_048_576,
        huggingFaceRepo: "bartowski/Qwen_Qwen3.5-0.8B-GGUF",
        filename: "Qwen3.5-0.8B-Q4_K_S.gguf",
        isDirectory: false,
        requiredFor: [.english, .thai]
    )
}
