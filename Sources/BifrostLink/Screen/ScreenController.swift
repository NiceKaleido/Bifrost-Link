import AppKit
import CoreMedia
import Combine

enum ScreenRole: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }
    var title: String { self == .top ? "Top Screen" : "Bottom Screen" }
    var shortTitle: String { self == .top ? "Top" : "Bottom" }
}

enum ScreenState: Equatable {
    case idle
    case connecting
    case live
    case failed(String)
}

@MainActor
final class ScreenController: ObservableObject, ScreenInputDelegate {
    let role: ScreenRole
    let displayId: Int
    let view = ScreenView(frame: .zero)
    @Published private(set) var state: ScreenState = .idle
    @Published private(set) var size: CGSize
    @Published var focused = false
    @Published private(set) var hasFrame = false
    let ambientLayer: CALayer = {
        let layer = CALayer()
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.contentsGravity = .resize
        layer.opacity = 0.6
        return layer
    }()
    nonisolated(unsafe) private var frameSeen = false

    nonisolated(unsafe) private(set) var control: ControlChannel?
    nonisolated(unsafe) private var sizeStorage: CGSize
    nonisolated var videoSize: CGSize { sizeStorage }

    private var session: ServerSession?
    private var stream: VideoStream?
    private let frameLock = NSLock()
    nonisolated(unsafe) private var lastFrame: CVPixelBuffer?
    nonisolated(unsafe) private var frameCount = 0
    nonisolated(unsafe) var recorder: ScreenRecorderTrack?
    nonisolated(unsafe) var replay: ReplayBuffer?
    nonisolated let stats = ScreenStats()
    @Published private(set) var statsSnapshot: ScreenStats.Snapshot?
    weak var owner: DeviceManager?
    var onEnded: (() -> Void)?

    init(role: ScreenRole, displayId: Int, size: CGSize) {
        self.role = role
        self.displayId = displayId
        self.size = size
        self.sizeStorage = size
        view.inputDelegate = self
        let stats = self.stats
        view.renderer.onPresented = { arrival in stats.presented(latency: CACurrentMediaTime() - arrival) }
    }

    func refreshStats(codec: String) {
        statsSnapshot = stats.snapshot(size: size, codec: codec)
    }

    func clearStats() {
        statsSnapshot = nil
    }

    func start(serial: String, settings: LinkSettings, primary: Bool, cleanupShell: String? = nil) async throws {
        state = .connecting
        var options: [String: String] = [
            "display_id": "\(displayId)",
            "video_codec": settings.codec.rawValue,
            "video_bit_rate": "\(settings.bitrateMbps * 1_000_000)",
            "max_fps": "\(settings.maxFps)",
            "stay_awake": "true",
            "power_on": "true",
            "clipboard_autosync": primary ? "true" : "false",
            "cleanup": "true",
            "power_off_on_close": "false",
            "hidden_capture": "true",
        ]
        if settings.maxSize > 0 { options["max_size"] = "\(settings.maxSize)" }
        options["video_codec_options"] = ((settings.replayEnabled ? ["i-frame-interval:int=2"] : []) + ["priority:int=0", "latency:int=1"]).joined(separator: ",")
        if primary && settings.chargingSeparation { options["charging_separation"] = "true" }
        if let cleanupShell, let encoded = cleanupShell.data(using: .utf8)?.base64EncodedString() { options["cleanup_shell"] = encoded }
        let session = ServerSession(serial: serial, label: role.rawValue, video: true, audio: false, control: true, options: options)
        self.session = session
        do {
            let sockets = try await session.start()
            guard let videoSocket = sockets.video, let controlSocket = sockets.control else { throw ADBError.failed("Missing sockets") }
            let control = ControlChannel(socket: controlSocket)
            control.onEvent = { [weak self] event in
                Task { @MainActor in self?.owner?.handleDeviceEvent(event, from: self?.role ?? .top) }
            }
            self.control = control
            let stream = VideoStream(socket: videoSocket)
            stream.delegate = self
            self.stream = stream
            stream.start()
            state = .live
        } catch {
            session.stop()
            self.session = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        stream?.delegate = nil
        stream?.stop()
        stream = nil
        control?.close()
        control = nil
        session?.stop()
        session = nil
        view.clear()
        frameLock.lock(); lastFrame = nil; frameSeen = false; frameLock.unlock()
        hasFrame = false
        ambientLayer.contents = nil
        state = .idle
    }

    nonisolated var frameStamp: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return frameCount
    }

    nonisolated func snapshot() -> CVPixelBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return lastFrame
    }

    func screenViewDidBecomeFocused(_ view: ScreenView) {
        owner?.focus(role)
    }

    func screenView(_ view: ScreenView, didReceiveDroppedFiles urls: [URL]) {
        owner?.handleDrop(urls)
    }

    func screenViewPaste(_ view: ScreenView) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        control?.setClipboard(text, paste: true)
    }

    func screenViewCopy(_ view: ScreenView, cut: Bool) {
        control?.getClipboard(copyKey: cut ? 2 : 1)
    }
}

extension ScreenController: VideoStreamDelegate {
    nonisolated func videoStream(_ stream: VideoStream, didChangeSize size: CGSize) {
        sizeStorage = size
        Task { @MainActor in self.size = size }
    }

    nonisolated func videoStream(_ stream: VideoStream, didDecode pixelBuffer: CVPixelBuffer, arrival: CFTimeInterval) {
        frameLock.lock()
        lastFrame = pixelBuffer
        frameCount &+= 1
        let first = !frameSeen
        frameSeen = true
        frameLock.unlock()
        if first { Task { @MainActor in self.hasFrame = true } }
        stats.decoded()
        view.renderer.render(pixelBuffer, arrival: arrival)
    }

    nonisolated func videoStream(_ stream: VideoStream, didReceiveCompressed sample: CMSampleBuffer, keyFrame: Bool) {
        stats.received(bytes: CMSampleBufferGetTotalSampleSize(sample))
        recorder?.append(video: sample, keyFrame: keyFrame)
        replay?.append(video: sample, keyFrame: keyFrame, role: role)
    }

    nonisolated func videoStreamDidEnd(_ stream: VideoStream) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.onEnded?()
        }
    }
}
