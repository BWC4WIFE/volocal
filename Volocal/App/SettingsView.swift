import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var modelManager: UnifiedModelManager
    @State private var isExporting = false
    @State private var showExportSuccess = false
    @State private var isExportFolderPresented = false
    
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
                
                Section {
                    Button {
                        isExportFolderPresented = true
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isExporting ? "Exporting Models..." : "Export Models to Folder")
                        }
                    }
                    .disabled(isExporting)
                } footer: {
                    Text("Export your models to a folder (like 'On My iPhone' or iCloud Drive) so you don't have to re-download them later.")
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
            .fileImporter(
                isPresented: $isExportFolderPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let folderURL = urls.first {
                        exportTo(folderURL: folderURL)
                    }
                case .failure(let error):
                    modelManager.error = "File selection failed: \(error.localizedDescription)"
                }
            }
            .alert("Export Successful", isPresented: $showExportSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Models have been successfully exported to the selected folder.")
            }
        }
    }
    
    private func exportTo(folderURL: URL) {
        isExporting = true
        modelManager.error = nil // Clear previous errors
        Task {
            await modelManager.exportModels(to: folderURL)
            isExporting = false
            if modelManager.error == nil {
                showExportSuccess = true
            }
        }
    }
}
