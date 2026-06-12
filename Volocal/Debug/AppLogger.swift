import Foundation
import os
import UIKit

// MARK: - AppLogger

/// Centralized logging for Volocal — covers all app activity from init to exit.
/// Writes to both Apple's unified logging (Console.app) and a persistent file
/// at Documents/volocal-session.log. Auto-rotates at 5 MB.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    // MARK: - Types

    enum Level: String {
        case info    = "INFO"
        case debug   = "DEBUG"
        case warning = "WARN"
        case error   = "ERROR"
    }

    enum Category: String {
        case app      = "APP"
        case pipeline  = "PIPELINE"
        case stt       = "STT"
        case llm       = "LLM"
        case tts       = "TTS"
        case audio     = "AUDIO"
        case models    = "MODELS"
    }

    // MARK: - Private State

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.volocal.applogger", qos: .utility)
    private let maxFileSize: UInt64 = 5 * 1024 * 1024  // 5 MB
    private let osLoggers: [Category: Logger]

    private var sessionStartDate: Date?

    // MARK: - Init

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("volocal-session.log")

        // Create os.Logger for each category
        var loggers: [Category: Logger] = [:]
        for cat in [Category.app, .pipeline, .stt, .llm, .tts, .audio, .models] {
            loggers[cat] = Logger(subsystem: "com.volocal.app", category: cat.rawValue.lowercased())
        }
        osLoggers = loggers
    }

    // MARK: - Session Lifecycle

    /// Call at app launch to log session header with device/version info.
    func startSession() {
        sessionStartDate = Date()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        let deviceName = UIDevice.current.name

        let header = """
        ════════════════════════════════════════════════════════════
        VOLOCAL SESSION START
        Version: \(version) (\(build))
        Device: \(device) — \(deviceName)
        iOS: \(systemVersion)
        Time: \(ISO8601DateFormatter().string(from: Date()))
        ════════════════════════════════════════════════════════════
        """
        writeRaw(header)
        info(.app, "Session started — v\(version) build \(build), \(device) iOS \(systemVersion)")
    }

    /// Call when app goes to background or terminates.
    func endSession(reason: String = "background") {
        let duration: String
        if let start = sessionStartDate {
            let elapsed = Date().timeIntervalSince(start)
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            duration = "\(mins)m \(secs)s"
        } else {
            duration = "unknown"
        }

        info(.app, "Session ending — reason: \(reason), duration: \(duration)")
        writeRaw("════════════════════════════════════════════════════════════")
        writeRaw("VOLOCAL SESSION END — \(reason) — duration: \(duration)")
        writeRaw("════════════════════════════════════════════════════════════\n")
    }

    // MARK: - Logging Methods

    func info(_ category: Category, _ message: String) {
        log(level: .info, category: category, message: message)
    }

    func debug(_ category: Category, _ message: String) {
        log(level: .debug, category: category, message: message)
    }

    func warning(_ category: Category, _ message: String) {
        log(level: .warning, category: category, message: message)
    }

    func error(_ category: Category, _ message: String) {
        log(level: .error, category: category, message: message)
    }

    // MARK: - I/O Logging

    /// Log user input (STT transcript).
    func logInput(_ category: Category, text: String) {
        log(level: .info, category: category, message: "INPUT ▶ \"\(text)\"")
    }

    /// Log system output (LLM response, TTS text).
    func logOutput(_ category: Category, text: String) {
        log(level: .info, category: category, message: "OUTPUT ◀ \"\(text)\"")
    }

    // MARK: - Core

    private func log(level: Level, category: Category, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(level.rawValue)] [\(category.rawValue)] \(message)"

        // Write to os.Logger (unified logging / Console.app)
        let osLogger = osLoggers[category] ?? Logger(subsystem: "com.volocal.app", category: "general")
        switch level {
        case .info:    osLogger.info("\(message, privacy: .public)")
        case .debug:   osLogger.debug("\(message, privacy: .public)")
        case .warning: osLogger.warning("\(message, privacy: .public)")
        case .error:   osLogger.error("\(message, privacy: .public)")
        }

        // Write to file
        writeToFile(entry)
    }

    // MARK: - File I/O

    private func writeRaw(_ text: String) {
        writeToFile(text)
    }

    private func writeToFile(_ entry: String) {
        queue.async { [self] in
            let line = entry + "\n"
            guard let data = line.data(using: .utf8) else { return }

            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                // Check for rotation
                rotateIfNeeded()

                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Rotate log file when it exceeds maxFileSize.
    /// Keeps the most recent half of the file.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxFileSize else { return }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        // Keep the second half (most recent logs)
        let midpoint = content.index(content.startIndex, offsetBy: content.count / 2)
        // Find the first newline after midpoint to avoid splitting a log entry
        let keepFrom = content[midpoint...].firstIndex(of: "\n") ?? midpoint
        let truncated = "[LOG ROTATED — older entries trimmed]\n" + String(content[keepFrom...])

        try? truncated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Log Retrieval

    /// Get all log content for export.
    func getLogs() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Get the log file URL for direct access.
    var logFileURL: URL { fileURL }
}
