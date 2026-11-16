import Foundation

enum ServerConfig {
    static let version = "4.1-bifrost"
    static let remotePath = "/data/local/tmp/bifrost-server.jar"

    static var localJar: URL? {
        if let url = Bundle.main.url(forResource: "bifrost-server", withExtension: "jar") { return url }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/bifrost-server.jar")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}

struct ServerSockets {
    var video: TCPSocket?
    var audio: TCPSocket?
    var control: TCPSocket?
    var deviceName: String
}

final class ServerSession: @unchecked Sendable {
    let serial: String
    let label: String
    private let wantVideo: Bool
    private let wantAudio: Bool
    private let wantControl: Bool
    private var options: [String: String]
    private let scid: UInt32
    private var port: UInt16 = 0
    private var process: Process?
    private var sockets: [TCPSocket] = []
    private let lock = NSLock()
    private var stopped = false
    private(set) var log: [String] = []
    var onExit: (@Sendable () -> Void)?

    init(serial: String, label: String, video: Bool, audio: Bool, control: Bool, options: [String: String]) {
        self.serial = serial
        self.label = label
        self.wantVideo = video
        self.wantAudio = audio
        self.wantControl = control
        self.options = options
        self.scid = UInt32.random(in: 1...0x7FFF_FFFF)
    }

    private var socketName: String { String(format: "scrcpy_%08x", scid) }

    func start() async throws -> ServerSockets {
        guard let port = TCPSocket.freePort() else { throw ADBError.failed("No free local port") }
        self.port = port
        let forward = try await ADB.shared.run(["forward", "tcp:\(port)", "localabstract:\(socketName)"], serial: serial)
        guard forward.ok else { throw ADBError.failed("adb forward failed: \(forward.stderr)") }

        var args = options
        args["scid"] = String(format: "%08x", scid)
        args["tunnel_forward"] = "true"
        args["video"] = wantVideo ? "true" : "false"
        args["audio"] = wantAudio ? "true" : "false"
        args["control"] = wantControl ? "true" : "false"
        args["send_dummy_byte"] = "true"
        args["send_device_meta"] = "true"
        if args["log_level"] == nil { args["log_level"] = "info" }
        let params = args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        var classpath = ServerConfig.remotePath
        if args["cleanup"] == "true" {
            classpath = "/data/local/tmp/bifrost-\(String(format: "%08x", scid)).jar"
            let copy = try await ADB.shared.run(["shell", "cp \(ServerConfig.remotePath) \(classpath)"], serial: serial, timeout: 10)
            guard copy.ok else { throw ADBError.failed("Could not prepare the server on the device: \(copy.stderr)") }
        }
        let command = "CLASSPATH=\(classpath) app_process / com.genymobile.scrcpy.Server \(ServerConfig.version) \(params)"

        let label = self.label
        process = try ADB.shared.startStreaming(["shell", command], serial: serial, onLine: { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.log.append(line)
            if self.log.count > 80 { self.log.removeFirst(self.log.count - 80) }
            self.lock.unlock()
            NSLog("[server:%@] %@", label, line)
        }, onExit: { [weak self] _ in
            self?.onExit?()
        })

        let order: [Bool] = [wantVideo, wantAudio, wantControl]
        var connected: [TCPSocket?] = [nil, nil, nil]
        var firstSocket: TCPSocket?
        for (index, wanted) in order.enumerated() where wanted {
            var socket: TCPSocket?
            let isFirst = firstSocket == nil
            for _ in 0..<120 {
                if isStopped { throw CancellationError() }
                let candidate = await Self.blocking { () -> TCPSocket? in
                    guard let c = TCPSocket.connect(port: port) else { return nil }
                    if isFirst && c.readByte() == nil {
                        c.close()
                        return nil
                    }
                    return c
                }
                if let candidate {
                    socket = candidate
                    break
                }
                if process?.isRunning == false { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let socket else {
                stop()
                throw ADBError.failed("Could not connect to the \(label) stream.\n" + lastLog)
            }
            track(socket)
            if isFirst { firstSocket = socket }
            connected[index] = socket
        }
        guard let firstSocket else { throw ADBError.failed("No stream requested") }
        guard let meta = await Self.blocking({ firstSocket.readExactly(64) }) else {
            stop()
            throw ADBError.failed("Device metadata missing.\n" + lastLog)
        }
        let deviceName = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
        return ServerSockets(video: connected[0], audio: connected[1], control: connected[2], deviceName: deviceName)
    }

    static func blocking<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private func track(_ socket: TCPSocket) {
        lock.lock(); sockets.append(socket); lock.unlock()
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    var lastLog: String {
        lock.lock(); defer { lock.unlock() }
        return log.suffix(6).joined(separator: "\n")
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let socks = sockets
        sockets.removeAll()
        let proc = process
        lock.unlock()
        socks.forEach { $0.close() }
        if let proc, proc.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if proc.isRunning { proc.terminate() }
            }
        }
        let serial = self.serial
        let port = self.port
        if port != 0 {
            Task.detached {
                try? await ADB.shared.run(["forward", "--remove", "tcp:\(port)"], serial: serial, timeout: 5)
            }
        }
    }
}
