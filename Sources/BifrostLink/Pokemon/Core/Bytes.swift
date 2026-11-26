import Foundation

/// Little/big-endian reads and writes on a byte array, used by every save format.
extension Array where Element == UInt8 {
    func u8(_ o: Int) -> Int { Int(self[o]) }
    func u16(_ o: Int) -> Int { Int(self[o]) | Int(self[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
    func u16be(_ o: Int) -> Int { Int(self[o]) << 8 | Int(self[o + 1]) }
    func u24be(_ o: Int) -> Int { Int(self[o]) << 16 | Int(self[o + 1]) << 8 | Int(self[o + 2]) }
    func u32be(_ o: Int) -> UInt32 { UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3]) }

    mutating func set8(_ o: Int, _ v: Int) { self[o] = UInt8(truncatingIfNeeded: v) }
    mutating func set16(_ o: Int, _ v: Int) {
        self[o] = UInt8(truncatingIfNeeded: v)
        self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    mutating func set32(_ o: Int, _ v: UInt32) {
        for i in 0..<4 { self[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }
    mutating func set64(_ o: Int, _ v: UInt64) {
        set32(o, UInt32(truncatingIfNeeded: v))
        set32(o + 4, UInt32(truncatingIfNeeded: v >> 32))
    }
    mutating func set16be(_ o: Int, _ v: Int) {
        self[o] = UInt8(truncatingIfNeeded: v >> 8)
        self[o + 1] = UInt8(truncatingIfNeeded: v)
    }
    mutating func set24be(_ o: Int, _ v: Int) {
        self[o] = UInt8(truncatingIfNeeded: v >> 16)
        self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        self[o + 2] = UInt8(truncatingIfNeeded: v)
    }
    mutating func set32be(_ o: Int, _ v: UInt32) {
        for i in 0..<4 { self[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(3 - i))) }
    }

    func slice(_ o: Int, _ n: Int) -> [UInt8] { Array(self[o..<(o + n)]) }
    mutating func put(_ o: Int, _ bytes: [UInt8]) { replaceSubrange(o..<(o + bytes.count), with: bytes) }

    func bit(_ o: Int, _ index: Int) -> Bool { self[o + index >> 3] & (1 << (index & 7)) != 0 }
    mutating func setBit(_ o: Int, _ index: Int, _ on: Bool) {
        if on { self[o + index >> 3] |= 1 << (index & 7) } else { self[o + index >> 3] &= ~(1 << (index & 7)) }
    }

    var isAllZero: Bool { allSatisfy { $0 == 0 } }
    var isAllFF: Bool { allSatisfy { $0 == 0xFF } }
}

enum PKError: LocalizedError {
    case unsupported(String)
    case corrupt(String)
    case readOnly(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s), .corrupt(let s), .readOnly(let s): return s
        }
    }
}
