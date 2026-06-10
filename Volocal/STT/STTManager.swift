import Foundation
import AVFoundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.volocal.app", category: "stt")

/// Wraps FluidAudio's Qwen3ASRManager for on-device speech-to-text
/// optimized for Thai language on Apple Neural Engine.
///
/// Qwen3-ASR is an encoder-decoder model running as CoreML.
/// Audio buffers are accumulated into chunks; VAD-based silence detection triggers
/// full transcription via Qwen3ASRManager.transcribe(audioSamples:language:).
/// Uses VadManager (Silero VAD CoreML) if available, falls back to energy-based
/// RMS threshold detection. Silence threshold reduced to ~0.5s for faster
/// utterance boundary detection. Emits partial results every ~2s.
///
/// Uses SharedAudioEngine for mic input instead of creating its own AVAudioEngine.
@available(iOS 18.0, *)
@MainActor
final class STTManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var partialResult: String = ""
    @Published var error: String?

    /// Called when a complete utterance is transcribed.
    var onUtteranceCompleted: ((String) -> Void)?

        /// Called when speech is first detected (non-silence).
    var onSpeechDetected: (() -> Void)?

    /// Called with interim partial results during active speech.
    var onPartialResult: ((String) -> Void)?

    /// Shared audio engine — injected by VoicePipeline.
    weak var sharedAudio: SharedAudioEngine?

    /// ASR language. Default is Thai ("th"). Pass nil for auto-detection.
    var language: String? = "th"

    /// Model variant: prefer f32 for stability in autoregressive decoding.
    private let modelVariant: Qwen3AsrVariant = .f32

        private var asrManager: Qwen3AsrManager?
        private var vadManager: VadManager?
        private var vadStreamState: VadStreamState?
        private var hasFiredSpeechDetected = false
        private var isStopping = false

        /// Accumulates audio samples for the current utterance (16kHz mono Float32).
        private var audioBuffer: [Float] = []

        /// Minimum audio duration before transcription (1.0s at 16kHz).
        private let minAudioSamples = 16_000

        /// Maximum audio duration before forced transcription (30s at 16kHz).
        private let maxAudioSamples = 480_000

        /// Partial result interval in samples. Emits interim transcription every ~2s at 16kHz.
        private let partialResultIntervalSamples = 32_000

        /// Last sample count at which we emitted a partial result.
        private var lastPartialSampleCount: Int = 0

        /// VAD buffer accumulates 16kHz mono samples until we have a full chunk (4096).
        private var vadBuffer: [Float] = []

        /// Tracks whether VAD has detected sustained silence since last utterance.
        private var didSpeechEnd: Bool = false

        /// Energy-based VAD fallback state (used when VadManager is unavailable).
        private let silenceEnergyThreshold: Float = 0.01
        private var consecutiveSilenceChunks: Int = 0
        /// Minimum consecutive silent chunks to trigger end-of-utterance.
        /// Each chunk is VadManager.chunkSize (4096) samples = 256ms at 16kHz.
        /// 2 chunks = ~0.5s.
        private let silenceChunksThreshold = 2

        /// Serial stream for backpressure — prevents unbounded Task spawning per audio buffer.
        private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        private var processingTask: Task<Void, Never>?

        init() {}

            /// Download Qwen3-ASR CoreML models from HuggingFace and load into memory.
            /// Also initializes FluidAudio's VadManager for accurate voice activity detection.
            func initialize() async {
                do {
                    logger.info(
                        "Initializing Qwen3-ASR (\(self.modelVariant.rawValue))..."
                    )

                    let cacheDir = Qwen3AsrModels.defaultCacheDirectory(
                        variant: modelVariant
                    )

                    try await Qwen3AsrModels.download(variant: modelVariant)

                    let manager = Qwen3AsrManager()
                    try await manager.loadModels(
                        from: cacheDir,
                        computeUnits: .all
                    )

                    self.asrManager = manager
                    logger.info("Qwen3-ASR (\(self.modelVariant.rawValue)) ready")

                    // Initialize FluidAudio's VadManager (Silero VAD CoreML) if available.
                    // Failure is non-fatal: falls back to energy-based silence detection.
                    do {
                        logger.info("Attempting VadManager init (Silero VAD)...")
                        let vad = try await VadManager(
                            config: VadConfig(
                                defaultThreshold: 0.5,
                                computeUnits: .all
                            )
                        )
                        self.vadManager = vad
                        logger.info("VadManager ready")
                    } catch {
                        logger.warning(
                            "VadManager init failed, using energy-based VAD: "
                                \(error.localizedDescription, privacy: .public)"
                            )
                    }
        } catch {
                    self.error = "STT init failed: \(error.localizedDescription)"
                                        logger.error("STT init failed: \(error.localizedDescription, privacy: .public)")
                }
            }

    func startListening() {
        guard !isListening, asrManager != nil else {
            if asrManager == nil {  = "STT not initialized" }
            return
        }
        guard let sharedAudio else {
            error = "No shared audio engine"
            return
        }

                isStopping = false

        // Reset audio accumulation state
        audioBuffer.removeAll(keepingCapacity: true)
        vadBuffer.removeAll(keepingCapacity: true)
        vadStreamState = VadStreamState.initial()
        lastPartialSampleCount = 0

        // Set up serial AsyncStream for backpressure
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.bufferContinuation = continuation

        processingTask = Task { [weak self] in
            guard let manager = self?.asrManager else { return }
            let vad = self?.vadManager
            for await buffer in stream {
                guard let self, !Task.isCancelled else { break }
                await self.processAudioBuffer(
                    buffer,
                    manager: manager,
                    vad: vad
                )
            }
        }

        // Start mic capture with VP AEC (restarts engine with tap installed).
        // Set bridge continuation so tap handler delivers buffers to our stream.
        sharedAudio.bridge.inputContinuation = continuation
        sharedAudio.beginInputCapture()

        isListening = true
        transcript = ""
        partialResult = ""
        hasFiredSpeechDetected = false
        error = nil
        logger.info("STT listening started (lang=\(self.language ?? "auto"))")
    }

    /// Process an audio buffer from the mic tap.
    /// Converts to 16kHz mono Float32, runs VAD for speech detection,
    /// accumulates, and triggers transcription when VAD detects sustained silence
    /// or the buffer exceeds maximum length.
    /// Emits partial results every ~2 seconds during active speech.
    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        manager: Qwen3AsrManager,
        vad: VadManager?
    ) async {
        guard !isStopping else { return }

        // Extract and resample audio samples to 16kHz mono Float32
        let samples = extractMonoSamples(from: buffer)
        guard !samples.isEmpty else { return }

        // Accumulate into main audio buffer
        audioBuffer.append(contentsOf: samples)

        // Accumulate into VAD buffer and process when we have enough samples
        vadBuffer.append(contentsOf: samples)

        // Process VAD in chunkSize increments via FluidAudio's streaming API
        let vadChunkSize = VadManager.chunkSize
        while vadBuffer.count >= vadChunkSize {
            let chunk = Array(vadBuffer.prefix(vadChunkSize))
            vadBuffer.removeFirst(vadChunkSize)

            if let vad, let state = vadStreamState {
                await processVadChunk(chunk, vad: vad, state: state)
            } else {
                // Fallback: simple energy-based VAD if VadManager unavailable
                fallbackVadChunk(chunk)
            }
        }

        // Emit partial result every ~2 seconds during active speech
        if audioBuffer.count - lastPartialSampleCount >= partialResultIntervalSamples
            && audioBuffer.count >= minAudioSamples
            && hasFiredSpeechDetected {
            lastPartialSampleCount = audioBuffer.count
            let partialSamples = audioBuffer
            Task { [weak self] in
                guard let self, let manager = self.asrManager else { return }
                await self.emitPartialResult(partialSamples, manager: manager)
            }
        }

        // Check if we should transcribe:
        // VAD speechEnd event has fired and we have enough audio, or buffer maxed out
        let shouldTranscribe =
            audioBuffer.count >= maxAudioSamples
            || (audioBuffer.count >= minAudioSamples
                && hasFiredSpeechDetected
                && didSpeechEnd)

        // Reset the flag after reading
        let transcribeNow = shouldTranscribe
        if transcribeNow {
            didSpeechEnd = false
        }

        if transcribeNow && !audioBuffer.isEmpty {
            let samplesToTranscribe = audioBuffer
            audioBuffer.removeAll(keepingCapacity: true)
            vadBuffer.removeAll(keepingCapacity: true)
            lastPartialSampleCount = 0

            await performTranscription(samplesToTranscribe, manager: manager)
        }
    }

    /// Process a VAD chunk through FluidAudio's streaming API.
    /// Uses VadSegmentationConfig with 0.5s minSilenceDuration for faster
    /// end-of-utterance detection.
    private func processVadChunk(
        _ chunk: [Float],
        vad: VadManager,
        state: VadStreamState
    ) async {
        do {
            let result = try await vad.processStreamingChunk(
                chunk,
                state: state,
                                config: VadSegmentationConfig(
                    minSpeechDuration: 0.15,
                    minSilenceDuration: 0.5,
                    maxSpeechDuration: 14.0,
                    speechPadding: 0.1
                ),
                returnSeconds: false,
                timeResolution: 1
            )
            vadStreamState = result.state

            // Use probability for noise-adaptive threshold
            // In noisy environments, the threshold can be adjusted dynamically

            if let event = result.event {
                if event.isStart {
                    hasFiredSpeechDetected = true
                    await MainActor.run {
                        self.onSpeechDetected?()
                    }
                } else if event.isEnd {
                    didSpeechEnd = true
                }
            }
        } catch {
                        logger.error(
                "VAD stream error: \(error.localizedDescription, privacy: .public)"
            )
            // Fallback: assume voice is active to avoid clipping speech
            if !hasFiredSpeechDetected {
                hasFiredSpeechDetected = true
                await MainActor.run {
                    self.onSpeechDetected?()
                }
            }
        }
    }

        /// Fallback VAD using simple energy-based detection when VadManager is unavailable.
    private func fallbackVadChunk(_ chunk: [Float]) {
        let energy = calculateRMS(chunk)
        let isSilence = energy < silenceEnergyThreshold

                if isSilence {
            consecutiveSilenceChunks += 1
            if consecutiveSilenceChunks >= silenceChunksThreshold
                && hasFiredSpeechDetected {
                didSpeechEnd = true
            }
        } else {
            consecutiveSilenceChunks = 0
            if !hasFiredSpeechDetected {
                hasFiredSpeechDetected = true
                onSpeechDetected?()
            }
        }
    }

    /// Emit a partial transcription from the accumulating buffer.
    private func emitPartialResult(
        _ samples: [Float],
        manager: Qwen3AsrManager
    ) async {
        guard samples.count >= minAudioSamples else { return }
        do {
            let text = try await manager.transcribe(
                audioSamples: samples,
                language: language
            )
            let trimmedText = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedText.isEmpty else { return }
            await MainActor.run {
                guard !self.isStopping else { return }
                self.partialResult = trimmedText
                self.onPartialResult?(trimmedText)
            }
        } catch {
                        logger.debug(
                "Partial transcription failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Transcribe accumulated audio samples using Qwen3-ASR.
    private func performTranscription(
        _ samples: [Float],
        manager: Qwen3AsrManager
    ) async {
        do {
            let duration = Double(samples.count) / 16_000.0
                        logger.debug(
                "Transcribing \(samples.count) samples (\(String(format: "%.1f", duration))s)"
            )

            let text = try await manager.transcribe(
                audioSamples: samples,
                language: language
            )

            let trimmedText = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedText.isEmpty else { return }

            await MainActor.run {
                guard !self.isStopping else { return }
                                self.transcript = trimmedText
                self.partialResult = ""
                self.hasFiredSpeechDetected = false
                self.didSpeechEnd = false
                self.onUtteranceCompleted?(trimmedText)
            }

            logger.info("Transcribed: \"\(trimmedText)\"")
        } catch {
            await MainActor.run {
                guard !self.isStopping else { return }
                                logger.error(
                    "Transcription failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Audio Processing

    /// Extract mono Float32 samples from an AVAudioPCMBuffer,
    /// resampling to 16kHz if needed (Qwen3-ASR expects 16kHz mono).
    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let srcFormat = buffer.format
        let srcRate = Float(srcFormat.sampleRate)
        let srcChannels = Int(srcFormat.channelCount)
        let srcFrames = Int(buffer.frameLength)

        guard srcFrames > 0, let srcData = buffer.floatChannelData else {
            return []
        }

        var mono: [Float]

        if srcChannels == 1 {
            mono = Array(
                UnsafeBufferPointer(start: srcData[0], count: srcFrames)
            )
        } else {
            // Stereo/multi-channel: average all channels
            mono = [Float](repeating: 0, count: srcFrames)
            for ch in 0..<srcChannels {
                let chData = UnsafeBufferPointer(
                    start: srcData[ch],
                    count: srcFrames
                )
                for i in 0..<srcFrames {
                    mono[i] += chData[i] / Float(srcChannels)
                }
            }
        }

        guard srcRate != 16000 else { return mono }
        return resample(mono, fromRate: srcRate, toRate: 16000)
    }

    /// Linear interpolation resampler.
    private func resample(
        _ input: [Float],
        fromRate: Float,
        toRate: Float
    ) -> [Float] {
        guard fromRate != toRate, !input.isEmpty else { return input }

        let ratio = fromRate / toRate
        let outputLength = Int(Float(input.count) / ratio)
        var output = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let srcPos = Float(i) * ratio
            let srcIdx = Int(srcPos)
            let frac = srcPos - Float(srcIdx)

            if srcIdx + 1 < input.count {
                output[i] =
                    input[srcIdx] * (1 - frac) + input[srcIdx + 1] * frac
            } else if srcIdx < input.count {
                output[i] = input[srcIdx]
            }
        }

        return output
    }

    /// Calculate RMS energy of audio samples.
    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }

    // MARK: - Control

    func stopListening() {
        isStopping = true

        // Transcribe any remaining audio before stopping
        if !audioBuffer.isEmpty && audioBuffer.count >= minAudioSamples {
            let remainingSamples = audioBuffer
            audioBuffer.removeAll()
            Task { [weak self] in
                guard let self, let manager = self.asrManager else { return }
                await self.performTranscription(
                    remainingSamples,
                    manager: manager
                )
            }
        }

        // Stop mic capture and disconnect from stream
        sharedAudio?.endInputCapture()
        bufferContinuation?.finish()
        bufferContinuation = nil
        processingTask?.cancel()
        processingTask = nil

                isListening = false
        audioBuffer.removeAll(keepingCapacity: true)
        vadBuffer.removeAll(keepingCapacity: true)
        vadStreamState = nil
        didSpeechEnd = false
        lastPartialSampleCount = 0

        logger.info("STT listening stopped")
    }

        /// Reset ASR state for next utterance without stopping the mic.
    func resetForNextUtterance() {
        hasFiredSpeechDetected = false
        didSpeechEnd = false
        partialResult = ""
        audioBuffer.removeAll(keepingCapacity: true)
        vadBuffer.removeAll(keepingCapacity: true)
        vadStreamState = VadStreamState.initial()
        lastPartialSampleCount = 0
    }

    /// Simulate a transcript for testing without a real microphone.
    func simulateTranscript(_ text: String) {
        transcript += text + "\n"
        partialResult = ""
        onUtteranceCompleted?(text)
    }

    // MARK: - Private

    static func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let dir = docs.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }
}
