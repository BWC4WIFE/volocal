import SwiftUI
import AVFoundation

struct PipelineView: View {
    @EnvironmentObject var metrics: SystemMetrics
    @EnvironmentObject var pipeline: VoicePipeline
    @State private var showSettings = false
    @State private var showPermissionAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Conversation history
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(pipeline.conversationHistory) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            // Show current partial response (visible while LLM generates and TTS speaks)
                            if !pipeline.currentResponse.isEmpty && (pipeline.state == .processing || pipeline.state == .speaking) {
                                MessageBubble(message: ConversationMessage(
                                    role: .assistant,
                                    text: pipeline.currentResponse
                                ))
                            }

                            // Scroll anchor
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: pipeline.conversationHistory.count) {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: pipeline.currentResponse) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                Divider()

                // Status + mic button
                VStack(spacing: 16) {
                    // Status indicator
                    Text(pipeline.state.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Current transcript while listening (uses pipeline.partialTranscript)
                    if pipeline.state == .listening && !pipeline.partialTranscript.isEmpty {
                        Text(pipeline.partialTranscript)
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    // Error display
                    if let error = pipeline.currentError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    // Mic button
                    Button {
                        pipeline.toggleListening()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(buttonColor)
                                .frame(width: 72, height: 72)

                            Image(systemName: buttonIcon)
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: buttonColor.opacity(0.4), radius: pipeline.state == .listening ? 12 : 0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pipeline.state == .listening)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Volocal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pipeline.resetChat()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(pipeline.conversationHistory.isEmpty)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Microphone Access Required", isPresented: $showPermissionAlert) {
                Button("Open Settings", role: .cancel) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Later", role: .destructive) {}
            } message: {
                Text("Volocal needs microphone access to listen to your voice. Please enable it in Settings.")
            }
            .onAppear {
                checkMicrophonePermission()
            }
        }
    }

    private func checkMicrophonePermission() {
        let status = AVAudioApplication.shared.recordPermission
        if status == .undetermined {
            AVAudioApplication.requestRecordPermission { granted in
                if !granted {
                    Task { @MainActor in
                        showPermissionAlert = true
                    }
                }
            }
        } else if status == .denied {
            showPermissionAlert = true
        }
    }

    private var buttonColor: Color {
        switch pipeline.state {
        case .idle: return .blue
        case .listening: return .red
        case .processing: return .orange
        case .speaking: return .green
        }
    }

    private var buttonIcon: String {
        switch pipeline.state {
        case .idle: return "mic.fill"
        case .listening: return "mic.fill"
        case .processing: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Original Thai transcription (user messages only)
                if let original = message.originalText {
                    Text(original)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // English translation / LLM output
                Text(message.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.blue : Color(.systemGray5))
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var modelManager: UnifiedModelManager
    @EnvironmentObject var settings: AppSettings
    @State private var isExporting = false
    @State private var showExportSuccess = false
    @State private var isExportFolderPresented = false
    @State private var preparedExportURL: URL?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Models")) {
                    HStack {
                        Text("LLM (Language Model)")
                        Spacer()
                        Text("~1.26 GB")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("STT (Speech to Text)")
                        Spacer()
                        Text("~1.75 GB")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("TTS (Text to Speech)")
                        Spacer()
                        Text("~600 MB")
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Features")) {
                    Toggle("Text-to-Speech", isOn: $settings.ttsEnabled)
                    
                    Toggle("Multi-Language Input", isOn: $settings.multiLanguageMode)
                } footer: {
                    Text("When Multi-Language is off, only Thai speech is recognized. Enable for auto-detection of any language.\n\nWhen Text-to-Speech is enabled, translations are spoken aloud.")
                }

                Section {
                    Button {
                        isExporting = true
                        Task {
                            if let url = await modelManager.prepareExportBundle() {
                                preparedExportURL = url
                                isExportFolderPresented = true
                            }
                            isExporting = false
                        }
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isExporting ? "Preparing Export..." : "Export Models to Folder")
                        }
                    }
                    .disabled(isExporting)
                } footer: {
                    Text("Export your models to a folder (like 'On My iPhone' or iCloud Drive) so you don't have to re-download them later.")
                }
                
                Section {
                    Button("Export Debug Logs") {
                        Task {
                            do {
                                let logs = try getDebugLogs()
                                // Activity view requires an active window scene
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootVC = windowScene.windows.first?.rootViewController {
                                    let activityVC = UIActivityViewController(activityItems: [logs], applicationActivities: nil)
                                    // Handle iPad popover
                                    if let popover = activityVC.popoverPresentationController {
                                        popover.sourceView = rootVC.view
                                        popover.sourceRect = CGRect(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY, width: 0, height: 0)
                                        popover.permittedArrowDirections = []
                                    }
                                    rootVC.present(activityVC, animated: true)
                                }
                            } catch {
                                logToFile("Failed to read logs: \(error)")
                            }
                        }
                    }
                }
                
                if let error = modelManager.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isExportFolderPresented) {
                if let url = preparedExportURL {
                    ExportDocumentPicker(urls: [url])
                        .ignoresSafeArea()
                }
            }
        }
    }
}

struct ExportDocumentPicker: UIViewControllerRepresentable {
    let urls: [URL]
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
