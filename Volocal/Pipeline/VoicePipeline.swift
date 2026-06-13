import Foundation
import AVFoundation
import Speech
import Combine

/// Orchestrates the full voice pipeline: STT -> LLM -> TTS
/// Listens for completed utterances from STT, generates LLM responses,
/// buffers into sentences, and sends to TTS for playback.
/// Supports barge-in: user can speak while AI is talking to interrupt.
@MainActor
final class VoicePipeline: ObservableObject {
    @Published var state: PipelineState = .idle
    @Published var conversationHistory: [ConversationMessage] = []
    @Published var currentTranscript: String = ""
    @Published var currentResponse: String = ""
    @Published var loadingStatus: String?
    @Published var isReady: Bool = false
    @Published var partialTranscript: String = ""
    @Published var currentError: String?

    let sttManager = STTManager()
    let llmManager = LLMManager()
    let ttsManager = TTSManager()
    let sharedAudio = SharedAudioEngine()
    private let sentenceBuffer = SentenceBuffer()
    private var settings: AppSettings?

    private var generationTask: Task<Void, Never>?
    private var sentenceQueue: [String] = []
    private var speakingTask: Task<Void, Never>?
    private var turnRevision: Int = 0
    private var cancellables = Set<AnyCancellable>()

    /// Maximum conversation history entries (system prompt excluded).
    /// Each exchange is 2 entries (user + assistant). Keep last ~4 exchanges.
    private let maxHistoryEntries = 8

    enum PipelineState: Equatable {
        case idle
        case listening
        case processing
        case speaking

        var label: String {
            switch self {
            case .idle: return "Tap to start"
            case .listening: return "Listening..."
            case .processing: return "Thinking..."
            case .speaking: return "Speaking..."
            }
        }
    }

    init() {
        setupCallbacks()
        // Forward partial transcript from STT manager
        sttManager.$partialResult
            .receive(on: DispatchQueue.main)
            .assign(to: &$partialTranscript)
    }

    var metrics: SystemMetrics?

    func configure(llmModelPath: String?, settings: AppSettings) async {
        self.settings = settings
        logToFile("VoicePipeline.configure() started")
        AppLogger.shared.info(.pipeline, "configure() started")
        let configStart = CFAbsoluteTimeGetCurrent()
        
        // Explicitly request permission before starting the pipeline
        if AVAudioApplication.shared.recordPermission == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            AppLogger.shared.info(.pipeline, "Microphone permission: \(granted ? "granted" : "denied")")
            logToFile("Microphone permission: \(granted ? "granted" : "denied")")
            if !granted {
                self.currentError = "Microphone access denied. Please enable in Settings > Privacy & Security > Microphone."
                return
            }
        } else if AVAudioApplication.shared.recordPermission == .denied {
            logToFile("Microphone permission: denied")
            self.currentError = "Microphone access denied. Please enable in Settings > Privacy & Security > Microphone."
            return
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            AppLogger.shared.info(.pipeline, "Speech recognition permission: \(status.rawValue)")
            logToFile("Speech recognition permission: \(status.rawValue)")
            if status != .authorized {
                self.currentError = "Speech recognition access denied. Enable in Settings > Privacy & Security > Speech Recognition."
            }
        } else if SFSpeechRecognizer.authorizationStatus() != .authorized {
            logToFile("Speech recognition permission: not authorized (\(SFSpeechRecognizer.authorizationStatus().rawValue))")
        }

        // Start shared audio engine
        sharedAudio.start()

        // Inject shared audio into managers
        sttManager.sharedAudio = sharedAudio
        ttsManager.sharedAudio = sharedAudio
        
        sttManager.language = settings.multiLanguageMode ? nil : "th"
        sttManager.multiLanguageMode = settings.multiLanguageMode
        llmManager.multiLanguageMode = settings.multiLanguageMode

        loadingStatus = "Loading speech recognition..."
        metrics?.beginTracking("STT (Qwen3-ASR)")
        await sttManager.initialize()
        metrics?.endTracking("STT (Qwen3-ASR)")

        loadingStatus = "Loading language model..."
        if let path = llmModelPath {
            metrics?.beginTracking("LLM (llama.cpp)")
            do {
                try await llmManager.loadModel(path: path)
            } catch {
                AppLogger.shared.error(.pipeline, "LLM load failed: \(error.localizedDescription)")
                currentError = "LLM failed to load: \(error.localizedDescription)"
                loadingStatus = nil
                // Don't set isReady — stay on loading screen with error
                return
            }
            metrics?.endTracking("LLM (llama.cpp)")
        }

        if settings.ttsEnabled {
            loadingStatus = "Loading text-to-speech..."
            ttsManager.metrics = metrics
            await ttsManager.initialize()
        } else {
            AppLogger.shared.info(.pipeline, "TTS disabled by user — skipping init")
        }

        loadingStatus = nil
        isReady = true
        let configElapsed = CFAbsoluteTimeGetCurrent() - configStart
        AppLogger.shared.info(.pipeline, "configure() complete in \(String(format: "%.1f", configElapsed))s — all models loaded")
    }

    func toggleListening() {
        AppLogger.shared.debug(.pipeline, "toggleListening() — current state: \(state.label)")
        switch state {
        case .idle:
            startListening()
        case .listening:
            stopListening()
        case .processing, .speaking:
            interrupt()
        }
    }

    func resetChat() {
        AppLogger.shared.info(.pipeline, "Chat reset")
        if state == .processing || state == .speaking {
            interrupt()
        }
        if state == .listening {
            stopListening()
        }
        conversationHistory.removeAll()
        currentTranscript = ""
        currentResponse = ""
        currentError = nil
    }

    // MARK: - Pipeline Control

    private func startListening() {
        if AVAudioApplication.shared.recordPermission == .denied {
            currentError = "Microphone access denied. Please enable in Settings."
            AppLogger.shared.warning(.pipeline, "Start listening blocked — mic permission denied")
            return
        }
        
        AppLogger.shared.info(.pipeline, "State → listening")
        state = .listening
        currentTranscript = ""
        currentError = nil
        sttManager.startListening()
    }

    private func stopListening() {
        AppLogger.shared.info(.pipeline, "State → idle (stop listening)")
        sttManager.stopListening()
        state = .idle
    }

    private func interrupt() {
        AppLogger.shared.info(.pipeline, "Barge-in interrupt — cancelling generation/playback")
        turnRevision += 1
        if settings?.ttsEnabled == true {
            ttsManager.stop()
        }
        llmManager.stopGeneration()
        generationTask?.cancel()
        generationTask = nil
        speakingTask?.cancel()
        speakingTask = nil
        sentenceQueue.removeAll()
        sentenceBuffer.reset()
        currentResponse = ""
        // Don't stop STT — mic stays open for barge-in
        state = .listening
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        sttManager.onUtteranceCompleted = { [weak self] text in
            Task { @MainActor in
                self?.handleUtterance(text)
            }
        }

        sttManager.onSpeechDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Barge-in: user started speaking while AI is active
                if self.state == .processing || self.state == .speaking {
                    self.interrupt()
                }
            }
        }

        sentenceBuffer.onSentenceReady = { [weak self] sentence in
            Task { @MainActor in
                self?.handleSentence(sentence)
            }
        }
    }

    private func handleUtterance(_ text: String) {
        // If AI is still active, interrupt first
        if state == .processing || state == .speaking {
            interrupt()
        }
        guard state == .listening else { return }

        turnRevision += 1
        let myRevision = turnRevision

        let userMessage = ConversationMessage(role: .user, text: text, originalText: text)
        conversationHistory.append(userMessage)
        currentTranscript = text

        AppLogger.shared.info(.pipeline, "State → processing")
        AppLogger.shared.logInput(.pipeline, text: text)

        // Forward partial transcript
        partialTranscript = sttManager.partialResult

        // Reset ASR for next utterance (mic stays open)
        sttManager.resetForNextUtterance()

        state = .processing
        currentResponse = ""
        sentenceBuffer.reset()
        sentenceQueue.removeAll()

        generationTask = Task {
            // History already includes the user message we just appended.
            // generate() should NOT re-append the prompt.
            for await token in llmManager.generate(history: conversationHistory) {
                guard !Task.isCancelled, myRevision == turnRevision else { break }
                currentResponse += token
                sentenceBuffer.append(token)
            }

            guard !Task.isCancelled, myRevision == turnRevision else { return }

            sentenceBuffer.flush()

            // Only append non-empty assistant messages
            if !currentResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let assistantMessage = ConversationMessage(role: .assistant, text: currentResponse)
                conversationHistory.append(assistantMessage)
                AppLogger.shared.logOutput(.pipeline, text: currentResponse)
                trimHistory()
            }
            // Clear so the partial response bubble disappears
            // (the response is now in conversationHistory)
            currentResponse = ""

            // Wait for all queued sentences to finish speaking (with timeout)
            if self.settings?.ttsEnabled == true {
                let waitStart = CFAbsoluteTimeGetCurrent()
                let waitTimeout: TimeInterval = 60
                while self.speakingTask != nil && !Task.isCancelled && myRevision == self.turnRevision {
                    if CFAbsoluteTimeGetCurrent() - waitStart > waitTimeout {
                        AppLogger.shared.warning(.pipeline, "Speaking wait timeout after \(waitTimeout)s")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            guard !Task.isCancelled, myRevision == turnRevision else { return }
            AppLogger.shared.info(.pipeline, "State → listening (turn complete)")
            state = .listening
        }
    }

    private func handleSentence(_ sentence: String) {
        guard settings?.ttsEnabled == true else { return }
        sentenceQueue.append(sentence)
        processNextSentence()
    }

    private func processNextSentence() {
        guard speakingTask == nil, !sentenceQueue.isEmpty else { return }
        guard !Task.isCancelled else { return }

        let sentence = sentenceQueue.removeFirst()
        let myRevision = turnRevision
        AppLogger.shared.info(.pipeline, "State → speaking")
        state = .speaking
        speakingTask = Task {
            await ttsManager.speak(sentence)
            guard !Task.isCancelled, myRevision == turnRevision else { return }
            speakingTask = nil
            processNextSentence()
        }
    }

    /// Trim conversation history to prevent context overflow.
    /// Keeps the most recent exchanges within maxHistoryEntries.
    private func trimHistory() {
        let beforeCount = conversationHistory.count
        while conversationHistory.count > maxHistoryEntries {
            conversationHistory.removeFirst()
            // Remove in pairs if possible to keep user/assistant aligned
            if !conversationHistory.isEmpty && conversationHistory.first?.role == .assistant {
                conversationHistory.removeFirst()
            }
        }
        let trimmed = beforeCount - conversationHistory.count
        if trimmed > 0 {
            AppLogger.shared.debug(.pipeline, "History trimmed: removed \(trimmed) entries, \(conversationHistory.count) remaining")
        }
    }
}

// MARK: - Global Debug Logging (Legacy Wrappers)

/// Legacy wrapper — forwards to AppLogger.
public func logToFile(_ message: String) {
    AppLogger.shared.info(.app, message)
}

/// Legacy wrapper — reads from AppLogger's log file.
public func getDebugLogs() throws -> String {
    try AppLogger.shared.getLogs()
}
