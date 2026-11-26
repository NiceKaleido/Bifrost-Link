import Foundation

/// Block shuffling and stream ciphers shared by the Pokémon entity formats.
enum PKXCrypto {
    /// Stored order of the four data blocks for each shuffle value (0…23); "ABDC" means block C is stored 4th.
    static let orders: [[Int]] = [
        "ABCD", "ABDC", "ACBD", "ACDB", "ADBC", "ADCB", "BACD", "BADC", "BCAD", "BCDA", "BDAC", "BDCA",
        "CABD", "CADB", "CBAD", "CBDA", "CDAB", "CDBA", "DABC", "DACB", "DBAC", "DBCA", "DCAB", "DCBA",
    ].map { $0.unicodeScalars.map { Int($0.value) - 65 } }

    /// Stored → real block order.
    static func unshuffle(_ data: [UInt8], start: Int, blockSize: Int, shuffle: Int) -> [UInt8] {
        var out = data
        let order = orders[shuffle % 24]
        for (position, block) in order.enumerated() {
            out.put(start + block * blockSize, data.slice(start + position * blockSize, blockSize))
        }
        return out
    }

    /// Real → stored block order.
    static func shuffle(_ data: [UInt8], start: Int, blockSize: Int, shuffle: Int) -> [UInt8] {
        var out = data
        let order = orders[shuffle % 24]
        for (position, block) in order.enumerated() {
            out.put(start + position * blockSize, data.slice(start + block * blockSize, blockSize))
        }
        return out
    }

    /// The Gen 4+ LCG stream cipher: XOR each 16-bit word with the high half of the next seed.
    static func lcgCrypt(_ data: inout [UInt8], range: Range<Int>, seed: UInt32) {
        var s = seed
        var o = range.lowerBound
        while o + 1 < range.upperBound {
            s = s &* 0x41C6_4E6D &+ 0x6073
            let v = data.u16(o) ^ Int(s >> 16)
            data.set16(o, v)
            o += 2
        }
    }

    static func sum16(_ data: [UInt8], range: Range<Int>) -> Int {
        var sum = 0
        var o = range.lowerBound
        while o + 1 < range.upperBound { sum &+= data.u16(o); o += 2 }
        return sum & 0xFFFF
    }

    // MARK: Gen 4/5 (136-byte box, 236/220-byte party)

    static func decrypt45(_ stored: [UInt8]) -> [UInt8] {
        var d = stored
        let pid = d.u32(0)
        lcgCrypt(&d, range: 8..<136, seed: UInt32(d.u16(6)))
        if d.count > 136 { lcgCrypt(&d, range: 136..<d.count, seed: pid) }
        return unshuffle(d, start: 8, blockSize: 32, shuffle: Int((pid >> 13) & 31))
    }

    static func encrypt45(_ plain: [UInt8]) -> [UInt8] {
        var d = plain
        d.set16(6, sum16(d, range: 8..<136))
        let pid = d.u32(0)
        d = shuffle(d, start: 8, blockSize: 32, shuffle: Int((pid >> 13) & 31))
        lcgCrypt(&d, range: 8..<136, seed: UInt32(d.u16(6)))
        if d.count > 136 { lcgCrypt(&d, range: 136..<d.count, seed: pid) }
        return d
    }

    // MARK: Gen 6+ (encryption constant based)

    /// `storedSize` is the box size (0xE8 PK6/PK7/PB7, 0x148 PK8/PB8/PK9, 0x168 PA8).
    static func decrypt6(_ stored: [UInt8], storedSize: Int) -> [UInt8] {
        var d = stored
        let ec = d.u32(0)
        lcgCrypt(&d, range: 8..<storedSize, seed: ec)
        if d.count > storedSize { lcgCrypt(&d, range: storedSize..<d.count, seed: ec) }
        return unshuffle(d, start: 8, blockSize: (storedSize - 8) / 4, shuffle: Int((ec >> 13) & 31))
    }

    static func encrypt6(_ plain: [UInt8], storedSize: Int) -> [UInt8] {
        var d = plain
        d.set16(6, sum16(d, range: 8..<storedSize))
        let ec = d.u32(0)
        d = shuffle(d, start: 8, blockSize: (storedSize - 8) / 4, shuffle: Int((ec >> 13) & 31))
        lcgCrypt(&d, range: 8..<storedSize, seed: ec)
        if d.count > storedSize { lcgCrypt(&d, range: storedSize..<d.count, seed: ec) }
        return d
    }

    static func checksumValid6(_ plain: [UInt8], storedSize: Int) -> Bool {
        plain.u16(6) == sum16(plain, range: 8..<storedSize)
    }
}

/// Save checksums used across the generations.
enum Checksums {
    /// CRC-16/CCITT-FALSE (Gen 4, Gen 5, Gen 6 blocks).
    static func crc16ccitt(_ data: [UInt8], _ range: Range<Int>? = nil) -> Int {
        var crc: UInt16 = 0xFFFF
        for i in range ?? 0..<data.count {
            crc ^= UInt16(data[i]) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return Int(crc)
    }

    /// Reflected CRC-16 (poly 0xA001) with inverted result, used by Gen 7 blocks.
    static func crc16gen7(_ data: [UInt8], _ range: Range<Int>) -> Int {
        var crc: UInt16 = 0xFFFF
        for i in range {
            crc ^= UInt16(data[i])
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return Int(~crc)
    }

    /// Reflected CRC-16 (poly 0xA001) starting from 0, not inverted (Let's Go blocks).
    static func crc16noInvert(_ data: [UInt8], _ range: Range<Int>) -> Int {
        var crc: UInt16 = 0
        for i in range {
            crc ^= UInt16(data[i])
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return Int(crc)
    }

    /// Gen 3 sector checksum: 32-bit sum folded to 16 bits.
    static func sum32fold(_ data: [UInt8], _ range: Range<Int>) -> Int {
        var sum: UInt32 = 0
        var o = range.lowerBound
        while o + 3 < range.upperBound { sum &+= data.u32(o); o += 4 }
        return Int((sum >> 16) &+ (sum & 0xFFFF)) & 0xFFFF
    }
}
