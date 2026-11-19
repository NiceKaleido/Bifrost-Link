import AppKit
import AVFoundation
import Combine
import CoreImage
import UniformTypeIdentifiers

enum LinkState: Equatable {
    case noADB
    case searching
    case unauthorized(String)
    case linking(String)
    case linked
    case failed(String)
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let message: String
    var url: URL?
    var editable = false
}

struct DisplayInfo {
    let id: Int
    let size: CGSize
}

@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var state: LinkState = .searching
    @Published private(set) var serial: String?
    @Published private(set) var deviceName = "AYN Thor"
    @Published private(set) var model = ""
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var screens: [ScreenController] = []
    @Published private(set) var focusedRole: ScreenRole = .top
    @Published private(set) var lidClosed = false
    @Published private(set) var panelsOn = true
    @Published private(set) var mirroringPaused = false
    private var panelsBeforePause: Bool?
    @Published private(set) var recording = false
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var gamepads: [String] = []
    @Published private(set) var screenApps: [AudioChannel: [String]] = [:]
    @Published var toast: Toast?
    var lastCapture: URL?
    @Published var flash = false

    let settings = LinkSettings.shared
    let files = FileService()
    let emulation = EmulationHub()
    let backups = SaveBackupService()
    let cleanup = CleanupService()
    let cocoon = CocoonBridge()
    let stats = PlayStats()
    let monitor = DeviceMonitor()
    let apps = AppManager()
    let updater = EmulatorUpdater()
    let ports = PortCatalog()
    private var homeProfile: LayoutProfile?
    let audio = AudioOutput()
    private var router: AudioRouter?
    private var power: PowerGuard?
    let gamepad = GamepadBridge()
    private var pollTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var ambientTask: Task<Void, Never>?
    private var lastAmbientStamps: [Int] = []
    private let ambientContext = CIContext(options: [.cacheIntermediates: false])
    let ambientWash: CALayer = {
        let layer = CALayer()
        layer.magnificationFilter = .linear
        layer.contentsGravity = .resize
        layer.opacity = 0.38
        return layer
    }()
    private var linkTask: Task<Void, Never>?
    private var recorders: [ScreenRecorderTrack] = []
    private var layoutRecorder: LayoutRecorder?
    private var replayBuffer: ReplayBuffer?
    private var statsTask: Task<Void, Never>?
    @Published private(set) var audioLatencyMs: Double?
    private var cancellables: Set<AnyCancellable> = []
    private var manualUnlink = false
    private var forceConnect = false
    private var unlinkTask: Task<Void, Never>?

    private init() {
        emulation.files = files
        cleanup.backups = backups
        let toastHandler: (String, String) -> Void = { [weak self] symbol, message in self?.showToast(symbol, message) }
        emulation.toast = toastHandler
        ports.toast = toastHandler
        ports.backups = backups
        ports.romFolders = { [weak self] in self?.emulation.folders.mapValues(\.path) ?? [:] }
        stats.bridge = cocoon
        monitor.foreground = { [weak self] in
            guard let serial = self?.serial,
                  let listing = try? await ADB.shared.shell("cmd activity stack list", serial: serial, timeout: 5) else { return nil }
            let visible = AudioRouter.visiblePackages(listing)
            let ordered = (visible[0] ?? []) + visible.keys.sorted().filter { $0 != 0 }.flatMap { visible[$0] ?? [] }
            return ordered.first { !CocoonBridge.homePackages.contains($0) } ?? ordered.first
        }
        monitor.names = { [weak self] name in
            guard let self, name.contains("."), !name.contains("/") else { return nil }
            let package = String(name.split(separator: ":").first ?? Substring(name))
            // An emulator running a known game: name the game.
            if let playing = self.cocoon.nowPlaying, playing.package == package, !playing.file.isEmpty {
                let game = self.stats.customNames["game:" + playing.file] ?? playing.title
                return "\(game) (\(EmulatorUpdater.knownNames[package] ?? playing.player))"
            }
            return self.stats.displayName(package: package) ?? self.apps.names?(package) ?? EmulatorUpdater.knownNames[package] ?? EmulatorUpdater.prettyName(package)
        }
        stats.names = { [weak self] package in self?.apps.names?(package) }
        stats.isGame = { [weak self] package in
            guard let self else { return true }
            let kind = self.apps.kinds?(package)
            return kind != "Emulator" && kind != "Launcher"
        }
        apps.toast = toastHandler
        apps.names = { [weak self] package in
            guard let self else { return nil }
            if package == CocoonBridge.package { return "Cocoon" }
            return self.ports.ports.first { $0.forks.contains { $0.package == package } }?.name
        }
        apps.kinds = { [weak self] package in
            guard let self else { return nil }
            if CocoonBridge.homePackages.contains(package) { return "Launcher" }
            if Emulators.all.contains(where: { $0.package == package }) || EmulatorHotkeys.names[package] != nil { return "Emulator" }
            if self.ports.packages.contains(package) { return "Port" }
            return nil
        }
        gamepad.onShortcut = { [weak self] action in
            Task { @MainActor in self?.handleShortcut(action) }
        }
        cocoon.onSessionEnded = { [weak self] playing, ended in self?.stats.record(playing, ended: ended) }
        backups.toast = toastHandler
        cleanup.toast = toastHandler
        updater.toast = toastHandler
        backups.loadSnapshots()
        cocoon.$nowPlaying.removeDuplicates { $0?.file == $1?.file && $0?.package == $1?.package }.dropFirst().sink { [weak self] playing in
            DispatchQueue.main.async { self?.nowPlayingChanged(playing) }
        }.store(in: &cancellables)
        gamepad.onChange = { [weak self] names in
            Task { @MainActor in self?.gamepads = names }
        }
        files.onPushed = { [weak self] remote in
            self?.screen(.top)?.control?.scanFile(remote)
        }
        settings.$masterVolume.combineLatest(settings.$muted).sink { [weak self] volume, muted in
            self?.audio.setMasterVolume(muted ? 0 : Float(volume))
        }.store(in: &cancellables)
        settings.$topVolume.sink { [weak self] v in self?.audio.setVolume(Float(v), for: .top) }.store(in: &cancellables)
        settings.$bottomVolume.sink { [weak self] v in self?.audio.setVolume(Float(v), for: .bottom) }.store(in: &cancellables)
        settings.$perScreenAudio.combineLatest(settings.$playOnDevice).dropFirst().sink { [weak self] per, dup in
            self?.router?.reconfigure(perScreen: per, playOnDevice: dup)
            DispatchQueue.main.async { self?.applyThorVolume() }
        }.store(in: &cancellables)
        settings.$macKeyboardTyping.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyThorKeyboard() }
        }.store(in: &cancellables)
        settings.$gamepadEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            if enabled, let control = self.screen(.top)?.control { self.gamepad.attach(control) } else { self.gamepad.detach() }
            self.syncKeyboardPad()
        }.store(in: &cancellables)
        settings.$cinemaMode.sink { [weak self] on in
            self?.updateAmbient(on)
        }.store(in: &cancellables)
        settings.$smoothMotion.sink { [weak self] on in
            self?.screens.forEach { $0.view.renderer.smoothing = on }
        }.store(in: &cancellables)
        settings.$upscaling.sink { [weak self] on in
            self?.screens.forEach { $0.view.renderer.upscaling = on }
        }.store(in: &cancellables)
        settings.$statsOverlay.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatsLoop() }
        }.store(in: &cancellables)
        settings.$replayEnabled.combineLatest(settings.$replaySeconds).dropFirst().sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateReplay() }
        }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self, let recorder = self.layoutRecorder else { return }
                recorder.update(spec: self.layoutSpec)
            }
        }.store(in: &cancellables)
        settings.$controllerIdentity.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.gamepad.identity = GamepadBridge.Identity(rawValue: value) ?? .odin
            if self.state == .linked, self.settings.gamepadEnabled, let control = self.screen(.top)?.control {
                self.gamepad.attach(control)
                self.syncKeyboardPad()
            }
        }.store(in: &cancellables)
        settings.$rumbleEnabled.sink { [weak self] on in
            self?.gamepad.rumbleEnabled = on
        }.store(in: &cancellables)
        settings.$hoverEnabled.sink { [weak self] on in
            self?.screens.forEach { $0.view.hoverEnabled = on }
        }.store(in: &cancellables)
    }

    func boot() {
        guard pollTask == nil else { return }
        if ADB.shared.path == nil {
            state = .noADB
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func screen(_ role: ScreenRole) -> ScreenController? {
        screens.first { $0.role == role }
    }

    var focusedScreen: ScreenController? {
        screen(focusedRole) ?? screens.first
    }

    private func poll() async {
        guard let result = try? await ADB.shared.run(["devices", "-l"], timeout: 10) else { return }
        let lines = result.stdout.split(separator: "\n").dropFirst().map(String.init).filter { !$0.isEmpty }
        let devices = lines.compactMap { line -> (String, String, String)? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? ""
            return (parts[0], parts[1], model)
        }
        let preferred = devices.first { $0.2.lowercased().contains("thor") || $0.2.lowercased().contains("ayn") } ?? devices.first

        switch state {
        case .linked, .linking:
            if let serial, !devices.contains(where: { $0.0 == serial && $0.1 == "device" }) {
                await unlink(reason: "Device disconnected")
            }
        case .failed:
            if preferred == nil { state = .searching }
        case .searching, .unauthorized:
            guard let preferred else {
                state = .searching
                manualUnlink = false
                return
            }
            if preferred.1 == "unauthorized" {
                state = .unauthorized(preferred.0)
            } else if preferred.1 == "device" {
                state = .searching
                if (settings.autoConnect || forceConnect) && !manualUnlink {
                    forceConnect = false
                    link(serial: preferred.0, model: preferred.2)
                }
            }
        case .noADB:
            break
        }
    }

    func retry() {
        manualUnlink = false
        forceConnect = true
        state = .searching
        Task { await poll() }
    }

    func connectNow() {
        manualUnlink = false
        forceConnect = true
        if case .failed = state { state = .searching }
        Task { await poll() }
    }

    func link(serial: String, model: String) {
        guard linkTask == nil else { return }
        self.serial = serial
        self.model = model.replacingOccurrences(of: "_", with: " ")
        deviceName = self.model.isEmpty ? "Android" : self.model
        DeviceInfo.update(model: deviceName)
        state = .linking(deviceName)
        linkTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performLink(serial: serial)
                // Unlinked (or unplugged) while linking: performUnlink already tore down and
                // moved on, so don't resurrect a "linked" state with no screens behind it.
                guard !Task.isCancelled else {
                    Log.write("link cancelled")
                    // Clean up anything started after the unlink's teardown, unless a new link
                    // is already under way (its teardown would kill that one).
                    if self.linkTask == nil && self.state == .searching { await self.teardown() }
                    return
                }
                self.state = .linked
                Log.write("linked \(serial)")
            } catch {
                guard !Task.isCancelled else {
                    Log.write("link cancelled")
                    return
                }
                Log.write("link failed: \(error.localizedDescription)")
                await self.teardown()
                self.state = .failed(error.localizedDescription)
            }
            self.linkTask = nil
        }
    }

    private func performLink(serial: String) async throws {
        guard let jar = ServerConfig.localJar else { throw ADBError.failed("bifrost-server.jar is missing from the app bundle.") }
        let push = try await ADB.shared.run(["push", jar.path, ServerConfig.remotePath], serial: serial, timeout: 30)
        guard push.ok else { throw ADBError.failed("Could not upload the Bifrost server: \(push.stderr)") }

        let displays = try await listDisplays(serial: serial)
        guard let main = displays.first(where: { $0.id == 0 }) ?? displays.first else { throw ADBError.failed("No displays found on the device") }
        let secondary = displays.first { $0.id != main.id }

        var cleanupParts = [Self.volumeRestoreShell, Self.keyboardRestoreShell]
        if settings.pauseSleepManager, let part = await pauseSleepManager(serial: serial) {
            cleanupParts.append(part)
        }
        await clearStickyBatterySaver(serial: serial)
        let cleanupShell: String? = cleanupParts.joined(separator: "; ")

        var list = [ScreenController(role: .top, displayId: main.id, size: main.size)]
        if let secondary { list.append(ScreenController(role: .bottom, displayId: secondary.id, size: secondary.size)) }
        for s in list {
            s.owner = self
            s.view.hoverEnabled = settings.hoverEnabled
            s.view.renderer.upscaling = settings.upscaling
            s.view.renderer.smoothing = settings.smoothMotion
            s.onEnded = { [weak self, weak s] in
                guard let self, let s, self.screens.contains(where: { $0 === s }) else { return }
                Task { await self.unlink(reason: "\(s.role.title) stream ended") }
                Log.write("stream ended: \(s.role.rawValue)")
            }
        }
        screens = list

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, s) in list.enumerated() {
                group.addTask { @MainActor in
                    try await s.start(serial: serial, settings: self.settings, primary: index == 0, cleanupShell: index == 0 ? cleanupShell : nil)
                }
            }
            try await group.waitForAll()
        }

        if settings.gamepadEnabled, let control = screen(.top)?.control {
            gamepad.attach(control)
        }
        applyControllerProfile()

        let guardian = PowerGuard(serial: serial)
        guardian.setPanels = { [weak self] on in
            self?.screen(.top)?.control?.setDisplayPower(on)
            self?.panelsOn = on
        }
        guardian.onLidChange = { [weak self] closed in self?.lidClosed = closed }
        power = guardian
        await guardian.start()

        startAudio()
        files.reset(serial: serial)
        emulation.reset(serial: serial)
        backups.reset(serial: serial)
        cleanup.reset(serial: serial)
        updater.reset(serial: serial)
        ports.reset(serial: serial)
        apps.reset(serial: serial)
        updater.excludedPackages = ports.packages
        Task { [weak self] in
            guard let self else { return }
            await self.emulation.refreshFolders()
            self.cocoon.start(serial: serial, cocoonRoot: self.emulation.cocoonRoot)
            self.monitor.start(serial: serial)
            self.stats.serial = serial
            self.stats.cocoonRoot = self.emulation.cocoonRoot
            await self.backups.autoBackupIfDue()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard self.state == .linked, self.serial == serial else { return }
            if self.emulation.lastScan == nil && !self.emulation.scanning { await self.emulation.scan() }
            guard self.state == .linked, self.serial == serial else { return }
            if self.cleanup.usage.isEmpty && !self.cleanup.scanning { await self.cleanup.scan() }
            guard self.state == .linked, self.serial == serial else { return }
            await self.stats.refreshCocoon()
            guard self.state == .linked, self.serial == serial, self.settings.checkPortUpdates else { return }
            await self.ports.refresh()
            self.updater.excludedPackages = self.ports.packages
            await self.ports.detectInstalled()
            let count = self.ports.updates.count
            if count > 0 { self.showToast("arrow.down.app", count == 1 ? "An update for \(self.ports.updates[0].port.name) is ready in Ports" : "\(count) port updates are ready in Ports") }
        }
        startBatteryPolling(serial: serial)
        updateAmbient(settings.cinemaMode)
        showToast("link", "Linked to \(deviceName)")
        DispatchQueue.main.async {
            self.updateReplay()
            self.updateStatsLoop()
            self.applyThorVolume()
            self.applyThorKeyboard()
        }
    }

    private func updateAmbient(_ on: Bool) {
        ambientTask?.cancel()
        ambientTask = nil
        guard on else {
            screens.forEach { $0.ambientLayer.contents = nil }
            ambientWash.contents = nil
            return
        }
        ambientTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let targets = self.screens.map { ($0, $0.ambientLayer) }
                let context = self.ambientContext
                let stamps = targets.map { $0.0.frameStamp }
                if stamps == self.lastAmbientStamps {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                self.lastAmbientStamps = stamps
                let images = await Task.detached(priority: .utility) { () -> [CGImage?] in
                    targets.map { screen, _ in Self.ambientImage(screen.snapshot(), context: context) }
                }.value
                guard !Task.isCancelled, self.settings.cinemaMode else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.35)
                var washImage: CGImage?
                let washRole: ScreenRole = self.settings.layout == .bottomOnly || (self.settings.swapped && self.settings.layout == .overlay) ? .bottom : .top
                for ((screen, layer), image) in zip(targets, images) {
                    guard let image else { continue }
                    let fade = CABasicAnimation(keyPath: "contents")
                    fade.duration = 0.35
                    layer.add(fade, forKey: "contents")
                    layer.contents = image
                    if screen.role == washRole || washImage == nil { washImage = image }
                }
                if let washImage {
                    let fade = CABasicAnimation(keyPath: "contents")
                    fade.duration = 0.35
                    self.ambientWash.add(fade, forKey: "contents")
                    self.ambientWash.contents = washImage
                }
                CATransaction.commit()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    nonisolated private static func ambientImage(_ buffer: CVPixelBuffer?, context: CIContext) -> CGImage? {
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let probeWidth = 64
        let probeScale = CGFloat(probeWidth) / image.extent.width
        let probe = image.transformed(by: CGAffineTransform(scaleX: probeScale, y: probeScale))
        let probeHeight = max(1, Int(probe.extent.height.rounded()))
        var pixels = [UInt8](repeating: 0, count: probeWidth * probeHeight * 4)
        context.render(probe, toBitmap: &pixels, rowBytes: probeWidth * 4,
                       bounds: CGRect(x: probe.extent.minX, y: probe.extent.minY, width: CGFloat(probeWidth), height: CGFloat(probeHeight)),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var minX = probeWidth, maxX = -1, minY = probeHeight, maxY = -1
        for y in 0..<probeHeight {
            for x in 0..<probeWidth {
                let i = (y * probeWidth + x) * 4
                if max(pixels[i], pixels[i + 1], pixels[i + 2]) > 28 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY, (maxX - minX + 1) * (maxY - minY + 1) >= 12 else { return nil }
        let unit = 1 / probeScale
        let content = CGRect(x: image.extent.minX + CGFloat(minX) * unit,
                             y: image.extent.minY + CGFloat(probeHeight - 1 - maxY) * unit,
                             width: CGFloat(maxX - minX + 1) * unit,
                             height: CGFloat(maxY - minY + 1) * unit).intersection(image.extent)
        let cropped = image.cropped(to: content).transformed(by: CGAffineTransform(translationX: -content.minX, y: -content.minY))
        let target = CGSize(width: 24, height: max(1, (24 * image.extent.height / image.extent.width).rounded()))
        let small = cropped.transformed(by: CGAffineTransform(scaleX: target.width / content.width, y: target.height / content.height))
        let extent = CGRect(origin: .zero, size: target)
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 2.2)
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputBrightnessKey: -0.08])
        return context.createCGImage(blurred, from: extent)
    }

    private func startAudio() {
        guard let serial, let top = screen(.top) else { return }
        router?.stop()
        audio.setMasterVolume(settings.muted ? 0 : Float(settings.masterVolume))
        audio.setVolume(Float(settings.topVolume), for: .top)
        audio.setVolume(Float(settings.bottomVolume), for: .bottom)
        let r = AudioRouter(serial: serial, output: audio, topDisplay: top.displayId, bottomDisplay: screen(.bottom)?.displayId,
                            perScreen: settings.perScreenAudio, playOnDevice: settings.playOnDevice)
        r.onAppsChanged = { [weak self] apps in self?.screenApps = apps }
        r.onListing = { [weak self] listing in self?.cocoon.feed(listing) }
        router = r
        r.start()
    }

    private func listDisplays(serial: String) async throws -> [DisplayInfo] {
        let command = "CLASSPATH=\(ServerConfig.remotePath) app_process / com.genymobile.scrcpy.Server \(ServerConfig.version) list_displays=true video=false audio=false control=false cleanup=false"
        let out = try await ADB.shared.run(["shell", command], serial: serial, timeout: 20)
        let text = out.stdout + out.stderr
        var result: [DisplayInfo] = []
        let regex = try NSRegularExpression(pattern: #"--display-id=(\d+)\s+\((\d+)x(\d+)\)"#)
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let id = Int(ns.substring(with: m.range(at: 1))), let w = Int(ns.substring(with: m.range(at: 2))), let h = Int(ns.substring(with: m.range(at: 3))) {
                result.append(DisplayInfo(id: id, size: CGSize(width: w, height: h)))
            }
        }
        if result.isEmpty { result = [DisplayInfo(id: 0, size: CGSize(width: 1920, height: 1080))] }
        return result
    }

    private func startBatteryPolling(serial: String) {
        batteryTask?.cancel()
        let layoutTask = Task { [weak self] in
            var last: Bool?
            while !Task.isCancelled {
                if let out = try? await ADB.shared.shell("settings get system flip_button_layout", serial: serial, timeout: 5) {
                    let nintendo = out.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
                    if nintendo != last {
                        last = nintendo
                        self?.gamepad.nintendoLayout = nintendo
                        Log.write("thor controller style: \(nintendo ? "nintendo" : "xbox")")
                    }
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        batteryTask = Task { [weak self] in
            defer { layoutTask.cancel() }
            while !Task.isCancelled {
                if let out = try? await ADB.shared.shell("dumpsys battery", serial: serial, timeout: 5) {
                    var level: Int?
                    var powered = false
                    for line in out.split(separator: "\n") {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("level:") { level = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
                        if (t.hasPrefix("AC powered: true") || t.hasPrefix("USB powered: true") || t.hasPrefix("Wireless powered: true")) { powered = true }
                    }
                    self?.battery = level
                    self?.charging = powered
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func disconnect() {
        manualUnlink = true
        Task { await unlink(reason: nil) }
    }

    func unlink(reason: String?) async {
        if let unlinkTask {
            await unlinkTask.value
            return
        }
        guard state == .linked || linkTask != nil || !screens.isEmpty else { return }
        let task = Task { @MainActor in
            await self.performUnlink(reason: reason)
        }
        unlinkTask = task
        await task.value
        unlinkTask = nil
    }

    private func performUnlink(reason: String?) async {
        Log.write("unlink: \(reason ?? "requested")")
        linkTask?.cancel()
        linkTask = nil
        if recording { await stopRecording() }
        let present = await deviceStillPresent()
        Log.write("unlink: device \(present ? "present" : "gone")")
        await teardown(devicePresent: present)
        state = .searching
        if let reason { showToast("cable.connector.slash", present ? reason : "\(DeviceInfo.name) disconnected") }
    }

    private func deviceStillPresent() async -> Bool {
        guard let serial else { return false }
        guard let result = try? await ADB.shared.run(["get-state"], serial: serial, timeout: 2) else { return false }
        return result.ok && result.stdout.contains("device")
    }

    private func teardown(devicePresent: Bool = true) async {
        batteryTask?.cancel()
        batteryTask = nil
        ambientTask?.cancel()
        ambientTask = nil
        statsTask?.cancel()
        statsTask = nil
        audio.removeTapConsumer("replay")
        replayBuffer?.clear()
        replayBuffer = nil
        padReleasePointer()
        keyboardPad = false
        gamepad.detach(sendDestroy: devicePresent)
        router?.stop()
        router = nil
        mirroringPaused = false
        panelsBeforePause = nil
        if devicePresent {
            if let power {
                await power.releaseDevice()
            }
        } else {
            power?.stop()
        }
        power = nil
        screens.forEach { $0.stop() }
        screens = []
        if devicePresent, let serial {
            _ = try? await ADB.shared.run(["shell", "sleep 1; rm -f /data/local/tmp/bifrost-*.jar"], serial: serial, timeout: 10)
        }
        files.reset(serial: nil)
        cocoon.stop()
        monitor.stop()
        stats.serial = nil
        emulation.reset(serial: nil)
        backups.reset(serial: nil)
        cleanup.reset(serial: nil)
        updater.reset(serial: nil)
        ports.reset(serial: nil)
        apps.reset(serial: nil)
        restoreHomeProfile()
        battery = nil
        screenApps = [:]
        lidClosed = false
        panelsOn = true
        Log.write("teardown complete")
    }

    private static let volumeMarker = "/data/local/tmp/bifrost-volume"
    private static let volumeRestoreShell = "[ -f \(volumeMarker) ] && cmd media_session volume --stream 3 --set $(cat \(volumeMarker)) >/dev/null 2>&1; rm -f \(volumeMarker)"

    static let cocoonKeyboard = "rip.moth.cocoonshell/.ui.keyboard.CocoonInputMethodService"
    private static let keyboardMarker = "/data/local/tmp/bifrost-ime"
    private static let keyboardRestoreShell = "[ -f \(keyboardMarker) ] && { ime enable $(cat \(keyboardMarker)); ime set $(cat \(keyboardMarker)); } >/dev/null 2>&1; rm -f \(keyboardMarker)"
    private static let keyboardReleaseShell = "k=$(settings get secure default_input_method); [ \"$k\" = \"\(cocoonKeyboard)\" ] && { echo \"$k\" > \(keyboardMarker); ime disable \"$k\" >/dev/null 2>&1; }; true"

    func applyThorKeyboard() {
        guard let serial, state == .linked else { return }
        let release = settings.macKeyboardTyping
        Task {
            _ = try? await ADB.shared.shell(release ? Self.keyboardReleaseShell : Self.keyboardRestoreShell, serial: serial, timeout: 10)
            Log.write(release ? "cocoon keyboard released for mac typing" : "thor keyboard restored")
        }
    }

    private struct RadioState: Codable {
        var wifi: Bool
        var bluetooth: Bool

        var shell: String {
            "svc wifi \(wifi ? "enable" : "disable"); cmd bluetooth_manager \(bluetooth ? "enable" : "disable") >/dev/null 2>&1"
        }
    }

    // v2: v1 could record Sleep Manager's "asleep" radios (wifi off) when linking with the lid open but the screen off.
    private static let radioKey = "sleepManagerAwakeRadios.v2"

    private func pauseSleepManager(serial: String) async -> String? {
        let installed = (try? await ADB.shared.shell("pm list packages com.med.sleepmanager", serial: serial)) ?? ""
        guard installed.contains("com.med.sleepmanager") else { return nil }
        let probe = (try? await ADB.shared.shell("echo $(settings get global wifi_on) $(settings get global bluetooth_on) $(getevent -pl 2>/dev/null | grep -c 'SW_LID\\*') $(dumpsys power | grep -c 'mWakefulness=Awake')", serial: serial, timeout: 10)) ?? ""
        let values = probe.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var awake = (UserDefaults.standard.data(forKey: Self.radioKey)).flatMap { try? JSONDecoder().decode(RadioState.self, from: $0) }
        if values.count == 4 {
            let current = RadioState(wifi: values[0] == "1" || values[0] == "2", bluetooth: values[1] == "1" || values[1] == "2")
            // Only trust the live radios as the "awake" state when Sleep Manager isn't holding them down:
            // lid open AND the device actually awake. Otherwise it may have switched them off for sleep.
            let trulyAwake = values[2] == "0" && values[3] != "0"
            if trulyAwake {
                awake = current
                UserDefaults.standard.set(try? JSONEncoder().encode(current), forKey: Self.radioKey)
            }
            if awake == nil { awake = trulyAwake ? current : RadioState(wifi: true, bluetooth: current.bluetooth) }
        }
        _ = try? await ADB.shared.shell("am force-stop com.med.sleepmanager", serial: serial)
        let radios = awake ?? RadioState(wifi: true, bluetooth: false)
        _ = try? await ADB.shared.shell(radios.shell, serial: serial, timeout: 10)
        Log.write("sleep manager paused, radios wifi=\(radios.wifi) bt=\(radios.bluetooth)")
        return radios.shell + "; cmd deviceidle tempwhitelist -d 15000 com.med.sleepmanager >/dev/null 2>&1; am broadcast -n com.med.sleepmanager/.service.BootReceiver >/dev/null 2>&1"
    }

    /// Sleep Manager turns Battery Saver on for sleep with `cmd power set-mode 1`, which Android
    /// treats as a manual switch and marks "sticky". Plugging in pauses Battery Saver but keeps the
    /// sticky flag, and Sleep Manager can drop its ownership without clearing it, so Android switched
    /// Battery Saver back on every time the cable came out. Linking means the Thor is in use and
    /// charging, so a sticky flag left over at this point is cleared.
    private func clearStickyBatterySaver(serial: String) async {
        let state = (try? await ADB.shared.shell("echo $(settings get global low_power) $(settings get global low_power_sticky) $(pm list packages com.med.sleepmanager | grep -c sleepmanager)", serial: serial, timeout: 10)) ?? ""
        let values = state.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Only with Sleep Manager installed: without it a sticky flag is the user's own choice.
        guard values.count == 3, values[1] == "1", values[2] != "0" else { return }
        _ = try? await ADB.shared.shell("settings put global low_power_sticky 0", serial: serial, timeout: 10)
        Log.write("battery saver: cleared sticky flag left from sleep (low_power=\(values[0]))")
    }

    func shutdown() async {
        pollTask?.cancel()
        await unlink(reason: nil)
    }

    func focus(_ role: ScreenRole) {
        focusedRole = role
        for s in screens { s.focused = s.role == role }
    }

    func handleDeviceEvent(_ event: DeviceEvent, from role: ScreenRole) {
        switch event {
        case .clipboard(let text):
            let pb = NSPasteboard.general
            if pb.string(forType: .string) != text {
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        case .ackClipboard:
            break
        case .uhidOutput(let id, let data):
            gamepad.handleOutput(id: id, data: data)
        }
    }

    func handleDrop(_ urls: [URL]) {
        guard let serial else { return }
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        let roms = urls.filter { Systems.isRom($0.lastPathComponent) }
        if !roms.isEmpty { emulation.prepareImport(roms) }
        let others = urls.filter { $0.pathExtension.lowercased() != "apk" && !Systems.isRom($0.lastPathComponent) }
        for apk in apks {
            showToast("app.badge", "Installing \(apk.lastPathComponent)…")
            Task {
                let r = try? await ADB.shared.run(["install", "-r", apk.path], serial: serial, timeout: 300)
                showToast(r?.ok == true ? "checkmark.circle" : "exclamationmark.triangle",
                          r?.ok == true ? "Installed \(apk.lastPathComponent)" : "Install failed: \(r?.stdout.split(separator: "\n").last ?? "")")
            }
        }
        if !others.isEmpty {
            files.upload(others, to: "/sdcard/Download")
            showToast("arrow.up.doc", others.count == 1 ? "Sending \(others[0].lastPathComponent) to Download" : "Sending \(others.count) files to Download")
        }
    }

    func press(_ keycode: Int32) {
        focusedScreen?.control?.pressKey(keycode)
    }

    func toggleMirroring() {
        guard state == .linked else { return }
        let pause = !mirroringPaused
        mirroringPaused = pause
        for screen in screens {
            if pause { screen.control?.pauseVideo() } else { screen.control?.resumeVideo() }
        }
        if pause {
            router?.stop()
            router = nil
            panelsBeforePause = power?.panelsOn
            power?.applyPanels(true)
            applyThorVolume()
            Log.write("mirroring paused")
            showToast("pause.circle", "Mirroring paused, the \(DeviceInfo.name)’s screens are back on")
        } else {
            startAudio()
            applyThorVolume()
            if panelsBeforePause == false { power?.applyPanels(false) }
            panelsBeforePause = nil
            Log.write("mirroring resumed")
            showToast("play.circle", "Mirroring resumed")
        }
    }

    func applyThorVolume() {
        guard let serial, state == .linked else { return }
        let full = !mirroringPaused && !settings.playOnDevice
        Task {
            if full {
                _ = try? await ADB.shared.shell("[ -f \(Self.volumeMarker) ] || cmd media_session volume --stream 3 --get 2>/dev/null | sed -n 's/.*volume is \\([0-9]*\\).*/\\1/p' > \(Self.volumeMarker); max=$(cmd media_session volume --stream 3 --get 2>/dev/null | sed -n 's/.*\\.\\.\\([0-9]*\\)\\].*/\\1/p'); cmd media_session volume --stream 3 --set ${max:-15} >/dev/null 2>&1", serial: serial, timeout: 10)
            } else {
                _ = try? await ADB.shared.shell(Self.volumeRestoreShell, serial: serial, timeout: 10)
            }
            Log.write(full ? "thor media volume at full while linked" : "thor media volume restored")
        }
    }

    func handleShortcut(_ action: ShortcutAction) {
        guard state == .linked else { return }
        switch action {
        case .quickSave: quickState(.save)
        case .quickLoad: quickState(.load)
        case .saveReplay:
            if settings.replayEnabled { saveReplay() } else { showToast("clock.arrow.circlepath", "Instant replay is off. Turn it on in the More menu first") }
        case .screenshot: screenshot()
        case .closeApp: closeForegroundApp()
        case .record: toggleRecording()
        }
    }

    func quickState(_ action: StateAction) {
        guard let serial, state == .linked else { return }
        Task {
            guard let listing = try? await ADB.shared.shell("cmd activity stack list", serial: serial, timeout: 5) else { return }
            let visible = AudioRouter.visiblePackages(listing)
            var target: (display: Int, package: String)?
            for display in visible.keys.sorted() {
                if let package = visible[display]?.first(where: { !CocoonBridge.homePackages.contains($0) }) {
                    target = (display, package)
                    break
                }
            }
            guard let target else {
                showToast("gamecontroller", "No game is running")
                return
            }
            let name = EmulatorHotkeys.names[target.package] ?? EmulatorUpdater.knownNames[target.package] ?? EmulatorUpdater.prettyName(target.package)
            guard let binding = await EmulatorHotkeys.binding(for: target.package, action: action, serial: serial) else {
                showToast("exclamationmark.triangle", EmulatorHotkeys.unsupported[target.package] ?? "\(name) has no \(action.title)-state shortcut Bifrost can use")
                return
            }
            switch binding {
            case .keys(let hold, let press):
                if let control = screen(.top)?.control { gamepad.bind(control) }
                guard await gamepad.typeOnKeyboard(keycode: press.keycode, meta: press.meta, hold: hold?.keycode) else {
                    showToast("exclamationmark.triangle", "\(name)’s \(action.title)-state key can’t be pressed from here")
                    return
                }
            case .pad(let inputs):
                if let control = screen(.top)?.control { gamepad.bind(control) }
                guard await gamepad.pulse(inputs) else { return }
            }
            Log.write("quick \(action.title) in \(target.package) via \(binding)")
            showToast(action == .save ? "square.and.arrow.down" : "arrow.uturn.backward", action == .save ? "Saved state in \(name)" : "Loaded state in \(name)")
        }
    }

    func closeForegroundApp() {
        guard let serial, state == .linked else { return }
        let target = focusedScreen ?? screen(.top)
        let displayId = target?.displayId ?? 0
        Task {
            guard let listing = try? await ADB.shared.shell("cmd activity stack list", serial: serial, timeout: 5) else { return }
            let visible = AudioRouter.visiblePackages(listing)
            let candidates = (visible[displayId] ?? []) + (visible[0] ?? [])
            guard let package = candidates.first(where: { !CocoonBridge.homePackages.contains($0) }) else {
                showToast("house", "Nothing to close, you’re on the home screen")
                return
            }
            _ = try? await ADB.shared.shell("am force-stop \(ADB.quote(package))", serial: serial, timeout: 10)
            let name = EmulatorUpdater.knownNames[package] ?? EmulatorUpdater.prettyName(package)
            Log.write("closed \(package)")
            showToast("xmark.app", "Closed \(name)")
        }
    }

    func toggleMute() {
        settings.muted.toggle()
        showToast(settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", settings.muted ? "Muted" : "Sound on")
    }

    func togglePanels() {
        guard let power else { return }
        power.applyPanels(!panelsOn)
    }

    func rotate() {
        focusedScreen?.control?.rotate()
    }

    func expandNotifications() {
        screen(.top)?.control?.expandNotifications()
    }

    func showToast(_ symbol: String, _ message: String, url: URL? = nil, editable: Bool = false) {
        let t = Toast(symbol: symbol, message: message, url: url, editable: editable)
        if editable, let url { lastCapture = url }
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if toast?.id == t.id { toast = nil }
        }
    }

    private func captureFolder(_ base: String) -> URL {
        var url = URL(fileURLWithPath: base)
        if let playing = cocoon.nowPlaying { url.appendPathComponent(playing.safeName) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var capturePrefix: String {
        cocoon.nowPlaying?.safeName ?? "Bifrost"
    }

    private func nowPlayingChanged(_ playing: NowPlaying?) {
        applyControllerProfile()
        if let playing {
            if let profile = LayoutProfiles.get(LayoutProfiles.gameKey(playing)) ?? (playing.isApp ? nil : LayoutProfiles.get(LayoutProfiles.systemKey(playing.system))) {
                if homeProfile == nil { homeProfile = LayoutProfile(settings: settings) }
                profile.apply(to: settings)
                showToast("rectangle.3.group", "Using your layout for \(playing.title)")
            } else {
                // No saved layout: go back to your own settings and leave them alone, so changes made now stick.
                restoreHomeProfile()
                if !playing.isApp { showToast("gamecontroller", "Now playing \(playing.title)") }
            }
        } else {
            restoreHomeProfile()
        }
    }

    /// Puts back the settings that were in place before a game's saved layout took over.
    /// Must also run on unlink, or the game's layout (cinema mode included) stays saved as your own.
    private func restoreHomeProfile() {
        guard let home = homeProfile else { return }
        homeProfile = nil
        home.apply(to: settings)
    }

    enum ProfileScope { case game, system }

    @Published private(set) var keyboardPad = false
    @Published private(set) var controllerScope = ControllerProfiles.everyone
    private(set) var pointerCaptured = false
    private var resignObserver: NSObjectProtocol?

    func applyControllerProfile() {
        let resolved = ControllerProfiles.resolve(cocoon.nowPlaying)
        gamepad.profile = resolved.profile
        controllerScope = resolved.scope
    }

    func toggleKeyboardPad() {
        guard state == .linked else { return }
        keyboardPad.toggle()
        syncKeyboardPad()
        if keyboardPad {
            let mouse = gamepad.profile.mouse != .off
            showToast("keyboard", mouse ? "Keyboard plays as controller. Click the screen to use the mouse as \(gamepad.profile.mouse == .rightStick ? "camera" : "stick"), Esc releases it · ⌃⌘K to type again" : "Keyboard plays as controller · ⌃⌘K to type again")
        } else {
            padReleasePointer()
            showToast("keyboard", "Keyboard types again")
        }
    }

    func syncKeyboardPad() {
        guard keyboardPad, let control = screen(.top)?.control else {
            keyboardPad = false
            gamepad.setKeyboardPad(false)
            return
        }
        gamepad.bind(control)
        gamepad.setKeyboardPad(true)
        ScreenView.padRouter = self
    }

    func rememberLayout(_ scope: ProfileScope) {
        guard let playing = cocoon.nowPlaying else { return }
        let key = scope == .game ? LayoutProfiles.gameKey(playing) : LayoutProfiles.systemKey(playing.system)
        LayoutProfiles.set(LayoutProfile(settings: settings), for: key)
        showToast("checkmark.circle", scope == .game ? "Layout remembered for \(playing.title)" : "Layout remembered for all \(Systems.name(for: playing.system)) games")
        objectWillChange.send()
    }

    func forgetLayout(_ scope: ProfileScope) {
        guard let playing = cocoon.nowPlaying else { return }
        LayoutProfiles.set(nil, for: scope == .game ? LayoutProfiles.gameKey(playing) : LayoutProfiles.systemKey(playing.system))
        showToast("arrow.uturn.backward", "Forgot the saved layout")
        objectWillChange.send()
    }

    func hasProfile(_ scope: ProfileScope) -> Bool {
        guard let playing = cocoon.nowPlaying else { return false }
        return LayoutProfiles.get(scope == .game ? LayoutProfiles.gameKey(playing) : LayoutProfiles.systemKey(playing.system)) != nil
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    private var visibleScreens: [ScreenController] {
        screens.filter { settings.layout.shows($0.role) }
    }

    func screenshot() {
        let targets = visibleScreens
        guard !targets.isEmpty else { return }
        let folder = captureFolder(settings.screenshotFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = timestamp()
        let context = CIContext()
        var saved: [URL] = []
        for s in targets {
            guard let buffer = s.snapshot() else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            let suffix = targets.count > 1 ? " \(s.role.shortTitle)" : ""
            let url = folder.appendingPathComponent("\(capturePrefix) \(stamp)\(suffix).png")
            if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
                do {
                    try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: cs)
                    saved.append(url)
                } catch {
                    NSLog("Screenshot failed: %@", error.localizedDescription)
                }
            }
        }
        guard !saved.isEmpty else {
            showToast("exclamationmark.triangle", "No frame to capture yet")
            return
        }
        if saved.count == 1, let image = NSImage(contentsOf: saved[0]) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        NSSound(named: "Tink")?.play()
        flash = true
        Task { try? await Task.sleep(nanoseconds: 180_000_000); flash = false }
        showToast("camera.fill", saved.count == 1 ? "Screenshot saved & copied" : "\(saved.count) screenshots saved", url: saved.first)
    }

    func toggleRecording() {
        if recording {
            Task { await stopRecording() }
        } else {
            startRecording()
        }
    }

    private var layoutSpec: LayoutSpec {
        LayoutSpec(settings: settings, top: screen(.top)?.size, bottom: screen(.bottom)?.size)
    }

    private func startRecording() {
        let targets = visibleScreens
        guard !targets.isEmpty else { return }
        let folder = captureFolder(settings.recordingFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = timestamp()
        if router == nil { audio.start() }
        let format = audio.tapFormat

        if settings.recordLayout {
            let sources = Dictionary(uniqueKeysWithValues: screens.map { ($0.role, $0.view.renderer) })
            let url = folder.appendingPathComponent("\(capturePrefix) \(stamp) Layout.mov")
            guard let recorder = try? LayoutRecorder(url: url, spec: layoutSpec, sources: sources, audioFormat: format), recorder.start() else {
                showToast("exclamationmark.triangle", "Could not start recording")
                return
            }
            layoutRecorder = recorder
            audio.addTapConsumer("record") { buffer, time in recorder.append(audio: buffer, hostTime: time.hostTime) }
        } else {
            var tracks: [ScreenRecorderTrack] = []
            for s in targets {
                let suffix = targets.count > 1 ? " \(s.role.shortTitle)" : ""
                let url = folder.appendingPathComponent("\(capturePrefix) \(stamp)\(suffix).mov")
                guard let track = try? ScreenRecorderTrack(url: url, audioFormat: format) else { continue }
                s.recorder = track
                tracks.append(track)
                s.control?.resetVideo()
            }
            guard !tracks.isEmpty else { return }
            recorders = tracks
            audio.addTapConsumer("record") { buffer, time in
                for t in tracks { t.append(audio: buffer, hostTime: time.hostTime) }
            }
        }
        recording = true
        recordingStarted = Date()
        Log.write("recording started (\(settings.recordLayout ? "layout" : "separate"))")
    }

    private func stopRecording() async {
        audio.removeTapConsumer("record")
        screens.forEach { $0.recorder = nil }
        let tracks = recorders
        let layout = layoutRecorder
        recorders = []
        layoutRecorder = nil
        recording = false
        recordingStarted = nil
        var urls: [URL] = []
        if let layout, let url = await layout.finish() { urls.append(url) }
        for t in tracks {
            if let url = await t.finish() { urls.append(url) }
        }
        if urls.isEmpty {
            showToast("exclamationmark.triangle", "Recording failed")
        } else {
            showToast("record.circle", urls.count == 1 ? "Recording saved" : "\(urls.count) recordings saved", url: urls.first, editable: true)
        }
    }

    private func updateReplay() {
        if settings.replayEnabled && state == .linked {
            let buffer = replayBuffer ?? ReplayBuffer(seconds: settings.replaySeconds)
            buffer.setSeconds(settings.replaySeconds)
            replayBuffer = buffer
            screens.forEach { $0.replay = buffer }
            if router == nil { audio.start() }
            audio.addTapConsumer("replay") { b, time in buffer.append(audio: b, hostTime: time.hostTime) }
        } else {
            audio.removeTapConsumer("replay")
            screens.forEach { $0.replay = nil }
            replayBuffer?.clear()
            replayBuffer = nil
        }
    }

    func saveReplay() {
        guard let buffer = replayBuffer else {
            showToast("clock.arrow.circlepath", "Turn on Instant Replay in Settings ▸ Capture")
            return
        }
        let snapshot = buffer.snapshot()
        let folder = captureFolder(settings.recordingFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = timestamp()
        let format = audio.tapFormat
        let prefix = capturePrefix
        let roles = visibleScreens.map(\.role).filter { !(snapshot.video[$0]?.isEmpty ?? true) }
        Log.write("replay: buffered " + snapshot.video.map { "\($0.key.rawValue)=\($0.value.count) frames (\($0.value.filter(\.key).count) key)" }.joined(separator: ", ") + ", \(snapshot.audio.count) audio buffers")
        guard !roles.isEmpty else {
            showToast("exclamationmark.triangle", "Nothing buffered yet")
            return
        }
        showToast("clock.arrow.circlepath", "Saving replay…")
        Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            for role in roles {
                guard let items = snapshot.video[role], !items.isEmpty else { continue }
                let suffix = roles.count > 1 ? " \(role.shortTitle)" : ""
                let url = folder.appendingPathComponent("\(prefix) Replay \(stamp)\(suffix).mov")
                if let saved = await ReplayWriter.write(url: url, video: items, audio: snapshot.audio, audioFormat: format) { urls.append(saved) }
            }
            let result = urls
            Log.write("replay: saved \(result.map(\.lastPathComponent))")
            await MainActor.run {
                if result.isEmpty {
                    self.showToast("exclamationmark.triangle", "Replay could not be saved")
                } else {
                    self.showToast("clock.arrow.circlepath", result.count == 1 ? "Replay saved" : "\(result.count) replays saved", url: result.first, editable: true)
                }
            }
        }
    }

    private func updateStatsLoop() {
        monitor.watch("overlay", settings.statsOverlay)
        statsTask?.cancel()
        statsTask = nil
        guard settings.statsOverlay else {
            screens.forEach { $0.clearStats() }
            audioLatencyMs = nil
            return
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.settings.statsOverlay else { return }
                let codec = self.settings.codec == .h265 ? "H.265" : "H.264"
                self.screens.forEach { $0.refreshStats(codec: codec) }
                if AudioStream.debug {
                    for screen in self.screens {
                        if let st = screen.statsSnapshot {
                            Log.write("stats \(screen.role.rawValue): \(Int(st.fps)) fps recv \(Int(st.receivedFps)) \(String(format: "%.1f", st.mbps)) Mbit/s \(Int(st.latencyMs)) ms dropped \(st.dropped) buffer \(String(format: "%.1f", screen.view.renderer.bufferMs)) ms \(st.resolution) upscaling \(self.settings.upscaling)")
                        }
                    }
                }
                let frames = AudioChannel.allCases.map { self.audio.queuedFrames($0) }.max() ?? 0
                self.audioLatencyMs = self.router == nil ? nil : Double(frames) / AudioOutput.sampleRate * 1000
            }
        }
    }
}

extension DeviceManager: PadRouter {
    var padActive: Bool { keyboardPad && state == .linked }
    var padUsesMouse: Bool { gamepad.profile.mouse != .off }

    func padKey(_ keyCode: UInt16, down: Bool) -> Bool {
        gamepad.keyboardEvent(keyCode: keyCode, down: down)
    }

    func padCapturePointer() {
        guard !pointerCaptured, NSApp.isActive else { return }
        pointerCaptured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.padReleasePointer() }
        }
    }

    func padReleasePointer() {
        guard pointerCaptured else { return }
        pointerCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    func padMouse(dx: CGFloat, dy: CGFloat) {
        gamepad.mouseMoved(dx: dx, dy: dy)
    }

    func padClick(right: Bool, down: Bool) {
        _ = gamepad.mouseButton(right: right, down: down)
    }
}
