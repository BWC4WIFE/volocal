import Foundation
import os

private let fileLoggerURL: URL = {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents.appendingPathComponent("volocal-debug.log")
}()

public func logToFile(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(timestamp)] \(message)\n"
    do {
        let data = entry.data(using: .utf8)!
        if FileManager.default.fileExists(atPath: fileLoggerURL.path) {
            let fileHandle = try FileHandle(forWritingTo: fileLoggerURL)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        } else {
            try data.write(to: fileLoggerURL)
        }
    } catch {
        print("File logging failed: \(error)")
    }
}

public func getDebugLogs() throws -> String {
    try String(contentsOf: fileLoggerURL)
}
