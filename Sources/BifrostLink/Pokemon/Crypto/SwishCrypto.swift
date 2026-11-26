import Foundation
import CryptoKit

/// Save encryption used by Sword/Shield, Legends: Arceus, Scarlet/Violet and Legends: Z-A:
/// a repeating static XOR pad over the payload, followed by a salted SHA-256 of the result.
enum SwishCrypto {
    private static let intro: [UInt8] = [
        0x9E, 0xC9, 0x9C, 0xD7, 0x0E, 0xD3, 0x3C, 0x44, 0xFB, 0x93, 0x03, 0xDC, 0xEB, 0x39, 0xB4, 0x2A,
        0x19, 0x47, 0xE9, 0x63, 0x4B, 0xA2, 0x33, 0x44, 0x16, 0xBF, 0x82, 0xA2, 0xBA, 0x63, 0x55, 0xB6,
        0x3D, 0x9D, 0xF2, 0x4B, 0x5F, 0x7B, 0x6A, 0xB2, 0x62, 0x1D, 0xC2, 0x1B, 0x68, 0xE5, 0xC8, 0xB5,
        0x3A, 0x05, 0x90, 0x00, 0xE8, 0xA8, 0x10, 0x3D, 0xE2, 0xEC, 0xF0, 0x0C, 0xB2, 0xED, 0x4F, 0x6D,
    ]
    private static let outro: [UInt8] = [
        0xD6, 0xC0, 0x1C, 0x59, 0x8B, 0xC8, 0xB8, 0xCB, 0x46, 0xE1, 0x53, 0xFC, 0x82, 0x8C, 0x75, 0x75,
        0x13, 0xE0, 0x45, 0xDF, 0x32, 0x69, 0x3C, 0x75, 0xF0, 0x59, 0xF8, 0xD9, 0xA2, 0x5F, 0xB2, 0x17,
        0xE0, 0x80, 0x52, 0xDB, 0xEA, 0x89, 0x73, 0x99, 0x75, 0x79, 0xAF, 0xCB, 0x2E, 0x80, 0x07, 0xE6,
        0xF1, 0x26, 0xE0, 0x03, 0x0A, 0xE6, 0x6F, 0xF6, 0x41, 0xBF, 0x7E, 0x59, 0xC2, 0xAE, 0x55, 0xFD,
    ]
    /// 0x7F-byte pad, applied repeatedly.
    private static let pad: [UInt8] = [
        0xA0, 0x92, 0xD1, 0x06, 0x07, 0xDB, 0x32, 0xA1, 0xAE, 0x01, 0xF5, 0xC5, 0x1E, 0x84, 0x4F, 0xE3,
        0x53, 0xCA, 0x37, 0xF4, 0xA7, 0xB0, 0x4D, 0xA0, 0x18, 0xB7, 0xC2, 0x97, 0xDA, 0x5F, 0x53, 0x2B,
        0x75, 0xFA, 0x48, 0x16, 0xF8, 0xD4, 0x8A, 0x6F, 0x61, 0x05, 0xF4, 0xE2, 0xFD, 0x04, 0xB5, 0xA3,
        0x0F, 0xFC, 0x44, 0x92, 0xCB, 0x32, 0xE6, 0x1B, 0xB9, 0xB1, 0x2E, 0x01, 0xB0, 0x56, 0x53, 0x36,
        0xD2, 0xD1, 0x50, 0x3D, 0xDE, 0x5B, 0x2E, 0x0E, 0x52, 0xFD, 0xDF, 0x2F, 0x7B, 0xCA, 0x63, 0x50,
        0xA4, 0x67, 0x5D, 0x23, 0x17, 0xC0, 0x52, 0xE1, 0xA6, 0x30, 0x7C, 0x2B, 0xB6, 0x70, 0x36, 0x5B,
        0x2A, 0x27, 0x69, 0x33, 0xF5, 0x63, 0x7B, 0x36, 0x3F, 0x26, 0x9B, 0xA3, 0xED, 0x7A, 0x53, 0x00,
        0xA4, 0x48, 0xB3, 0x50, 0x9E, 0x14, 0xA0, 0x52, 0xDE, 0x7E, 0x10, 0x2B, 0x1B, 0x77, 0x6E,
    ]

    static func xorPad(_ data: inout [UInt8], count: Int) {
        for i in 0..<count { data[i] ^= pad[i % pad.count] }
    }

    static func hash(_ payload: ArraySlice<UInt8>) -> [UInt8] {
        var h = SHA256()
        h.update(data: intro)
        h.update(data: Array(payload))
        h.update(data: outro)
        return Array(h.finalize())
    }

    static func isValid(_ file: [UInt8]) -> Bool {
        guard file.count > 0x20 else { return false }
        return hash(file[..<(file.count - 0x20)]) == Array(file[(file.count - 0x20)...])
    }

    /// Decrypts a whole save into its blocks.
    static func decrypt(_ file: [UInt8]) throws -> [SCBlock] {
        guard isValid(file) else { throw PKError.corrupt("The save's hash doesn't match.") }
        var payload = Array(file[..<(file.count - 0x20)])
        xorPad(&payload, count: payload.count)
        var blocks: [SCBlock] = []
        var offset = 0
        while offset < payload.count {
            blocks.append(try SCBlock.read(payload, at: &offset))
        }
        return blocks
    }

    static func encrypt(_ blocks: [SCBlock]) -> [UInt8] {
        var out: [UInt8] = []
        for block in blocks { block.write(into: &out) }
        xorPad(&out, count: out.count)
        out += hash(out[...])
        return out
    }
}

/// One save block: a 32-bit key, a type, and (for objects/arrays/values) data, each encrypted with
/// a XorShift32 stream seeded from the key.
struct SCBlock {
    enum Kind: UInt8 { case none = 0, boolFalse = 1, boolTrue = 2, bool3 = 3, object = 4, array = 5,
                       u8 = 8, u16 = 9, u32 = 10, u64 = 11, s8 = 12, s16 = 13, s32 = 14, s64 = 15, f32 = 16, f64 = 17 }

    let key: UInt32
    var kind: Kind
    var subKind: Kind = .none
    var data: [UInt8]

    static func size(of kind: Kind) -> Int {
        switch kind {
        case .bool3, .u8, .s8: return 1
        case .u16, .s16: return 2
        case .u32, .s32, .f32: return 4
        case .u64, .s64, .f64: return 8
        default: return 0
        }
    }

    struct XorShift {
        private var state: UInt32
        private var counter = 0

        init(_ seed: UInt32) {
            var s = seed
            for _ in 0..<seed.nonzeroBitCount { s = XorShift.advance(s) }
            state = s
        }

        static func advance(_ value: UInt32) -> UInt32 {
            var s = value
            s ^= s << 2
            s ^= s >> 15
            s ^= s << 13
            return s
        }

        mutating func next() -> UInt8 {
            let result = UInt8(truncatingIfNeeded: state >> (UInt32(counter) << 3))
            if counter == 3 { state = XorShift.advance(state); counter = 0 } else { counter += 1 }
            return result
        }

        mutating func next32() -> UInt32 {
            UInt32(next()) | UInt32(next()) << 8 | UInt32(next()) << 16 | UInt32(next()) << 24
        }
    }

    static func read(_ d: [UInt8], at offset: inout Int) throws -> SCBlock {
        guard offset + 5 <= d.count else { throw PKError.corrupt("A save block is cut off.") }
        let key = d.u32(offset)
        offset += 4
        var xs = XorShift(key)
        guard let kind = Kind(rawValue: d[offset] ^ xs.next()) else { throw PKError.corrupt("Unknown save block type.") }
        offset += 1
        switch kind {
        case .boolFalse, .boolTrue, .bool3:
            return SCBlock(key: key, kind: kind, data: [])
        case .object:
            let count = Int(d.u32(offset) ^ xs.next32())
            offset += 4
            guard count >= 0, offset + count <= d.count else { throw PKError.corrupt("A save block is cut off.") }
            var bytes = d.slice(offset, count)
            for i in 0..<count { bytes[i] ^= xs.next() }
            offset += count
            return SCBlock(key: key, kind: kind, data: bytes)
        case .array:
            let entries = Int(d.u32(offset) ^ xs.next32())
            offset += 4
            guard let sub = Kind(rawValue: d[offset] ^ xs.next()) else { throw PKError.corrupt("Unknown save array type.") }
            offset += 1
            let count = entries * size(of: sub)
            guard count >= 0, offset + count <= d.count else { throw PKError.corrupt("A save block is cut off.") }
            var bytes = d.slice(offset, count)
            for i in 0..<count { bytes[i] ^= xs.next() }
            offset += count
            return SCBlock(key: key, kind: kind, subKind: sub, data: bytes)
        default:
            let count = size(of: kind)
            guard count > 0, offset + count <= d.count else { throw PKError.corrupt("Unknown save value.") }
            var bytes = d.slice(offset, count)
            for i in 0..<count { bytes[i] ^= xs.next() }
            offset += count
            return SCBlock(key: key, kind: kind, data: bytes)
        }
    }

    func write(into out: inout [UInt8]) {
        var xs = XorShift(key)
        out += [UInt8(key & 0xFF), UInt8((key >> 8) & 0xFF), UInt8((key >> 16) & 0xFF), UInt8(key >> 24)]
        out.append(kind.rawValue ^ xs.next())
        switch kind {
        case .boolFalse, .boolTrue, .bool3, .none:
            return
        case .object:
            let n = UInt32(data.count) ^ xs.next32()
            out += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
        case .array:
            let n = UInt32(data.count / max(1, SCBlock.size(of: subKind))) ^ xs.next32()
            out += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
            out.append(subKind.rawValue ^ xs.next())
        default:
            break
        }
        for b in data { out.append(b ^ xs.next()) }
    }
}
