import Foundation

/// Character encodings used by the games for names (international versions).
enum TextCodec {
    // MARK: Gen 1/2 (Game Boy)

    private static let gbTable: [UInt8: Character] = {
        var t: [UInt8: Character] = [0x7F: " "]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { t[0x80 + UInt8(i)] = c }
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[0xA0 + UInt8(i)] = c }
        for (i, c) in "0123456789".enumerated() { t[0xF6 + UInt8(i)] = c }
        let extra: [UInt8: Character] = [
            0x9A: "(", 0x9B: ")", 0x9C: ":", 0x9D: ";", 0x9E: "[", 0x9F: "]", 0xBA: "é",
            0xE0: "'", 0xE3: "-", 0xE6: "?", 0xE7: "!", 0xE8: ".", 0xEF: "♂", 0xF0: "$",
            0xF1: "×", 0xF2: ".", 0xF3: "/", 0xF4: ",", 0xF5: "♀",
        ]
        t.merge(extra) { a, _ in a }
        return t
    }()
    private static let gbReverse: [Character: UInt8] = {
        var r: [Character: UInt8] = [:]
        for (k, v) in gbTable where r[v] == nil { r[v] = k }
        r["."] = 0xE8
        return r
    }()

    static func decodeGB(_ bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            if b == 0x50 || b == 0x00 { break }
            if b == 0xE1 { s += "PK"; continue }
            if b == 0xE2 { s += "MN"; continue }
            if let c = gbTable[b] { s.append(c) }
        }
        return s
    }

    /// Terminated with 0x50, padded with 0x50 like the games do.
    static func encodeGB(_ text: String, length: Int) -> [UInt8] {
        var out: [UInt8] = []
        for c in text where out.count < length - 1 {
            if let b = gbReverse[c] { out.append(b) } else if let b = gbReverse[Character(c.uppercased())] { out.append(b) }
        }
        while out.count < length { out.append(0x50) }
        return out
    }

    // MARK: Gen 3 (GBA, GameCube Box)

    private static let g3Table: [UInt8: Character] = {
        var t: [UInt8: Character] = [0x00: " "]
        for (i, c) in "0123456789".enumerated() { t[0xA1 + UInt8(i)] = c }
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { t[0xBB + UInt8(i)] = c }
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[0xD5 + UInt8(i)] = c }
        let extra: [UInt8: Character] = [
            0x01: "À", 0x02: "Á", 0x03: "Â", 0x04: "Ç", 0x05: "È", 0x06: "É", 0x07: "Ê", 0x08: "Ë", 0x09: "Ì",
            0x0B: "Î", 0x0C: "Ï", 0x0D: "Ò", 0x0E: "Ó", 0x0F: "Ô", 0x10: "Œ", 0x11: "Ù", 0x12: "Ú", 0x13: "Û",
            0x14: "Ñ", 0x15: "ß", 0x16: "à", 0x17: "á", 0x19: "ç", 0x1A: "è", 0x1B: "é", 0x1C: "ê", 0x1D: "ë",
            0x1E: "ì", 0x20: "î", 0x21: "ï", 0x22: "ò", 0x23: "ó", 0x24: "ô", 0x25: "œ", 0x26: "ù", 0x27: "ú",
            0x28: "û", 0x29: "ñ", 0x2A: "º", 0x2B: "ª", 0x2D: "&", 0x2E: "+", 0x35: "=", 0x36: ";",
            0x51: "¿", 0x52: "¡", 0x5A: "Í", 0x5B: "%", 0x5C: "(", 0x5D: ")", 0x68: "â", 0x6F: "í",
            0xAB: "!", 0xAC: "?", 0xAD: ".", 0xAE: "-", 0xB0: "…", 0xB1: "“", 0xB2: "”", 0xB3: "‘", 0xB4: "’",
            0xB5: "♂", 0xB6: "♀", 0xB7: "$", 0xB8: ",", 0xB9: "×", 0xBA: "/", 0xF0: ":",
            0xF1: "Ä", 0xF2: "Ö", 0xF3: "Ü", 0xF4: "ä", 0xF5: "ö", 0xF6: "ü",
        ]
        t.merge(extra) { a, _ in a }
        return t
    }()
    private static let g3Reverse: [Character: UInt8] = {
        var r: [Character: UInt8] = [:]
        for (k, v) in g3Table where r[v] == nil { r[v] = k }
        r["'"] = 0xB4
        return r
    }()

    static func decodeGen3(_ bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            if b == 0xFF { break }
            if let c = g3Table[b] { s.append(c) }
        }
        return s
    }

    static func encodeGen3(_ text: String, length: Int) -> [UInt8] {
        var out: [UInt8] = []
        for c in text where out.count < length {
            if let b = g3Reverse[c] { out.append(b) }
        }
        if out.count < length { out.append(0xFF) }
        while out.count < length { out.append(0xFF) }
        return out
    }

    // MARK: Gen 4 (DS) – a game-specific 16-bit table

    private static let g4Table: [Int: Character] = {
        var t: [Int: Character] = [0x1DE: " "]
        for (i, c) in "0123456789".enumerated() { t[0x121 + i] = c }
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { t[0x12B + i] = c }
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[0x145 + i] = c }
        // 0x15F… follows Latin-1 from À (U+00C0) to ÿ (U+00FF)
        for i in 0..<64 { t[0x15F + i] = Character(UnicodeScalar(0xC0 + i)!) }
        let tail: [Character] = ["Œ", "œ", "Ş", "ş", "ª", "º", "ᵉ", "ʳ", "ʳ", "₽", "¡", "¿", "!", "?", ",", ".", "…", "·", "/",
                                 "‘", "’", "“", "”", "„", "«", "»", "(", ")", "♂", "♀", "+", "-", "*", "#", "=", "&", "~", ":", ";"]
        for (i, c) in tail.enumerated() { t[0x19F + i] = c }
        t[0x1E0] = "@"
        t[0x1E2] = "%"
        return t
    }()
    private static let g4Reverse: [Character: Int] = {
        var r: [Character: Int] = [:]
        for (k, v) in g4Table where r[v] == nil { r[v] = k }
        r["'"] = 0x1B3
        return r
    }()

    static func decodeGen4(_ bytes: [UInt8]) -> String {
        var s = ""
        var o = 0
        while o + 1 < bytes.count {
            let v = bytes.u16(o)
            if v == 0xFFFF { break }
            if let c = g4Table[v] { s.append(c) }
            o += 2
        }
        return s
    }

    static func encodeGen4(_ text: String, chars: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: chars * 2)
        var i = 0
        for c in text where i < chars - 1 {
            guard let v = g4Reverse[c] else { continue }
            out.set16(i * 2, v)
            i += 1
        }
        out.set16(i * 2, 0xFFFF)
        return out
    }

    // MARK: Gen 5+ (UTF-16 with private-use gender symbols)

    /// `terminator` is 0xFFFF in Gen 5 and 0x0000 from Gen 6 on.
    static func decodeUTF16(_ bytes: [UInt8], terminator: Int = 0) -> String {
        var units: [UInt16] = []
        var o = 0
        while o + 1 < bytes.count {
            let v = bytes.u16(o)
            if v == terminator || v == 0 || v == 0xFFFF { break }
            switch v {
            case 0x246D, 0xE08E: units.append(0x2642)  // ♂
            case 0x246E, 0xE08F: units.append(0x2640)  // ♀
            default: units.append(UInt16(v))
            }
            o += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func encodeUTF16(_ text: String, chars: Int, terminator: Int = 0, gen5: Bool = false) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: chars * 2)
        var i = 0
        for unit in text.utf16 where i < chars - 1 {
            var v = Int(unit)
            if v == 0x2642 { v = gen5 ? 0x246D : 0xE08E }
            if v == 0x2640 { v = gen5 ? 0x246E : 0xE08F }
            out.set16(i * 2, v)
            i += 1
        }
        if i < chars { out.set16(i * 2, terminator) }
        if gen5 { for j in (i + 1)..<max(i + 1, chars) { out.set16(j * 2, 0xFFFF) } }
        return out
    }
}
