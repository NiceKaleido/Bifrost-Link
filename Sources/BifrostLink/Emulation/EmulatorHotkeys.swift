import Foundation

struct KeyPress: Equatable {
    let keycode: Int32
    let meta: Int32
}

enum HotkeyBinding: Equatable {
    case keys(hold: KeyPress?, press: KeyPress)
    case pad([PadInput])
}

enum StateAction {
    case save, load
    var title: String { self == .save ? "save" : "load" }
}

@MainActor
final class EmulatorHotkeys {
    static let retroarchConfig = "/sdcard/Android/data/com.retroarch/files/retroarch.cfg"
    static let ppssppControls = "/sdcard/Android/data/org.ppsspp.ppsspp/files/PSP/SYSTEM/controls.ini"

    static let names: [String: String] = [
        "com.retroarch": "RetroArch", "com.retroarch.aarch64": "RetroArch", "org.ppsspp.ppsspp": "PPSSPP",
        "org.dolphinemu.dolphinemu": "Dolphin", "com.github.stenzek.duckstation": "DuckStation", "com.armsx2": "ARMSX2",
        "io.github.lime3ds.android": "Azahar", "dev.igawa6.edenduo": "Eden Duo", "dev.eden.eden_emulator.nightly": "Eden Nightly",
        "me.magnum.melondualds": "melonDS",
    ]

    static let unsupported: [String: String] = [
        "org.dolphinemu.dolphinemu": "Dolphin on Android has no save-state hotkeys. Use its in-game menu (Back) instead",
        "com.github.stenzek.duckstation": "DuckStation keeps its hotkeys private. Use its in-game menu instead",
        "com.armsx2": "ARMSX2 keeps its hotkeys private. Use its in-game menu instead",
        "io.github.lime3ds.android": "Azahar has no save-state hotkey Bifrost can reach. Use its in-game menu instead",
        "dev.igawa6.edenduo": "Switch emulators have no save states",
        "dev.eden.eden_emulator.nightly": "Switch emulators have no save states",
    ]

    static func binding(for package: String, action: StateAction, serial: String) async -> HotkeyBinding? {
        switch package {
        case "com.retroarch", "com.retroarch.aarch64":
            let cfg = (try? await ADB.shared.shell("cat \(ADB.quote(retroarchConfig)) 2>/dev/null", serial: serial, timeout: 10)) ?? ""
            return retroarch(cfg, action: action)
        case "org.ppsspp.ppsspp":
            let ini = (try? await ADB.shared.shell("cat \(ADB.quote(ppssppControls)) 2>/dev/null", serial: serial, timeout: 10)) ?? ""
            return ppsspp(ini, action: action)
        default:
            return nil
        }
    }

    static func value(_ key: String, in cfg: String) -> String? {
        for line in cfg.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func retroarch(_ cfg: String, action: StateAction) -> HotkeyBinding? {
        let key = action == .save ? "input_save_state" : "input_load_state"
        guard let name = value(key, in: cfg), let press = retroarchKey(name) else { return nil }
        let hold = value("input_enable_hotkey", in: cfg).flatMap(retroarchKey)
        return .keys(hold: hold, press: press)
    }

    static func retroarchKey(_ name: String) -> KeyPress? {
        let n = name.lowercased()
        guard !n.isEmpty, n != "nul" else { return nil }
        if n.hasPrefix("f"), let number = Int32(n.dropFirst()), (1...12).contains(number) { return KeyPress(keycode: 130 + number, meta: 0) }
        if n.count == 1, let scalar = n.unicodeScalars.first {
            if (97...122).contains(scalar.value) { return KeyPress(keycode: 29 + Int32(scalar.value - 97), meta: 0) }
            if (48...57).contains(scalar.value) { return KeyPress(keycode: 7 + Int32(scalar.value - 48), meta: 0) }
        }
        let special: [String: Int32] = [
            "escape": 111, "space": 62, "enter": 66, "return": 66, "tab": 61, "backspace": 67,
            "up": 19, "down": 20, "left": 21, "right": 22, "insert": 124, "del": 112, "home": 122, "end": 123,
            "pageup": 92, "pagedown": 93, "rshift": 60, "shift": 59, "ctrl": 113, "alt": 57,
        ]
        return special[n].map { KeyPress(keycode: $0, meta: 0) }
    }

    static let androidPad: [Int: PadInput] = [
        96: .a, 97: .b, 99: .x, 100: .y, 102: .l1, 103: .r1, 104: .l2, 105: .r2, 106: .l3, 107: .r3,
        108: .start, 109: .select, 110: .home, 19: .dpadUp, 20: .dpadDown, 21: .dpadLeft, 22: .dpadRight,
    ]

    static func ppsspp(_ ini: String, action: StateAction) -> HotkeyBinding? {
        guard let raw = value(action == .save ? "Save State" : "Load State", in: ini) else { return nil }
        for mapping in raw.split(separator: ",").map(String.init) {
            let keys = mapping.split(separator: ":").compactMap { part -> (Int, Int)? in
                let pieces = part.split(separator: "-")
                guard pieces.count == 2, let device = Int(pieces[0]), let code = Int(pieces[1]) else { return nil }
                return (device, code)
            }
            guard !keys.isEmpty else { continue }
            if keys.allSatisfy({ $0.0 >= 10 }) {
                let inputs = keys.compactMap { androidPad[$0.1] }
                if inputs.count == keys.count { return .pad(inputs) }
            }
            if keys.count == 1, keys[0].0 == 1 {
                return .keys(hold: nil, press: KeyPress(keycode: Int32(keys[0].1), meta: 0))
            }
        }
        return nil
    }
}
