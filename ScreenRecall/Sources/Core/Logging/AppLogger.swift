import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = "com.anson.ScreenRecall"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let tier1 = Logger(subsystem: subsystem, category: "tier1")
    static let tier2 = Logger(subsystem: subsystem, category: "tier2")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let provider = Logger(subsystem: subsystem, category: "provider")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    static func bootstrap() {
        let dir = AppPaths.logsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        app.info("logger bootstrap, logsDir=\(dir.path, privacy: .public)")
        DebugFile.write("--- launch \(Date()) ---")
    }
}

enum DebugFile {
    static let url: URL = AppPaths.logsDir.appendingPathComponent("debug.log")
    static let queue = DispatchQueue(label: "com.anson.ScreenRecall.debug")

    static func write(_ msg: String) {
        queue.async {
            let line = "[\(Date())] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}

enum AppPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ScreenRecall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
    static var dbURL: URL { supportDir.appendingPathComponent("recall.db") }
    static var framesDir: URL { supportDir.appendingPathComponent("frames", isDirectory: true) }
    static var reportsDir: URL { supportDir.appendingPathComponent("reports", isDirectory: true) }
    static var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }
}
