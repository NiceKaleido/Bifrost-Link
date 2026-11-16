import Foundation
import AVFoundation

enum AudioChannel: String, CaseIterable, Identifiable {
    case top
    case bottom
    case background

    var id: String { rawValue }
}

final class AudioOutput: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    let engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioOutput.sampleRate, channels: 2, interleaved: false)!
    private var players: [AudioChannel: AVAudioPlayerNode] = [:]
    private var mixers: [AudioChannel: AVAudioMixerNode] = [:]
    private var queued: [AudioChannel: Int] = [:]
    private let lock = NSLock()
    private var tapConsumers: [String: (AVAudioPCMBuffer, AVAudioTime) -> Void] = [:]
    private var started = false
    var maxLatencyFrames = Int(AudioOutput.sampleRate * 0.16)

    init() {
        for channel in AudioChannel.allCases {
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(mixer)
            engine.connect(player, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
            players[channel] = player
            mixers[channel] = mixer
            queued[channel] = 0
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterConfigChange()
        }
    }

    func start() {
        lock.lock()
        let alreadyStarted = started
        lock.unlock()
        guard !alreadyStarted else { return }
        do {
            try engine.start()
            players.values.forEach { $0.play() }
            lock.lock(); started = true; lock.unlock()
        } catch {
            NSLog("Audio engine failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        lock.lock()
        started = false
        for key in queued.keys { queued[key] = 0 }
        lock.unlock()
        players.values.forEach { $0.stop() }
        engine.stop()
    }

    private func restartAfterConfigChange() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        if wasStarted { start() }
    }

    func setVolume(_ volume: Float, for channel: AudioChannel) {
        mixers[channel]?.outputVolume = volume
    }

    func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    func flush(_ channel: AudioChannel) {
        guard let player = players[channel] else { return }
        player.stop()
        lock.lock()
        queued[channel] = 0
        let running = started
        lock.unlock()
        if running { player.play() }
    }

    func enqueue(pcm16 data: Data, channel: AudioChannel) {
        lock.lock()
        let running = started
        lock.unlock()
        guard running, let player = players[channel] else { return }
        let frames = data.count / 4
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }

        lock.lock()
        let pending = queued[channel] ?? 0
        if pending > maxLatencyFrames {
            lock.unlock()
            return
        }
        let cushion = pending == 0 ? Int(AudioOutput.sampleRate * 0.04) : 0
        queued[channel] = pending + frames + cushion
        lock.unlock()

        if cushion > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(cushion)) {
            silence.frameLength = AVAudioFrameCount(cushion)
            if let channels = silence.floatChannelData {
                for c in 0..<Int(format.channelCount) { channels[c].update(repeating: 0, count: cushion) }
            }
            player.scheduleBuffer(silence) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.queued[channel] = max(0, (self.queued[channel] ?? 0) - cushion)
                self.lock.unlock()
            }
        }

        buffer.frameLength = AVAudioFrameCount(frames)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                left[i] = Float(Int16(littleEndian: samples[i * 2])) / 32768
                right[i] = Float(Int16(littleEndian: samples[i * 2 + 1])) / 32768
            }
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queued[channel] = max(0, (self.queued[channel] ?? 0) - frames)
            self.lock.unlock()
        }
    }

    func queuedFrames(_ channel: AudioChannel) -> Int {
        lock.lock(); defer { lock.unlock() }
        return queued[channel] ?? 0
    }

    func addTapConsumer(_ key: String, _ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        lock.lock()
        let install = tapConsumers.isEmpty
        tapConsumers[key] = handler
        lock.unlock()
        guard install else { return }
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { [weak self] buffer, time in
            guard let self else { return }
            self.lock.lock()
            let consumers = Array(self.tapConsumers.values)
            self.lock.unlock()
            consumers.forEach { $0(buffer, time) }
        }
    }

    func removeTapConsumer(_ key: String) {
        lock.lock()
        let had = tapConsumers.removeValue(forKey: key) != nil
        let empty = tapConsumers.isEmpty
        lock.unlock()
        if had && empty {
            engine.mainMixerNode.removeTap(onBus: 0)
        }
    }

    var tapFormat: AVAudioFormat { engine.mainMixerNode.outputFormat(forBus: 0) }
}

final class AudioStream: @unchecked Sendable {
    private let socket: TCPSocket
    let channel: AudioChannel
    private weak var output: AudioOutput?
    var onEnd: (@Sendable () -> Void)?

    init(socket: TCPSocket, channel: AudioChannel, output: AudioOutput) {
        self.socket = socket
        self.channel = channel
        self.output = output
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.qualityOfService = .userInteractive
        thread.name = "bifrost.audio.\(channel.rawValue)"
        thread.start()
    }

    func stop() {
        socket.close()
    }

    static let debug = ProcessInfo.processInfo.environment["BIFROST_DEBUG"] != nil
    private var meterBytes = 0
    private var meterPeak: Int16 = 0
    private var meterStart = Date()

    private func meter(_ data: Data) {
        meterBytes += data.count
        data.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) where abs(Int(v)) > Int(meterPeak) { meterPeak = Int16(clamping: abs(Int(v))) }
        }
        if Date().timeIntervalSince(meterStart) > 1 {
            NSLog("[audio:%@] %d bytes/s peak %d queued %d running %d", channel.rawValue, meterBytes, meterPeak, output?.queuedFrames(channel) ?? -1, output?.engine.isRunning == true ? 1 : 0)
            meterBytes = 0
            meterPeak = 0
            meterStart = Date()
        }
    }

    private func run() {
        defer { onEnd?() }
        guard let codec = socket.readExactly(4) else { return }
        let id = codec.readUInt32BE(at: 0)
        guard id == 0x0072_6177 else {
            NSLog("Audio stream %@ disabled (code %08x)", channel.rawValue, id)
            return
        }
        while true {
            guard let header = socket.readExactly(12) else { return }
            let first = header.readUInt64BE(at: 0)
            if first & (1 << 63) != 0 { continue }
            let length = Int(header.readUInt32BE(at: 8))
            guard let payload = socket.readExactly(length) else { return }
            if first & (1 << 62) != 0 { continue }
            if Self.debug { meter(payload) }
            output?.enqueue(pcm16: payload, channel: channel)
        }
    }
}
