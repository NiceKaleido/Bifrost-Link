import AppKit

enum AndroidKey {
    static let home: Int32 = 3
    static let back: Int32 = 4
    static let volumeUp: Int32 = 24
    static let volumeDown: Int32 = 25
    static let power: Int32 = 26
    static let appSwitch: Int32 = 187
    static let sleep: Int32 = 223
    static let mediaPlayPause: Int32 = 85
}

enum KeyMap {
    static let special: [UInt16: Int32] = [
        0x24: 66, 0x4C: 160, 0x30: 61, 0x31: 62, 0x33: 67, 0x75: 112, 0x35: 111,
        0x7B: 21, 0x7C: 22, 0x7D: 20, 0x7E: 19,
        0x73: 122, 0x77: 123, 0x74: 92, 0x79: 93,
        0x7A: 131, 0x78: 132, 0x63: 133, 0x76: 134, 0x60: 135, 0x61: 136,
        0x62: 137, 0x64: 138, 0x65: 139, 0x6D: 140, 0x67: 141, 0x6F: 142,
        0x38: 59, 0x3C: 60, 0x3B: 113, 0x3E: 114, 0x3A: 57, 0x3D: 58, 0x39: 115,
        0x52: 144, 0x53: 145, 0x54: 146, 0x55: 147, 0x56: 148, 0x57: 149,
        0x58: 150, 0x59: 151, 0x5B: 152, 0x5C: 153,
        0x4B: 154, 0x43: 155, 0x4E: 156, 0x45: 157, 0x41: 158, 0x51: 161,
    ]

    static let positional: [UInt16: Int32] = [
        0x00: 29, 0x0B: 30, 0x08: 31, 0x02: 32, 0x0E: 33, 0x03: 34, 0x05: 35, 0x04: 36,
        0x22: 37, 0x26: 38, 0x28: 39, 0x25: 40, 0x2E: 41, 0x2D: 42, 0x1F: 43, 0x23: 44,
        0x0C: 45, 0x0F: 46, 0x01: 47, 0x11: 48, 0x20: 49, 0x09: 50, 0x0D: 51, 0x07: 52,
        0x10: 53, 0x06: 54,
        0x1D: 7, 0x12: 8, 0x13: 9, 0x14: 10, 0x15: 11, 0x17: 12, 0x16: 13, 0x1A: 14, 0x1C: 15, 0x19: 16,
        0x32: 68, 0x1B: 69, 0x18: 70, 0x21: 71, 0x1E: 72, 0x2A: 73, 0x29: 74, 0x27: 75, 0x2C: 76, 0x2B: 55, 0x2F: 56,
    ]

    static let modifierKeyCodes: Set<UInt16> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x39]

    static func metaState(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var meta: Int32 = 0
        if flags.contains(.shift) { meta |= 0x41 }
        if flags.contains(.control) { meta |= 0x3000 }
        if flags.contains(.option) { meta |= 0x12 }
        if flags.contains(.capsLock) { meta |= 0x100000 }
        return meta
    }

    static func keycodeForCharacter(_ char: Character) -> Int32? {
        guard char.isASCII, let scalar = char.unicodeScalars.first else { return nil }
        let v = scalar.value
        switch v {
        case 0x61...0x7A: return 29 + Int32(v - 0x61)
        case 0x41...0x5A: return 29 + Int32(v - 0x41)
        case 0x30...0x39: return 7 + Int32(v - 0x30)
        default: return nil
        }
    }

    enum Translation {
        case key(Int32, meta: Int32)
        case text(String)
        case none
    }

    static func translate(_ event: NSEvent) -> Translation {
        let flags = event.modifierFlags
        let meta = metaState(flags)
        if let code = special[event.keyCode] {
            return .key(code, meta: meta)
        }
        let plain = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.control) {
            if let c = plain.first, let code = keycodeForCharacter(c) { return .key(code, meta: meta) }
            if let code = positional[event.keyCode] { return .key(code, meta: meta) }
            return .none
        }
        let typed = event.characters ?? ""
        if !flags.contains(.option), plain.count == 1, let c = plain.first, let code = keycodeForCharacter(c),
           c.isLetter || !flags.contains(.shift) {
            return .key(code, meta: meta)
        }
        if !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            return .text(typed)
        }
        if let code = positional[event.keyCode] { return .key(code, meta: meta) }
        return .none
    }
}
