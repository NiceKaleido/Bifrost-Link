import Foundation
import GameController
import CoreHaptics

final class GamepadBridge: @unchecked Sendable {
    enum Identity: String, CaseIterable, Identifiable {
        case odin, xbox
        var id: String { rawValue }
        var title: String { self == .odin ? "Odin Controller (like the Thor’s own)" : "Xbox Wireless Controller (with rumble)" }
        var vendorId: UInt16 { self == .odin ? 0x2020 : 0x045E }
        var productId: UInt16 { self == .odin ? 0x0111 : 0x02FD }
        var deviceName: String { self == .odin ? "Odin Controller" : "Xbox Wireless Controller" }
    }

    var identity: Identity = .odin
    private let layoutLock = NSLock()
    private var nintendoLayoutStorage = true
    var nintendoLayout: Bool {
        get { layoutLock.lock(); defer { layoutLock.unlock() }; return nintendoLayoutStorage }
        set { layoutLock.lock(); nintendoLayoutStorage = newValue; layoutLock.unlock() }
    }

    static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
        0xA1, 0x00,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02,
        0xC0,
        0x05, 0x02, 0x09, 0xC5, 0x09, 0xC4,
        0x15, 0x00, 0x26, 0xFF, 0x03, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x0F, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0F, 0x81, 0x02,
        0x75, 0x01, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x0C, 0x0A, 0x24, 0x02, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
        0x75, 0x07, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
        0xC0,
    ]

    private weak var control: ControlChannel?
    private var slots: [ObjectIdentifier: UInt16] = [:]
    private var controllers: [UInt16: GCController] = [:]
    private var rumblers: [UInt16: Rumbler] = [:]
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    var rumbleEnabled = true
    var onChange: (([String]) -> Void)?
    private(set) var names: [String] = []

    func attach(_ control: ControlChannel) {
        detach()
        self.control = control
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let c = note.object as? GCController { self?.connect(c) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            if let c = note.object as? GCController { self?.disconnect(c) }
        })
        GCController.controllers().forEach(connect)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    func detach(sendDestroy: Bool = true) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        lock.lock()
        let ids = Array(slots.values)
        let activeRumblers = Array(rumblers.values)
        slots.removeAll()
        controllers.removeAll()
        rumblers.removeAll()
        lock.unlock()
        activeRumblers.forEach { $0.stop() }
        if sendDestroy { ids.forEach { control?.uhidDestroy(id: $0) } }
        if keyboardActive {
            if sendDestroy { control?.uhidDestroy(id: Self.keyboardSlot) }
            keyboardActive = false
            decayTimer?.invalidate()
            decayTimer = nil
        }
        control = nil
        publish()
    }

    private func connect(_ controller: GCController) {
        guard let pad = controller.extendedGamepad, let control else { return }
        let key = ObjectIdentifier(controller)
        lock.lock()
        if slots[key] != nil { lock.unlock(); return }
        let used = Set(slots.values)
        let id = (UInt16(10)...UInt16(20)).first { !used.contains($0) } ?? 10
        slots[key] = id
        controllers[id] = controller
        lock.unlock()
        control.uhidCreate(id: id, vendorId: identity.vendorId, productId: identity.productId,
                           name: identity.deviceName, descriptor: Self.descriptor)
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            self?.send(gamepad, id: id)
        }
        send(pad, id: id)
        Log.write("gamepad: \(controller.vendorName ?? "controller") attached as uhid \(id), haptics \(controller.haptics != nil)")
        publish()
    }

    private func disconnect(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        lock.lock()
        let id = slots.removeValue(forKey: key)
        var rumbler: Rumbler?
        if let id {
            controllers[id] = nil
            rumbler = rumblers.removeValue(forKey: id)
        }
        lock.unlock()
        rumbler?.stop()
        if let id { control?.uhidDestroy(id: id) }
        publish()
    }

    private func publish() {
        names = GCController.controllers().filter { $0.extendedGamepad != nil }.map { $0.vendorName ?? "Controller" }
        onChange?(names)
    }

    func handleOutput(id: UInt16, data: Data) {
        guard rumbleEnabled, data.count >= 6, data[data.startIndex] == 0x03 else { return }
        let strong = Float(data[data.startIndex + 4]) / 100
        let weak = Float(data[data.startIndex + 5]) / 100
        lock.lock()
        var rumbler = rumblers[id]
        if rumbler == nil, let controller = controllers[id] {
            rumbler = Rumbler(controller: controller)
            rumblers[id] = rumbler
        }
        lock.unlock()
        rumbler?.set(strong: min(1, strong), weak: min(1, weak))
    }

    private let profileLock = NSLock()
    private var profileStorage = ControllerProfile.standard
    var profile: ControllerProfile {
        get { profileLock.lock(); defer { profileLock.unlock() }; return profileStorage }
        set {
            profileLock.lock(); profileStorage = newValue; profileLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.refreshAll() }
        }
    }
    var onInputs: ((Set<PadInput>) -> Void)?
    private var lastInputs: Set<PadInput> = []

    static let keyboardSlot: UInt16 = 30
    private(set) var keyboardActive = false
    private var keysDown: Set<PadInput> = []
    private var mouseX: Float = 0, mouseY: Float = 0
    private var decayTimer: Timer?

    private func refreshAll() {
        lock.lock()
        let active = controllers
        lock.unlock()
        for (id, controller) in active {
            if let pad = controller.extendedGamepad { send(pad, id: id) }
        }
        if keyboardActive { sendKeyboard() }
    }

    private func send(_ pad: GCExtendedGamepad, id: UInt16) {
        let state = PadState(pad)
        report(state.pressed)
        control?.uhidInput(id: id, report: encode(profile.apply(state)))
    }

    private func report(_ inputs: Set<PadInput>) {
        guard inputs != lastInputs else { return }
        lastInputs = inputs
        onInputs?(inputs)
    }

    func bind(_ control: ControlChannel) {
        if self.control == nil { self.control = control }
    }

    func setKeyboardPad(_ enabled: Bool) {
        guard enabled != keyboardActive else { return }
        keyboardActive = enabled
        keysDown.removeAll()
        mouseX = 0
        mouseY = 0
        if enabled {
            control?.uhidCreate(id: Self.keyboardSlot, vendorId: identity.vendorId, productId: identity.productId,
                                name: identity.deviceName, descriptor: Self.descriptor)
            sendKeyboard()
            Log.write("keyboard plays as controller (uhid \(Self.keyboardSlot))")
        } else {
            decayTimer?.invalidate()
            decayTimer = nil
            control?.uhidDestroy(id: Self.keyboardSlot)
            Log.write("keyboard back to typing")
        }
    }

    func keyboardEvent(keyCode: UInt16, down: Bool) -> Bool {
        guard keyboardActive, let input = profile.keyInput(keyCode) else { return false }
        if down { keysDown.insert(input) } else { keysDown.remove(input) }
        sendKeyboard()
        return true
    }

    func mouseButton(right: Bool, down: Bool) -> Bool {
        let p = profile
        guard keyboardActive, p.mouse != .off, let raw = right ? p.rightClick : p.leftClick, let input = PadInput(rawValue: raw) else { return false }
        if down { keysDown.insert(input) } else { keysDown.remove(input) }
        sendKeyboard()
        return true
    }

    func mouseMoved(dx: CGFloat, dy: CGFloat) {
        let p = profile
        guard keyboardActive, p.mouse != .off else { return }
        let gain = Float(0.06 * p.mouseSensitivity)
        mouseX = max(-1, min(1, mouseX * 0.5 + Float(dx) * gain))
        mouseY = max(-1, min(1, mouseY * 0.5 - Float(dy) * gain))
        sendKeyboard()
        if decayTimer == nil {
            decayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.mouseX *= 0.7
                self.mouseY *= 0.7
                if abs(self.mouseX) < 0.02 && abs(self.mouseY) < 0.02 {
                    self.mouseX = 0
                    self.mouseY = 0
                    self.decayTimer?.invalidate()
                    self.decayTimer = nil
                }
                self.sendKeyboard()
            }
        }
    }

    private func sendKeyboard() {
        guard keyboardActive else { return }
        var state = PadState()
        state.pressed = keysDown
        let p = profile
        switch p.mouse {
        case .rightStick:
            state.rx = mouseX
            state.ry = mouseY
        case .leftStick:
            state.lx = mouseX
            state.ly = mouseY
        case .off:
            break
        }
        report(keysDown)
        control?.uhidInput(id: Self.keyboardSlot, report: encode(p.apply(state)))
    }

    private func encode(_ state: PadState) -> Data {
        func axis(_ v: Float) -> UInt16 {
            let clamped = max(-1, min(1, v))
            return UInt16(clamping: Int((clamped + 1) * 32767.5))
        }
        func trigger(_ v: Float) -> UInt16 {
            UInt16(clamping: Int(max(0, min(1, v)) * 1023))
        }
        let p = state.pressed
        var buttons: UInt16 = 0
        let nintendo = identity == .odin && nintendoLayout
        if p.contains(.a) { buttons |= 1 << (nintendo ? 1 : 0) }
        if p.contains(.b) { buttons |= 1 << (nintendo ? 0 : 1) }
        if p.contains(.x) { buttons |= 1 << (nintendo ? 4 : 3) }
        if p.contains(.y) { buttons |= 1 << (nintendo ? 3 : 4) }
        if p.contains(.l1) { buttons |= 1 << 6 }
        if p.contains(.r1) { buttons |= 1 << 7 }
        if p.contains(.start) { buttons |= 1 << 11 }
        if p.contains(.home) { buttons |= 1 << 12 }
        if p.contains(.l3) { buttons |= 1 << 13 }
        if p.contains(.r3) { buttons |= 1 << 14 }
        let select = p.contains(.select)
        if select && identity == .odin { buttons |= 1 << 10 }
        let back: UInt8 = select && identity == .xbox ? 1 : 0

        let up = p.contains(.dpadUp), down = p.contains(.dpadDown)
        let left = p.contains(.dpadLeft), right = p.contains(.dpadRight)
        var hat: UInt8 = 0
        if up { hat = left ? 8 : (right ? 2 : 1) }
        else if down { hat = left ? 6 : (right ? 4 : 5) }
        else if left { hat = 7 }
        else if right { hat = 3 }

        func dir(_ plus: PadInput, _ minus: PadInput) -> Float { (p.contains(plus) ? 1 : 0) - (p.contains(minus) ? 1 : 0) }
        let lx = state.lx + dir(.lsRight, .lsLeft), ly = state.ly + dir(.lsUp, .lsDown)
        let rx = state.rx + dir(.rsRight, .rsLeft), ry = state.ry + dir(.rsUp, .rsDown)
        let l2 = p.contains(.l2) ? 1 : state.l2
        let r2 = p.contains(.r2) ? 1 : state.r2

        var report = Data()
        report.appendLE(axis(lx))
        report.appendLE(axis(-ly))
        report.appendLE(axis(rx))
        report.appendLE(axis(-ry))
        report.appendLE(trigger(l2))
        report.appendLE(trigger(r2))
        report.appendLE(buttons)
        report.append(back)
        report.append(hat)
        return report
    }
}

final class Rumbler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bifrost.rumble")
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private weak var controller: GCController?
    private var running = false

    init(controller: GCController) {
        self.controller = controller
    }

    func set(strong: Float, weak: Float) {
        queue.async { [self] in
            let intensity = max(strong, weak)
            if intensity <= 0.01 {
                stopLocked()
                return
            }
            let sharpness: Float = weak > strong ? 0.75 : 0.25
            do {
                if !running {
                    try startLocked(intensity: intensity, sharpness: sharpness)
                } else {
                    try player?.sendParameters([
                        CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                        CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
                    ], atTime: CHHapticTimeImmediate)
                }
            } catch {
                Log.write("rumble: \(error.localizedDescription)")
                stopLocked()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopLocked()
            engine?.stop()
            engine = nil
        }
    }

    private func startLocked(intensity: Float, sharpness: Float) throws {
        if engine == nil {
            guard let haptics = controller?.haptics,
                  let created = haptics.createEngine(withLocality: .default) else { return }
            created.isAutoShutdownEnabled = true
            created.resetHandler = { [weak self] in self?.queue.async { self?.running = false } }
            engine = created
        }
        guard let engine else { return }
        try engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ], relativeTime: 0, duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let newPlayer = try engine.makeAdvancedPlayer(with: pattern)
        newPlayer.loopEnabled = true
        try newPlayer.start(atTime: CHHapticTimeImmediate)
        try newPlayer.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
        player = newPlayer
        running = true
    }

    private func stopLocked() {
        guard running else { return }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        running = false
    }
}
