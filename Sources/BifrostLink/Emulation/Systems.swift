import Foundation

struct EmuSystem: Identifiable, Hashable {
    let id: String
    let name: String
    let extensions: Set<String>
    let bios: [BiosRequirement]

    struct BiosRequirement: Hashable {
        let label: String
        let patterns: [String]
        let required: Bool
    }
}

enum Systems {
    static let all: [EmuSystem] = [
        EmuSystem(id: "gb", name: "Game Boy", extensions: ["gb"], bios: []),
        EmuSystem(id: "gbc", name: "Game Boy Color", extensions: ["gbc"], bios: []),
        EmuSystem(id: "gba", name: "Game Boy Advance", extensions: ["gba"], bios: []),
        EmuSystem(id: "nds", name: "Nintendo DS", extensions: ["nds", "dsi"], bios: []),
        EmuSystem(id: "n3ds", name: "Nintendo 3DS", extensions: ["3ds", "cci", "cia", "cxi", "3dsx"], bios: []),
        EmuSystem(id: "nes", name: "NES", extensions: ["nes", "fds", "unf"], bios: []),
        EmuSystem(id: "snes", name: "Super Nintendo", extensions: ["sfc", "smc", "fig", "swc"], bios: []),
        EmuSystem(id: "n64", name: "Nintendo 64", extensions: ["z64", "n64", "v64"], bios: []),
        EmuSystem(id: "gc", name: "GameCube", extensions: ["rvz", "gcz", "gcm", "ciso", "dol", "tgc"], bios: [
            .init(label: "GameCube IPL (optional)", patterns: ["ipl.bin", "gc-ntsc", "gc-pal", "gc-dvd"], required: false),
        ]),
        EmuSystem(id: "wii", name: "Wii", extensions: ["wbfs", "wad", "wia"], bios: []),
        EmuSystem(id: "switch", name: "Nintendo Switch", extensions: ["nsp", "xci", "nca", "nro"], bios: []),
        EmuSystem(id: "genesis", name: "Sega Genesis / Mega Drive", extensions: ["md", "gen", "smd"], bios: []),
        EmuSystem(id: "mastersystem", name: "Sega Master System", extensions: ["sms"], bios: []),
        EmuSystem(id: "gamegear", name: "Sega Game Gear", extensions: ["gg"], bios: []),
        EmuSystem(id: "saturn", name: "Sega Saturn", extensions: [], bios: [
            .init(label: "Saturn BIOS", patterns: ["sega_101", "mpr-17933", "saturn"], required: true),
        ]),
        EmuSystem(id: "dreamcast", name: "Sega Dreamcast", extensions: ["gdi", "cdi"], bios: [
            .init(label: "Dreamcast boot ROM", patterns: ["dc_boot.bin"], required: true),
            .init(label: "Dreamcast flash", patterns: ["dc_flash.bin"], required: true),
        ]),
        EmuSystem(id: "psx", name: "PlayStation", extensions: ["pbp", "m3u", "ecm"], bios: [
            .init(label: "PlayStation BIOS", patterns: ["scph1001", "scph5501", "scph7001", "scph-1001", "psxonpsp", "ps1_rom"], required: true),
        ]),
        EmuSystem(id: "ps2", name: "PlayStation 2", extensions: [], bios: [
            .init(label: "PlayStation 2 BIOS", patterns: ["scph", "ps2-", "pcsx2"], required: true),
        ]),
        EmuSystem(id: "psp", name: "PlayStation Portable", extensions: ["cso", "pbp"], bios: []),
        EmuSystem(id: "xbox", name: "Xbox", extensions: ["xiso"], bios: [
            .init(label: "Xbox BIOS", patterns: ["xbox", "mcpx", "complex"], required: true),
        ]),
        EmuSystem(id: "arcade", name: "Arcade", extensions: [], bios: []),
        EmuSystem(id: "steam", name: "Steam / PC", extensions: ["steam"], bios: []),
        EmuSystem(id: "windows", name: "Windows", extensions: ["exe", "bat"], bios: []),
    ]

    static let ambiguous: [String: [String]] = [
        "iso": ["ps2", "psp", "gc", "wii", "xbox", "psx", "dreamcast"],
        "chd": ["psx", "ps2", "psp", "dreamcast", "saturn"],
        "cue": ["psx", "saturn", "dreamcast"],
        "bin": ["psx", "genesis", "saturn"],
        "img": ["psx"],
        "zip": ["arcade", "n64", "gba", "gb", "gbc", "nds", "snes", "genesis", "nes", "psp", "psx"],
        "7z": ["arcade", "n64", "gba", "gb", "gbc", "nds", "snes", "genesis", "nes", "psp", "psx"],
    ]

    static let romExtensions: Set<String> = Set(all.flatMap(\.extensions)).union(ambiguous.keys).subtracting(["exe", "bat", "steam"])

    private static var displayNames: [String: String] = [:]

    static func system(_ id: String) -> EmuSystem? {
        all.first { $0.id == id }
    }

    static func name(for id: String) -> String {
        displayNames[id] ?? system(id)?.name ?? id.uppercased()
    }

    static func loadDisplayNames(from text: String) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { displayNames[parts[0]] = parts[1] }
        }
    }

    static func candidates(forExtension ext: String) -> [String] {
        let lower = ext.lowercased()
        if let list = ambiguous[lower] { return list }
        return all.filter { $0.extensions.contains(lower) }.map(\.id)
    }

    static func isRom(_ filename: String) -> Bool {
        romExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    static func detect(localFile url: URL) -> (candidates: [String], sniffed: String?) {
        var candidates = Self.candidates(forExtension: url.pathExtension.lowercased())
        guard candidates.count > 1, let sniffed = sniff(localFile: url) else { return (candidates, nil) }
        candidates.removeAll { $0 == sniffed }
        candidates.insert(sniffed, at: 0)
        return (candidates, sniffed)
    }

    static func sniff(localFile url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "iso": return sniffISO(url)
        case "chd": return sniffCHD(url)
        default: return nil
        }
    }

    private static func sniffCHD(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x40), header.count >= 0x38,
              String(decoding: header.prefix(8), as: UTF8.self) == "MComprHD" else { return nil }
        let metaOffset = header[0x30..<0x38].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        try? handle.seek(toOffset: metaOffset)
        let tag = (try? handle.read(upToCount: 4)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if tag == "CHGD" { return "dreamcast" }
        let text = chdHeaderText(url)
        if text.contains("PSP GAME") || text.contains("UMD_DATA") { return "psp" }
        if text.contains("SEGA SEGASATURN") { return "saturn" }
        if text.contains("SEGA SEGAKATANA") { return "dreamcast" }
        if tag == "DVD " { return text.contains("PSP") ? "psp" : "ps2" }
        if text.contains("BOOT2") { return "ps2" }
        if text.contains("PLAYSTATION") || tag.hasPrefix("CHT") { return "psx" }
        return nil
    }

    private static func chdHeaderText(_ url: URL) -> String {
        guard let tool = EmulationHub.tools["chdman"].flatMap({ $0 }) else { return "" }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-sniff-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["extractraw", "-i", url.path, "-o", out.path, "-isb", "0", "-ib", "65536", "-f"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        guard let data = try? Data(contentsOf: out) else { return "" }
        return String(decoding: data.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x20 }, as: UTF8.self)
    }

    private static func sniffISO(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x20) , header.count >= 0x20 else { return nil }
        let gcMagic: [UInt8] = [0xC2, 0x33, 0x9F, 0x3D]
        let wiiMagic: [UInt8] = [0x5D, 0x1C, 0x9E, 0xA3]
        if Array(header[0x1C..<0x20]) == gcMagic { return "gc" }
        if Array(header[0x18..<0x1C]) == wiiMagic { return "wii" }
        try? handle.seek(toOffset: 0x8000)
        guard let pvd = try? handle.read(upToCount: 0x800), pvd.count > 0x50 else { return nil }
        let text = String(decoding: pvd.prefix(0x400), as: UTF8.self)
        if text.contains("PSP GAME") || text.contains("UMD") { return "psp" }
        if text.contains("PLAYSTATION") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 750_000_000 ? "ps2" : "psx"
        }
        if text.contains("XBOX") { return "xbox" }
        return nil
    }
}

struct RomFolder: Hashable {
    let system: String
    let path: String
}

enum RomLocator {
    static func folders(serial: String) async -> [String: RomFolder] {
        let out = (try? await ADB.shared.shell("for d in /sdcard/Roms/*/ /storage/*/Roms/*/; do [ -d \"$d\" ] && echo \"$d\"; done 2>/dev/null; for f in /storage/*/Roms/systems.txt /sdcard/Roms/systems.txt; do [ -f \"$f\" ] && echo \"SYSTEMS:$f\"; done", serial: serial, timeout: 15)) ?? ""
        var result: [String: RomFolder] = [:]
        var systemsFile: String?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SYSTEMS:") {
                systemsFile = String(line.dropFirst("SYSTEMS:".count))
                continue
            }
            guard !line.contains("/emulated/") else { continue }
            let trimmed = line.hasSuffix("/") ? String(line.dropLast()) : line
            let id = (trimmed as NSString).lastPathComponent
            if result[id] == nil { result[id] = RomFolder(system: id, path: trimmed) }
        }
        if let systemsFile, let text = try? await ADB.shared.shell("cat \(ADB.quote(systemsFile))", serial: serial, timeout: 10) {
            Systems.loadDisplayNames(from: text)
        }
        return result
    }

    static func defaultRoot(serial: String, volumes: [FileService.Place]) -> String {
        if let sd = volumes.first { return sd.path + "/Roms" }
        return "/sdcard/Roms"
    }
}
