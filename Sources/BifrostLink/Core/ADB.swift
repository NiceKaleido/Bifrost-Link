import Foundation

struct ADBResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum ADBError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "adb was not found. Install it with `brew install android-platform-tools`."
        case .failed(let message): return message
        }
    }
}

final class ADB: @unchecked Sendable {
    static let shared = ADB()

    let path: String?

    private init() {
        let candidates = [
            ProcessInfo.processInfo.environment["BIFROST_ADB"],
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            Bundle.main.url(forResource: "adb", withExtension: nil)?.path,
        ].compactMap { $0 }
        path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func makeProcess(_ args: [String], serial: String?) throws -> Process {
        guard let path else { throw ADBError.notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var full: [String] = []
        if let serial { full += ["-s", serial] }
        process.arguments = full + args
        return process
    }

    @discardableResult
    func run(_ args: [String], serial: String? = nil, timeout: TimeInterval = 30, onStart: ((Process) -> Void)? = nil) async throws -> ADBResult {
        let process = try makeProcess(args, serial: serial)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let collector = OutputCollector()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.appendOut(data) }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.appendErr(data) }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ADBResult(status: proc.terminationStatus, stdout: collector.outString, stderr: collector.errString))
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                continuation.resume(throwing: error)
                return
            }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
        }
    }

    func data(_ command: String, serial: String?, timeout: TimeInterval = 30) async -> Data? {
        guard let process = try? makeProcess(["exec-out", command], serial: serial) else { return nil }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            let collector = OutputCollector()
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collector.appendOut(chunk) }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: proc.terminationStatus == 0 ? collector.outData : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    func shell(_ command: String, serial: String?, timeout: TimeInterval = 30) async throws -> String {
        let result = try await run(["shell", command], serial: serial, timeout: timeout)
        return result.stdout
    }

    func startStreaming(_ args: [String], serial: String?, onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        let process = try makeProcess(args, serial: serial)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        let buffer = LineBuffer(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.feed(data)
            }
        }
        process.terminationHandler = { proc in
            onExit(proc.terminationStatus)
        }
        try process.run()
        return process
    }

    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }
    var outString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var outData: Data { lock.lock(); defer { lock.unlock() }; return out }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let range = pending.firstRange(of: Data([0x0A])) {
            let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}
