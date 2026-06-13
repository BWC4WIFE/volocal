import SwiftUI

@main
struct VolocalApp: App {
    @StateObject private var modelManager = UnifiedModelManager()
    @StateObject private var metrics = SystemMetrics()
    @StateObject private var pipeline = VoicePipeline()
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLogger.shared.startSession()
    }

    var body: some Scene {
        WindowGroup {
            if !modelManager.allModelsReady {
                OnboardingView()
                    .environmentObject(modelManager)
            } else if !pipeline.isReady {
                ModelLoadingView()
                    .environmentObject(pipeline)
                    .task {
                        pipeline.metrics = metrics
                        metrics.startMonitoring()
                        await pipeline.configure(
                            llmModelPath: modelManager.llmModelPath,
                            settings: settings
                        )
                    }
            } else {
                ContentView()
                    .environmentObject(modelManager)
                    .environmentObject(metrics)
                    .environmentObject(pipeline)
                    .environmentObject(settings)
                    .overlay { MetricsOverlay().environmentObject(metrics) }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                AppLogger.shared.info(.app, "Scene phase → active")
                metrics.startMonitoring()
            case .inactive:
                AppLogger.shared.info(.app, "Scene phase → inactive")
                metrics.stopMonitoring()
            case .background:
                AppLogger.shared.info(.app, "Scene phase → background")
                metrics.stopMonitoring()
                AppLogger.shared.endSession(reason: "background")
            @unknown default:
                AppLogger.shared.warning(.app, "Scene phase → unknown")
                break
            }
        }
    }
}
