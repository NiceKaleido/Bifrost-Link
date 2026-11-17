import Foundation

enum RomPatcher {
    static let extensions: Set<String> = ["ips", "ups", "bps", "xdelta", "vcdiff", "delta"]

    enum Failure: LocalizedError {
        case wrongGame
        case damaged(String)
        case unsupported
        case toolMissing
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .wrongGame: return "This patch is for a different version of the game"
            case .damaged(let detail): return "The patch file looks damaged (\(detail))"
            case .unsupported: return "This patch format isn’t supported"
            case .toolMissing: return "xdelta patches need the bundled xdelta3, which is missing"
            case .toolFailed(let message): return message.isEmpty ? "The patch couldn’t be applied" : message
            }
        }
    }

    static func isPatch(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func outputName(patch: URL, rom: URL) -> String {
        let patchBase = patch.deletingPathExtension().lastPathComponent
        let romBase = rom.deletingPathExtension().lastPathComponent
        let ext = rom.pathExtension
        let base = patchBase.caseInsensitiveCompare(romBase) == .orderedSame ? "\(romBase) (patched)" : patchBase
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    static func apply(patch: URL, to rom: URL, output: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let ext = patch.pathExtension.lowercased()
            if ["xdelta", "vcdiff", "delta"].contains(ext) {
                try xdelta(patch: patch, rom: rom, output: output)
                return
            }
            let patchData = try Data(contentsOf: patch, options: .alwaysMapped)
            let source = try Data(contentsOf: rom, options: .alwaysMapped)
            let result: Data
            if patchData.starts(with: Array("PATCH".utf8)) {
                result = try ips(patchData, source)
            } else if patchData.starts(with: Array("UPS1".utf8)) {
                result = try ups(patchData, source)
            } else if patchData.starts(with: Array("BPS1".utf8)) {
                result = try bps(patchData, source)
            } else {
                throw Failure.unsupported
            }
            try? FileManager.default.removeItem(at: output)
            try result.write(to: output)
        }.value
    }

    private static func xdelta(patch: URL, rom: URL, output: URL) throws {
        guard let tool = EmulationHub.tools["xdelta3"] ?? nil else { throw Failure.toolMissing }
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-d", "-f", "-s", rom.path, patch.path, output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            if message.contains("checksum") || message.contains("source") { throw Failure.wrongGame }
            throw Failure.toolFailed(message.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "xdelta3: ", with: "") } ?? "")
        }
    }

    static func ips(_ patch: Data, _ source: Data) throws -> Data {
        let p = [UInt8](patch)
        var out = [UInt8](source)
        var i = 5
        func need(_ n: Int) throws { if i + n > p.count { throw Failure.damaged("ends early") } }
        while true {
            try need(3)
            if p[i] == 0x45, p[i + 1] == 0x4F, p[i + 2] == 0x46 {
                i += 3
                if i + 3 <= p.count {
                    let truncate = Int(p[i]) << 16 | Int(p[i + 1]) << 8 | Int(p[i + 2])
                    if truncate < out.count { out.removeSubrange(truncate...) }
                }
                break
            }
            let offset = Int(p[i]) << 16 | Int(p[i + 1]) << 8 | Int(p[i + 2])
            i += 3
            try need(2)
            let size = Int(p[i]) << 8 | Int(p[i + 1])
            i += 2
            if size == 0 {
                try need(3)
                let count = Int(p[i]) << 8 | Int(p[i + 1])
                let value = p[i + 2]
                i += 3
                if out.count < offset + count { out += [UInt8](repeating: 0, count: offset + count - out.count) }
                for k in 0..<count { out[offset + k] = value }
            } else {
                try need(size)
                if out.count < offset + size { out += [UInt8](repeating: 0, count: offset + size - out.count) }
                for k in 0..<size { out[offset + k] = p[i + k] }
                i += size
            }
        }
        return Data(out)
    }

    private static func varint(_ p: [UInt8], _ i: inout Int, limit: Int) throws -> Int {
        var data = 0
        var shift = 1
        while true {
            guard i < limit else { throw Failure.damaged("ends early") }
            let x = Int(p[i])
            i += 1
            data += (x & 0x7F) * shift
            if x & 0x80 != 0 { break }
            shift <<= 7
            data += shift
        }
        return data
    }

    private static func readCRC(_ p: [UInt8], _ at: Int) -> UInt32 {
        UInt32(p[at]) | UInt32(p[at + 1]) << 8 | UInt32(p[at + 2]) << 16 | UInt32(p[at + 3]) << 24
    }

    static func ups(_ patch: Data, _ source: Data) throws -> Data {
        let p = [UInt8](patch)
        guard p.count >= 16 else { throw Failure.damaged("too short") }
        let footer = p.count - 12
        guard CRC32.checksum(p[0..<(p.count - 4)]) == readCRC(p, p.count - 4) else { throw Failure.damaged("checksum") }
        var i = 4
        let inputSize = try varint(p, &i, limit: footer)
        let outputSize = try varint(p, &i, limit: footer)
        let src = [UInt8](source)
        let sourceCRC = CRC32.checksum(src[...])
        guard src.count == inputSize, sourceCRC == readCRC(p, footer) else { throw Failure.wrongGame }
        var out = [UInt8](repeating: 0, count: outputSize)
        for k in 0..<min(src.count, outputSize) { out[k] = src[k] }
        var pos = 0
        while i < footer {
            pos += try varint(p, &i, limit: footer)
            while i < footer {
                let x = p[i]
                i += 1
                if x == 0 { pos += 1; break }
                if pos < outputSize { out[pos] ^= x }
                pos += 1
            }
        }
        guard CRC32.checksum(out[...]) == readCRC(p, footer + 4) else { throw Failure.wrongGame }
        return Data(out)
    }

    static func bps(_ patch: Data, _ source: Data) throws -> Data {
        let p = [UInt8](patch)
        guard p.count >= 16 else { throw Failure.damaged("too short") }
        let footer = p.count - 12
        guard CRC32.checksum(p[0..<(p.count - 4)]) == readCRC(p, p.count - 4) else { throw Failure.damaged("checksum") }
        var i = 4
        let sourceSize = try varint(p, &i, limit: footer)
        let targetSize = try varint(p, &i, limit: footer)
        let metadataSize = try varint(p, &i, limit: footer)
        i += metadataSize
        let src = [UInt8](source)
        guard src.count == sourceSize, CRC32.checksum(src[...]) == readCRC(p, footer) else { throw Failure.wrongGame }
        var out = [UInt8](repeating: 0, count: targetSize)
        var outOffset = 0
        var sourceRelative = 0
        var targetRelative = 0
        while i < footer {
            let data = try varint(p, &i, limit: footer)
            let command = data & 3
            let length = (data >> 2) + 1
            guard outOffset + length <= targetSize else { throw Failure.damaged("writes past the end") }
            switch command {
            case 0:
                guard outOffset + length <= src.count else { throw Failure.damaged("reads past the source") }
                for k in 0..<length { out[outOffset + k] = src[outOffset + k] }
            case 1:
                guard i + length <= footer else { throw Failure.damaged("ends early") }
                for k in 0..<length { out[outOffset + k] = p[i + k] }
                i += length
            case 2:
                let offset = try varint(p, &i, limit: footer)
                sourceRelative += (offset & 1 != 0 ? -1 : 1) * (offset >> 1)
                guard sourceRelative >= 0, sourceRelative + length <= src.count else { throw Failure.damaged("reads past the source") }
                for k in 0..<length { out[outOffset + k] = src[sourceRelative + k] }
                sourceRelative += length
            default:
                let offset = try varint(p, &i, limit: footer)
                targetRelative += (offset & 1 != 0 ? -1 : 1) * (offset >> 1)
                guard targetRelative >= 0 else { throw Failure.damaged("bad copy") }
                for k in 0..<length {
                    out[outOffset + k] = out[targetRelative]
                    targetRelative += 1
                }
            }
            outOffset += length
        }
        guard CRC32.checksum(out[...]) == readCRC(p, footer + 4) else { throw Failure.damaged("result checksum") }
        return Data(out)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
