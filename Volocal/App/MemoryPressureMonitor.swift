// Volocal/App/MemoryPressureMonitor.swift
// Watches system memory and drives pipeline memory-tier decisions.
//
// Strategy:
//   1. Poll os_proc_available_memory() every 10 s (background task)
//   2. Subscribe to UIApplication.didReceiveMemoryWarningNotification
//   3. Publish reactive state — VoicePipeline observes and acts.
//
// Actions triggered by pressure:
//   .normal    → no action
//   .elevated  → suggest pipeline switch to lite LLM on next load
//   .critical  → request immediate LLM unload if not mid-generation

import Foundation
import UIKit
import os.proc

// MARK: - Memory Tier

public enum MemoryPressureLevel: String {
    case normal    = "normal"     // > 1500 MB available
    case elevated  = "elevated"   // 800–1500 MB — prefer lite LLM
    case critical  = "critical"   // < 800 MB — unload LLM, warn user
}

// MARK: - MemoryPressureMonitor

@MainActor
public final class MemoryPressureMonitor: ObservableObject {

    // MARK: Published State

    @Published public private(set) var pressureLevel: MemoryPressureLevel = .normal
    @Published public private(set) var availableMemoryMB: Int = 2000
    @Published public private(set) var recommendedLLMTier: LLMMemoryTier = .standard

    // MARK: Callbacks

    /// Called when the monitor recommends an LLM tier change.
    public var onTierChange: ((LLMMemoryTier) -> Void)?

    /// Called when system memory is critically low — pipeline should
    /// immediately unload whichever model is not mid-inference.
    public var onCriticalPressure: (() -> Void)?

    // MARK: Private

    private var pollingTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    // Thresholds in MB
    private let criticalThreshold  = 800
    private let elevatedThreshold  = 1500

    // MARK: Lifecycle

    public init() {}

    deinit {
        pollingTask?.cancel()
        if let obs = memoryWarningObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: Start / Stop

    public func start() {
        subscribeToMemoryWarnings()
        startPolling()
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        if let obs = memoryWarningObserver {
            NotificationCenter.default.removeObserver(obs)
            memoryWarningObserver = nil
        }
    }

    // MARK: Private — Memory Warning

    private func subscribeToMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCriticalPressure()
            }
        }
    }

    // MARK: Private — Polling

    private func startPolling() {
        pollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                let availableMB = Self.queryAvailableMemoryMB()
                await MainActor.run { [weak self] in
                    self?.update(availableMB: availableMB)
                }
            }
        }
    }

    // MARK: Private — State Update

    private func update(availableMB: Int) {
        availableMemoryMB = availableMB

        let newLevel: MemoryPressureLevel
        let newTier: LLMMemoryTier

        switch availableMB {
        case ..<criticalThreshold:
            newLevel = .critical
            newTier  = .lite
        case criticalThreshold..<elevatedThreshold:
            newLevel = .elevated
            newTier  = .lite
        default:
            newLevel = .normal
            newTier  = .standard
        }

        if newLevel != pressureLevel {
            pressureLevel = newLevel
        }

        if newTier != recommendedLLMTier {
            recommendedLLMTier = newTier
            onTierChange?(newTier)
        }

        if newLevel == .critical {
            handleCriticalPressure()
        }
    }

    private func handleCriticalPressure() {
        pressureLevel = .critical
        recommendedLLMTier = .lite
        onCriticalPressure?()
    }

    // MARK: Private — Query

    /// Returns available memory in MB using the private `os_proc_available_memory` SPI.
    /// Falls back to a heuristic on simulators (ANE not available anyway).
    private static func queryAvailableMemoryMB() -> Int {
        #if targetEnvironment(simulator)
        return 2000
        #else
        let bytes = os_proc_available_memory()
        return Int(bytes / 1_048_576)
        #endif
    }
}
