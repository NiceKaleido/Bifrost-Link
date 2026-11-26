import Foundation
import AppKit

/// A 32×32 icon as RGBA pixels, read out of a ROM.
struct IconImage {
    static let size = 32
    var rgba: [UInt8]   // size × size × 4

    var image: NSImage {
        var pixels = rgba
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Self.size, pixelsHigh: Self.size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: Self.size * 4, bitsPerPixel: 32)!
        pixels.withUnsafeMutableBytes { raw in rep.bitmapData!.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count) }
        let image = NSImage(size: NSSize(width: Self.size, height: Self.size))
        image.addRepresentation(rep)
        return image
    }

    var png: Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Decodes the first 32×32 frame of 4bpp tiles laid out `tilesWide` tiles per row.
    static func from4bpp(_ d: [UInt8], at offset: Int, palette: [UInt16], tilesWide: Int = 4) -> IconImage? {
        guard offset >= 0, offset + 512 <= d.count, palette.count >= 16 else { return nil }
        var out = [UInt8](repeating: 0, count: size * size * 4)
        for tile in 0..<16 {
            let tx = tile % tilesWide, ty = tile / tilesWide
            guard ty < 4 else { break }
            for row in 0..<8 {
                for col in 0..<8 {
                    let byte = d[offset + tile * 32 + row * 4 + col / 2]
                    let index = Int(col % 2 == 0 ? byte & 0xF : byte >> 4)
                    guard index != 0 else { continue }
                    let c = palette[index]
                    let x = tx * 8 + col, y = ty * 8 + row
                    let p = (y * size + x) * 4
                    out[p] = UInt8((c & 0x1F) << 3 | (c & 0x1F) >> 2)
                    out[p + 1] = UInt8(((c >> 5) & 0x1F) << 3 | ((c >> 5) & 0x1F) >> 2)
                    out[p + 2] = UInt8(((c >> 10) & 0x1F) << 3 | ((c >> 10) & 0x1F) >> 2)
                    out[p + 3] = 255
                }
            }
        }
        return IconImage(rgba: out)
    }
}

/// Gen 3 (GBA) icons. Instead of fixed addresses per version, the ROM is searched for the icon pointer
/// table (hundreds of pointers spaced 0x400 apart), which is followed by the palette-index table and
/// then the palette list.
enum GBAIcons {
    static func extract(_ rom: [UInt8]) -> [Int: IconImage] {
        guard rom.count > 0x200000, let table = findIconTable(rom) else { return [:] }
        let count = table.count
        let indexTable = table.offset + count * 4
        guard indexTable + count < rom.count else { return [:] }
        let indexes = (0..<count).map { Int(rom[indexTable + $0]) }
        guard indexes.allSatisfy({ $0 < 6 }) else { return [:] }
        // Palette list: aligned to 4 after the index table, entries of (pointer, tag, padding).
        var paletteTable = (indexTable + count + 3) & ~3
        var palettes: [[UInt16]] = []
        for _ in 0..<64 where palettes.isEmpty {
            if let list = readPalettes(rom, at: paletteTable) { palettes = list } else { paletteTable += 4 }
        }
        guard !palettes.isEmpty else { return [:] }
        var icons: [Int: IconImage] = [:]
        for index in 1..<count {
            let pointer = Int(rom.u32(table.offset + index * 4) & 0x01FF_FFFF)
            let palette = palettes[min(indexes[index], palettes.count - 1)]
            guard let icon = IconImage.from4bpp(rom, at: pointer, palette: palette) else { continue }
            let national = PK3.internalToNational(index)
            if national > 0 && national <= 386 && icons[national] == nil { icons[national] = icon }
            if index >= 413 && index <= 439 { icons[10_000 + 201 * 32 + (index - 412)] = icon }  // Unown B…?
        }
        return icons
    }

    private static func isPointer(_ v: UInt32, romSize: Int) -> Bool {
        v & 0xFE00_0000 == 0x0800_0000 && Int(v & 0x01FF_FFFF) < romSize
    }

    /// The palette-index table starts like every Gen 3–5 game's: Bulbasaur line on palette 1,
    /// Charmander line on 0, Pikachu on 2. It directly follows the icon pointer table.
    static func looksLikePaletteTable(_ d: [UInt8], at o: Int, length: Int) -> Bool {
        guard o >= 0, o + length <= d.count, length > 26 else { return false }
        guard d[o + 1] == 1, d[o + 2] == 1, d[o + 3] == 1, d[o + 4] == 0, d[o + 5] == 0, d[o + 6] == 0, d[o + 25] == 2 else { return false }
        for i in 0..<length where d[o + i] > 5 { return false }
        return true
    }

    /// Finds the icon pointer table: a run of ≥ 412 ROM pointers followed by the palette-index table.
    static func findIconTable(_ rom: [UInt8]) -> (offset: Int, count: Int)? {
        var o = 4 * 412
        while o + 440 < rom.count {
            if rom[o + 1] == 1 && rom[o + 4] == 0 && looksLikePaletteTable(rom, at: o, length: 412) {
                var pointers = 0
                while pointers < 600 && o - (pointers + 1) * 4 >= 0 && isPointer(rom.u32(o - (pointers + 1) * 4), romSize: rom.count) { pointers += 1 }
                if pointers >= 412 {
                    var count = 412
                    while count < pointers && o + count < rom.count && rom[o + count] <= 5 { count += 1 }
                    return (offset: o - count * 4, count: count)
                }
            }
            o += 4
        }
        return nil
    }

    private static func readPalettes(_ rom: [UInt8], at offset: Int) -> [[UInt16]]? {
        var list: [[UInt16]] = []
        for i in 0..<3 {
            let entry = offset + i * 8
            guard entry + 8 <= rom.count, isPointer(rom.u32(entry), romSize: rom.count) else { return nil }
            let p = Int(rom.u32(entry) & 0x01FF_FFFF)
            guard p + 32 <= rom.count else { return nil }
            list.append((0..<16).map { UInt16(rom.u16(p + $0 * 2)) })
        }
        return list
    }
}

/// Gen 4/5 (DS) icons from the ROM's file system: a NARC with one palette file and one NCGR per species.
enum NDSIcons {
    struct NitroFS {
        let rom: [UInt8]
        private var paths: [String: Int] = [:]

        init?(_ rom: [UInt8]) {
            guard rom.count > 0x200 else { return nil }
            self.rom = rom
            let fnt = Int(rom.u32(0x40)), fntSize = Int(rom.u32(0x44))
            guard fnt > 0, fnt + fntSize <= rom.count else { return nil }
            walk(dir: 0xF000, prefix: "", fnt: fnt)
        }

        private mutating func walk(dir: Int, prefix: String, fnt: Int) {
            let entry = fnt + (dir & 0xFFF) * 8
            var o = fnt + Int(rom.u32(entry))
            var fileID = rom.u16(entry + 4)
            while o < rom.count {
                let head = Int(rom[o]); o += 1
                if head == 0 { break }
                let length = head & 0x7F
                guard o + length <= rom.count else { return }
                let name = String(bytes: rom[o..<(o + length)], encoding: .ascii) ?? ""
                o += length
                if head & 0x80 != 0 {
                    let sub = rom.u16(o); o += 2
                    walk(dir: sub, prefix: prefix + name + "/", fnt: fnt)
                } else {
                    paths[prefix + name] = fileID
                    fileID += 1
                }
            }
        }

        func file(_ path: String) -> [UInt8]? {
            guard let id = paths[path] else { return nil }
            let fat = Int(rom.u32(0x48)) + id * 8
            let start = Int(rom.u32(fat)), end = Int(rom.u32(fat + 4))
            guard start < end, end <= rom.count else { return nil }
            return Array(rom[start..<end])
        }

        var arm9: [UInt8] {
            let o = Int(rom.u32(0x20)), n = Int(rom.u32(0x2C))
            return o + n <= rom.count ? Array(rom[o..<(o + n)]) : []
        }
    }

    static func narcFiles(_ narc: [UInt8]) -> [[UInt8]] {
        guard narc.count > 0x1C, String(bytes: narc.prefix(4), encoding: .ascii) == "NARC" else { return [] }
        let btaf = 0x10
        let count = narc.u16(btaf + 8)
        let btnf = btaf + Int(narc.u32(btaf + 4))
        guard btnf + 8 <= narc.count else { return [] }
        let gmif = btnf + Int(narc.u32(btnf + 4))
        let base = gmif + 8
        return (0..<count).compactMap { i in
            let e = btaf + 12 + i * 8
            let s = base + Int(narc.u32(e)), t = base + Int(narc.u32(e + 4))
            return s <= t && t <= narc.count ? Array(narc[s..<t]) : nil
        }
    }

    static func palettes(fromNCLR d: [UInt8]) -> [[UInt16]] {
        guard d.count > 0x28, String(bytes: d.prefix(4), encoding: .ascii) == "RLCN" else { return [] }
        let ttlp = 0x10
        let size = Int(d.u32(ttlp + 0x10))
        let start = ttlp + 0x18
        let colors = min(size, d.count - start) / 2
        return stride(from: 0, to: colors - 15, by: 16).map { first in (0..<16).map { UInt16(d.u16(start + (first + $0) * 2)) } }
    }

    static func icon(fromNCGR d: [UInt8], palette: [UInt16]) -> IconImage? {
        guard d.count > 0x30, String(bytes: d.prefix(4), encoding: .ascii) == "RGCN" else { return nil }
        let rahc = 0x10
        let width = d.u16(rahc + 0x0A)
        let data = rahc + 0x20
        return IconImage.from4bpp(d, at: data, palette: palette, tilesWide: width == 0xFFFF || width == 0 ? 4 : min(width, 4))
    }

    /// Decompresses the DS "backwards LZ" used for arm9.bin.
    static func blz(_ input: [UInt8]) -> [UInt8] {
        guard input.count > 8 else { return input }
        let footer = input.count - 8
        let header = Int(input[footer + 3])
        let compressedLength = Int(input.u32(footer) & 0xFF_FFFF)
        let extra = Int(input.u32(footer + 4))
        guard compressedLength <= input.count, header >= 8 else { return input }
        var out = Array(input) + [UInt8](repeating: 0, count: extra)
        var src = input.count - header
        var dst = out.count
        let stop = input.count - compressedLength
        while src > stop {
            src -= 1
            let flags = out[src]
            for bit in 0..<8 {
                guard src > stop else { break }
                if flags & (0x80 >> bit) == 0 {
                    src -= 1; dst -= 1
                    out[dst] = out[src]
                } else {
                    src -= 2
                    let pair = Int(out[src]) | Int(out[src + 1]) << 8
                    let length = (pair >> 12) + 3
                    let displacement = (pair & 0xFFF) + 3
                    for _ in 0..<length {
                        dst -= 1
                        out[dst] = out[dst + displacement]
                    }
                }
            }
        }
        return out
    }

    /// The per-species palette-index table, found by its well-known start (see `GBAIcons`). Gen 4
    /// keeps it in the main code (compressed on Platinum/HGSS); Gen 5 hides it, so Gen 5 falls
    /// back to a table found in any Gen 4 ROM.
    static func paletteIndexes(rom: [UInt8], arm9: [UInt8], species: Int) -> [Int]? {
        for blob in [rom, blz(arm9)] {
            var o = 0
            while o + species < blob.count {
                if blob[o + 1] == 1 && blob[o + 4] == 0 && GBAIcons.looksLikePaletteTable(blob, at: o, length: species) {
                    return (0..<species).map { Int(blob[o + $0]) }
                }
                o += 1
            }
        }
        return nil
    }

    /// A palette table from another DS ROM (Gen 4 and 5 assign the same palettes up to #493).
    nonisolated(unsafe) static var fallbackPalettes: [Int]?
    /// The table found in the last ROM read (to hand on to Gen 5).
    nonisolated(unsafe) static var lastFound: [Int]?

    static func extract(_ rom: [UInt8]) -> [Int: IconImage] {
        guard let fs = NitroFS(rom) else { return [:] }
        let code = String(bytes: rom[0x0C..<0x0F], encoding: .ascii) ?? ""
        let gen5 = ["IRB", "IRA", "IRE", "IRD"].contains(code)
        let candidates = gen5 ? ["a/0/0/7"] : ["poketool/icongra/pl_poke_icon.narc", "poketool/icongra/poke_icon.narc", "a/0/2/0"]
        guard let narc = candidates.lazy.compactMap({ fs.file($0) }).first else { return [:] }
        let files = narcFiles(narc)
        guard let nclr = files.first(where: { String(bytes: $0.prefix(4), encoding: .ascii) == "RLCN" }) else { return [:] }
        let palettes = palettes(fromNCLR: nclr)
        guard !palettes.isEmpty else { return [:] }
        let maxSpecies = gen5 ? 649 : 493
        // Gen 5 hides its table (searching finds look-alikes with wrong colours), so it uses the Gen 4 one.
        let found = gen5 ? nil : paletteIndexes(rom: rom, arm9: fs.arm9, species: 494)
        lastFound = found
        let indexes = found ?? fallbackPalettes
        // Icons start after the palette/cell/animation files: species s sits at `first + s` (Gen 5: two per species).
        guard let first = files.firstIndex(where: { String(bytes: $0.prefix(4), encoding: .ascii) == "RGCN" }) else { return [:] }
        let stride = gen5 ? 2 : 1
        var icons: [Int: IconImage] = [:]
        for species in 1...maxSpecies {
            let index = first + species * stride
            guard index < files.count else { break }
            // Without a known palette the colours would be wrong; those species get a badge instead.
            guard let paletteIndex = indexes?[safe: species] else { continue }
            let palette = palettes[min(paletteIndex, palettes.count - 1)]
            if let icon = icon(fromNCGR: files[index], palette: palette) { icons[species] = icon }
        }
        return icons
    }
}
