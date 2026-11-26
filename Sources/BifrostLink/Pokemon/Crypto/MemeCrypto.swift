import Foundation
import CryptoKit
import CommonCrypto

/// The signature Sun/Moon and Ultra Sun/Ultra Moon put over their save's checksum table.
/// Without a fresh signature the game rejects a changed save as corrupted.
enum MemeCrypto {
    /// Public key (DER) of the "Pokédex and save file" key and its private exponent.
    private static let der: [UInt8] = [
        0x30, 0x7C, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x6B, 0x00, 0x30, 0x68, 0x02, 0x61,
        0x00, 0xB6, 0x1E, 0x19, 0x20, 0x91, 0xF9, 0x0A, 0x8F, 0x76, 0xA6, 0xEA, 0xAA, 0x9A, 0x3C, 0xE5, 0x8C, 0x86, 0x3F, 0x39, 0xAE, 0x25, 0x3F, 0x03,
        0x78, 0x16, 0xF5, 0x97, 0x58, 0x54, 0xE0, 0x7A, 0x9A, 0x45, 0x66, 0x01, 0xE7, 0xC9, 0x4C, 0x29, 0x75, 0x9F, 0xE1, 0x55, 0xC0, 0x64, 0xED, 0xDF,
        0xA1, 0x11, 0x44, 0x3F, 0x81, 0xEF, 0x1A, 0x42, 0x8C, 0xF6, 0xCD, 0x32, 0xF9, 0xDA, 0xC9, 0xD4, 0x8E, 0x94, 0xCF, 0xB3, 0xF6, 0x90, 0x12, 0x0E,
        0x8E, 0x6B, 0x91, 0x11, 0xAD, 0xDA, 0xF1, 0x1E, 0x7C, 0x96, 0x20, 0x8C, 0x37, 0xC0, 0x14, 0x3F, 0xF2, 0xBF, 0x3D, 0x7E, 0x83, 0x11, 0x41, 0xA9,
        0x73, 0x02, 0x03, 0x01, 0x00, 0x01,
    ]
    private static let privateExponent: [UInt8] = [
        0x00, 0x77, 0x54, 0x55, 0x66, 0x8F, 0xFF, 0x3C, 0xBA, 0x30, 0x26, 0xC2, 0xD0, 0xB2, 0x6B, 0x80, 0x85, 0x89, 0x59, 0x58, 0x34, 0x11, 0x57, 0xAE,
        0xB0, 0x3B, 0x6B, 0x04, 0x95, 0xEE, 0x57, 0x80, 0x3E, 0x21, 0x86, 0xEB, 0x6C, 0xB2, 0xEB, 0x62, 0xA7, 0x1D, 0xF1, 0x8A, 0x3C, 0x9C, 0x65, 0x79,
        0x07, 0x76, 0x70, 0x96, 0x1B, 0x3A, 0x61, 0x02, 0xDA, 0xBE, 0x5A, 0x19, 0x4A, 0xB5, 0x8C, 0x32, 0x50, 0xAE, 0xD5, 0x97, 0xFC, 0x78, 0x97, 0x8A,
        0x32, 0x6D, 0xB1, 0xD7, 0xB2, 0x8D, 0xCC, 0xCB, 0x2A, 0x3E, 0x01, 0x4E, 0xDB, 0xD3, 0x97, 0xAD, 0x33, 0xB8, 0xF2, 0x8C, 0xD5, 0x25, 0x05, 0x42,
        0x51,
    ]
    private static var modulus: [UInt8] { Array(der[0x18..<(0x18 + 0x61)]) }
    private static var publicExponent: [UInt8] { Array(der[0x7B..<(0x7B + 3)]) }

    static let signatureLength = 0x60
    static let regionLength = 0x80

    // MARK: Save layout

    /// (signature region offset, checksum table offset, checksum table length) for SM / USUM saves.
    static func layout(saveSize: Int) -> (region: Int, table: Int, tableLength: Int)? {
        switch saveSize {
        case 0x6CC00: return (0x6C000 + 0x100, saveSize - 0x200, 0x150)   // Ultra Sun / Ultra Moon
        case 0x6BE00: return (0x6BA00 + 0x100, saveSize - 0x200, 0x140)   // Sun / Moon
        default: return nil
        }
    }

    /// Writes a fresh signature over the checksum table. The region must already be zeroed and the
    /// checksums (including the one of the block holding the region) computed with it zeroed.
    static func sign(_ save: inout [UInt8]) {
        guard let l = layout(saveSize: save.count) else { return }
        var region = [UInt8](repeating: 0, count: regionLength)
        region.replaceSubrange(0..<32, with: Array(SHA256.hash(data: save[l.table..<(l.table + l.tableLength)])))
        signData(&region)
        save.replaceSubrange(l.region..<(l.region + regionLength), with: region)
    }

    /// Checks the signature the same way the game does.
    static func verify(_ save: [UInt8]) -> Bool {
        guard let l = layout(saveSize: save.count) else { return true }
        let region = Array(save[l.region..<(l.region + regionLength)])
        let expectedHash = Array(SHA256.hash(data: save[l.table..<(l.table + l.tableLength)]))
        var sig = rsa(Array(region.suffix(signatureLength)), exponent: publicExponent)
        for attempt in 0..<2 {
            if attempt == 1 { sig[0] |= 0x80 }
            var data = region
            data.replaceSubrange((regionLength - signatureLength)..<regionLength, with: sig)
            aesDecrypt(&data)
            let check = Array(Insecure.SHA1.hash(data: data.prefix(regionLength - 8)).prefix(8))
            if check == Array(data.suffix(8)) { return Array(data.prefix(32)) == expectedHash }
        }
        return false
    }

    // MARK: The signing scheme

    private static func signData(_ data: inout [UInt8]) {
        let hash = Array(Insecure.SHA1.hash(data: data.prefix(data.count - 8)).prefix(8))
        data.replaceSubrange((data.count - 8)..<data.count, with: hash)
        aesEncrypt(&data)
        var sig = Array(data.suffix(signatureLength))
        sig[0] &= 0x7F
        let signed = rsa(sig, exponent: privateExponent)
        data.replaceSubrange((data.count - signatureLength)..<data.count, with: signed)
    }

    private static func aesKey(_ payload: ArraySlice<UInt8>) -> [UInt8] {
        var h = Insecure.SHA1()
        h.update(data: der)
        h.update(data: Array(payload))
        return Array(h.finalize().prefix(16))
    }

    private static func ecb(_ block: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        _ = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    key, 16, nil, block, 16, &out, 16, &moved)
        return out
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 ^ $1 } }

    private static func subKey(_ temp: [UInt8]) -> [UInt8] {
        var sub = [UInt8](repeating: 0, count: 16)
        var i = 0
        while i < 16 {
            let b1 = temp[i], b2 = temp[i + 1]
            sub[i] = (b1 &<< 1) &+ (b2 >> 7)
            sub[i + 1] = b2 &<< 1
            if i + 2 < 16 { sub[i + 1] &+= temp[i + 2] >> 7 }
            i += 2
        }
        if temp[0] & 0x80 != 0 { sub[15] ^= 0x87 }
        return sub
    }

    private static func aesEncrypt(_ data: inout [UInt8]) {
        let start = data.count - signatureLength
        let key = aesKey(data[..<start])
        var sig = Array(data[start...])
        var temp = [UInt8](repeating: 0, count: 16)
        for i in stride(from: 0, to: sig.count, by: 16) {
            let block = ecb(xor(Array(sig[i..<(i + 16)]), temp), key: key, encrypt: true)
            sig.replaceSubrange(i..<(i + 16), with: block)
            temp = block
        }
        let next = subKey(xor(temp, Array(sig[0..<16])))
        for i in stride(from: 0, to: sig.count, by: 16) { sig.replaceSubrange(i..<(i + 16), with: xor(Array(sig[i..<(i + 16)]), next)) }
        temp = [UInt8](repeating: 0, count: 16)
        for i in stride(from: sig.count - 16, through: 0, by: -16) {
            let plain = Array(sig[i..<(i + 16)])
            sig.replaceSubrange(i..<(i + 16), with: xor(ecb(plain, key: key, encrypt: true), temp))
            temp = plain
        }
        data.replaceSubrange(start..<data.count, with: sig)
    }

    private static func aesDecrypt(_ data: inout [UInt8]) {
        let start = data.count - signatureLength
        let key = aesKey(data[..<start])
        var sig = Array(data[start...])
        var temp = [UInt8](repeating: 0, count: 16)
        for i in stride(from: sig.count - 16, through: 0, by: -16) {
            temp = ecb(xor(temp, Array(sig[i..<(i + 16)])), key: key, encrypt: false)
            sig.replaceSubrange(i..<(i + 16), with: temp)
        }
        let next = subKey(xor(temp, Array(sig.suffix(16))))
        for i in stride(from: 0, to: sig.count, by: 16) { sig.replaceSubrange(i..<(i + 16), with: xor(Array(sig[i..<(i + 16)]), next)) }
        var previous = [UInt8](repeating: 0, count: 16)
        for i in stride(from: 0, to: sig.count, by: 16) {
            let cipher = Array(sig[i..<(i + 16)])
            sig.replaceSubrange(i..<(i + 16), with: xor(ecb(cipher, key: key, encrypt: false), previous))
            previous = cipher
        }
        data.replaceSubrange(start..<data.count, with: sig)
    }

    // MARK: Big-number RSA (768-bit, little-endian 32-bit limbs)

    private typealias Big = [UInt32]

    private static func big(_ bytes: [UInt8]) -> Big {
        var limbs = Big(repeating: 0, count: (bytes.count + 3) / 4)
        for (i, b) in bytes.reversed().enumerated() { limbs[i / 4] |= UInt32(b) << (UInt32(i % 4) * 8) }
        return trim(limbs)
    }

    private static func bytes(_ x: Big, count: Int) -> [UInt8] {
        (0..<count).reversed().map { i in i / 4 < x.count ? UInt8(truncatingIfNeeded: x[i / 4] >> (UInt32(i % 4) * 8)) : 0 }
    }

    private static func trim(_ x: Big) -> Big {
        var x = x
        while x.count > 1 && x.last == 0 { x.removeLast() }
        return x
    }

    private static func compare(_ a: Big, _ b: Big) -> Int {
        let a = trim(a), b = trim(b)
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return 0
    }

    private static func subtract(_ a: Big, _ b: Big) -> Big {
        var out = a
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var v = Int64(out[i]) - borrow - (i < b.count ? Int64(b[i]) : 0)
            if v < 0 { v += 1 << 32; borrow = 1 } else { borrow = 0 }
            out[i] = UInt32(v)
        }
        return trim(out)
    }

    private static func multiply(_ a: Big, _ b: Big) -> Big {
        var out = [UInt64](repeating: 0, count: a.count + b.count + 1)
        for i in 0..<a.count {
            var carry: UInt64 = 0
            for j in 0..<b.count {
                let t = UInt64(a[i]) * UInt64(b[j]) + out[i + j] + carry
                out[i + j] = t & 0xFFFF_FFFF
                carry = t >> 32
            }
            out[i + b.count] += carry
        }
        return trim(out.map { UInt32($0 & 0xFFFF_FFFF) })
    }

    /// a mod m by shift-and-subtract.
    private static func mod(_ a: Big, _ m: Big) -> Big {
        if compare(a, m) < 0 { return a }
        var remainder: Big = [0]
        let bits = a.count * 32
        for bit in stride(from: bits - 1, through: 0, by: -1) {
            // remainder = remainder << 1 | bit
            var carry: UInt32 = (a[bit / 32] >> UInt32(bit % 32)) & 1
            for i in 0..<remainder.count {
                let next = remainder[i] >> 31
                remainder[i] = remainder[i] << 1 | carry
                carry = next
            }
            if carry != 0 { remainder.append(carry) }
            if compare(remainder, m) >= 0 { remainder = subtract(remainder, m) }
        }
        return trim(remainder)
    }

    private static func rsa(_ message: [UInt8], exponent: [UInt8]) -> [UInt8] {
        let n = big(modulus), e = big(exponent)
        var result: Big = [1]
        var base = mod(big(message), n)
        let bits = e.count * 32
        for bit in 0..<bits {
            if (e[bit / 32] >> UInt32(bit % 32)) & 1 == 1 { result = mod(multiply(result, base), n) }
            if bit < bits - 1 { base = mod(multiply(base, base), n) }
        }
        return bytes(result, count: signatureLength)
    }
}
