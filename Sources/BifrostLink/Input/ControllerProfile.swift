import Foundation
import GameController

enum PadInput: String, Codable, CaseIterable, Identifiable {
    case a, b, x, y, l1, r1, l2, r2, l3, r3, start, select, home
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case lsUp, lsDown, lsLeft, lsRight
    case rsUp, rsDown, rsLeft, rsRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l1: return "L1 / LB"
        case .r1: return "R1 / RB"
        case .l2: return "L2 / LT"
        case .r2: return "R2 / RT"
        case .l3: return "Left stick click"
        case .r3: return "Right stick click"
        case .start: return "Start"
        case .select: return "Select"
        case .home: return "Home"
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .lsUp: return "Left stick up"
        case .lsDown: return "Left stick down"
        case .lsLeft: return "Left stick left"
        case .lsRight: return "Left stick right"
        case .rsUp: return "Right stick up"
        case .rsDown: return "Right stick down"
        case .rsLeft: return "Right stick left"
        case .rsRight: return "Right stick right"
        }
    }

    static let buttons: [PadInput] = [.a, .b, .x, .y, .l1, .r1, .l2, .r2, .l3, .r3, .start, .select, .home, .dpadUp, .dpadDown, .dpadLeft, .dpadRight]
}

struct PadState: Equatable {
    var pressed: Set<PadInput> = []
    var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
    var l2: Float = 0, r2: Float = 0

    init() {}

    init(_ pad: GCExtendedGamepad) {
        if pad.buttonA.isPressed { pressed.insert(.a) }
        if pad.buttonB.isPressed { pressed.insert(.b) }
        if pad.buttonX.isPressed { pressed.insert(.x) }
        if pad.buttonY.isPressed { pressed.insert(.y) }
        if pad.leftShoulder.isPressed { pressed.insert(.l1) }
        if pad.rightShoulder.isPressed { pressed.insert(.r1) }
        if pad.leftThumbstickButton?.isPressed == true { pressed.insert(.l3) }
        if pad.rightThumbstickButton?.isPressed == true { pressed.insert(.r3) }
        if pad.buttonMenu.isPressed { pressed.insert(.start) }
        if pad.buttonOptions?.isPressed == true { pressed.insert(.select) }
        if pad.buttonHome?.isPressed == true { pressed.insert(.home) }
        if pad.dpad.up.isPressed { pressed.insert(.dpadUp) }
        if pad.dpad.down.isPressed { pressed.insert(.dpadDown) }
        if pad.dpad.left.isPressed { pressed.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { pressed.insert(.dpadRight) }
        lx = pad.leftThumbstick.xAxis.value
        ly = pad.leftThumbstick.yAxis.value
        rx = pad.rightThumbstick.xAxis.value
        ry = pad.rightThumbstick.yAxis.value
        l2 = pad.leftTrigger.value
        r2 = pad.rightTrigger.value
        if l2 > 0.5 { pressed.insert(.l2) }
        if r2 > 0.5 { pressed.insert(.r2) }
    }
}

struct ControllerProfile: Codable, Equatable {
    enum MouseMode: String, Codable, CaseIterable, Identifiable {
        case off, rightStick, leftStick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .rightStick: return "Right stick (camera)"
            case .leftStick: return "Left stick"
            }
        }
    }

    var remap: [String: String] = [:]
    var swapSticks = false
    var invertLeftY = false
    var invertRightY = false
    var deadzone: Double = 0.08
    var keyboard: [String: String] = ControllerProfile.defaultKeyboard
    var mouse: MouseMode = .rightStick
    var mouseSensitivity: Double = 1
    var leftClick: String? = PadInput.r2.rawValue
    var rightClick: String? = PadInput.l2.rawValue
    var keyLabels: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case remap, swapSticks, invertLeftY, invertRightY, deadzone, keyboard, mouse, mouseSensitivity, leftClick, rightClick, keyLabels
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remap = try c.decodeIfPresent([String: String].self, forKey: .remap) ?? [:]
        swapSticks = try c.decodeIfPresent(Bool.self, forKey: .swapSticks) ?? false
        invertLeftY = try c.decodeIfPresent(Bool.self, forKey: .invertLeftY) ?? false
        invertRightY = try c.decodeIfPresent(Bool.self, forKey: .invertRightY) ?? false
        deadzone = try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? 0.08
        keyboard = try c.decodeIfPresent([String: String].self, forKey: .keyboard) ?? Self.defaultKeyboard
        mouse = try c.decodeIfPresent(MouseMode.self, forKey: .mouse) ?? .rightStick
        mouseSensitivity = try c.decodeIfPresent(Double.self, forKey: .mouseSensitivity) ?? 1
        leftClick = try c.decodeIfPresent(String.self, forKey: .leftClick)
        rightClick = try c.decodeIfPresent(String.self, forKey: .rightClick)
        keyLabels = try c.decodeIfPresent([String: String].self, forKey: .keyLabels) ?? [:]
    }

    static let builtInLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        55: "⌘", 56: "Shift", 57: "Caps Lock", 58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control",
        123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    ]

    func label(for keyCode: UInt16) -> String {
        keyLabels[String(keyCode)] ?? Self.builtInLabels[keyCode] ?? "Key \(keyCode)"
    }

    static let standard = ControllerProfile()

    static let defaultKeyboard: [String: String] = [
        "13": "lsUp", "0": "lsLeft", "1": "lsDown", "2": "lsRight",
        "126": "dpadUp", "125": "dpadDown", "123": "dpadLeft", "124": "dpadRight",
        "40": "a", "37": "b", "38": "x", "34": "y",
        "12": "l1", "14": "r1", "18": "l2", "20": "r2",
        "36": "start", "48": "select", "15": "l3", "17": "r3",
    ]

    func target(for input: PadInput) -> PadInput? {
        guard let mapped = remap[input.rawValue] else { return input }
        return mapped == "none" ? nil : PadInput(rawValue: mapped) ?? input
    }

    func keyInput(_ keyCode: UInt16) -> PadInput? {
        keyboard[String(keyCode)].flatMap(PadInput.init(rawValue:))
    }

    func keyCode(for input: PadInput) -> UInt16? {
        keyboard.first { $0.value == input.rawValue }.flatMap { UInt16($0.key) }
    }

    func apply(_ state: PadState) -> PadState {
        var out = PadState()
        for input in state.pressed {
            if let target = target(for: input) { out.pressed.insert(target) }
        }
        func dz(_ v: Float) -> Float { abs(v) < Float(deadzone) ? 0 : v }
        var lx = dz(state.lx), ly = dz(state.ly), rx = dz(state.rx), ry = dz(state.ry)
        if invertLeftY { ly = -ly }
        if invertRightY { ry = -ry }
        if swapSticks { swap(&lx, &rx); swap(&ly, &ry) }
        out.lx = lx; out.ly = ly; out.rx = rx; out.ry = ry
        let l2Target = target(for: .l2), r2Target = target(for: .r2)
        if l2Target == .l2 { out.l2 = max(out.l2, state.l2) } else if l2Target == .r2 { out.r2 = max(out.r2, state.l2) }
        if r2Target == .r2 { out.r2 = max(out.r2, state.r2) } else if r2Target == .l2 { out.l2 = max(out.l2, state.r2) }
        return out
    }
}

enum ControllerProfiles {
    private static let key = "controllerProfiles"
    static let everyone = "default"

    static func all() -> [String: ControllerProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ControllerProfile].self, from: data)) ?? [:]
    }

    static func get(_ id: String) -> ControllerProfile? { all()[id] }

    static func set(_ profile: ControllerProfile?, for id: String) {
        var map = all()
        map[id] = profile
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func resolve(_ playing: NowPlaying?) -> (profile: ControllerProfile, scope: String) {
        let map = all()
        if let playing {
            let game = LayoutProfiles.gameKey(playing)
            if let profile = map[game] { return (profile, game) }
            if !playing.isApp, let profile = map[LayoutProfiles.systemKey(playing.system)] { return (profile, LayoutProfiles.systemKey(playing.system)) }
        }
        return (map[everyone] ?? .standard, everyone)
    }
}
