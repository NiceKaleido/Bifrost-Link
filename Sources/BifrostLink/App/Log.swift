import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "bifrost.log")
    private static let maxBytes = 1_000_000

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bifrost Link")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bifrost.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("%@", message)
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }

    static func installCrashHandlers() {
        signal(SIGPIPE, SIG_IGN)
        NSSetUncaughtExceptionHandler { exception in
            let text = "uncaught exception: \(exception.name.rawValue) \(exception.reason ?? "")\n\(exception.callStackSymbols.joined(separator: "\n"))"
            let line = "\(Date()) \(text)\n"
            if let handle = try? FileHandle(forWritingTo: Log.url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }
}
