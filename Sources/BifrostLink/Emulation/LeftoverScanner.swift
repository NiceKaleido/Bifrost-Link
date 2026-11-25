import Foundation
import CommonCrypto

/// A save, save state or shader cache that belongs to a game no longer on the device.
struct LeftoverItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case save = "save", state = "save state", cache = "shader cache" }
    let emulator: String
    let package: String?
    let kind: Kind
    /// Groups one emulator's files for one game (a file name, PSP/GameCube game ID or Switch title ID).
    let gameKey: String
    var game: String
    let path: String
    var bytes: Int64 = 0
    var id: String { path }
}

struct LeftoverGame: Identifiable, Hashable {
    let emulator: String
    let game: String
    let items: [LeftoverItem]
    var id: String { emulator + "|" + (items.first?.gameKey ?? game) }
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var kinds: String {
        LeftoverItem.Kind.allCases.filter { kind in items.contains { $0.kind == kind } }.map(\.rawValue).joined(separator: ", ")
    }

    static func group(_ items: [LeftoverItem]) -> [LeftoverGame] {
        Dictionary(grouping: items) { $0.emulator + "|" + $0.gameKey }.values.map { list in
            LeftoverGame(emulator: list[0].emulator, game: list.first { !$0.game.isEmpty }?.game ?? list[0].gameKey, items: list)
        }
        .sorted { ($0.emulator, $1.bytes) < ($1.emulator, $0.bytes) }
    }
}

/// Finds per-game emulator data whose game is gone. Anything it can't tie to a game with confidence is kept:
/// name matches are lenient, and ID-based emulators are only checked when every game's ID could be read.
enum LeftoverScanner {
    struct Result {
        var items: [LeftoverItem] = []
        /// Emulators that couldn't be checked, and why.
        var notes: [String] = []
    }

    private static let data = Emulators.data

    static func scan(serial: String) async -> Result {
        let packages = ((try? await ADB.shared.shell("pm list packages", serial: serial, timeout: 15)) ?? "")
        let installed = Set(packages.split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        let library = await Library.load(serial: serial)
        guard !library.files.isEmpty else { return Result(notes: ["No Roms folder found, so nothing could be compared."]) }

        var result = Result()
        result.items += library.romFolderSaves()
        if installed.contains("com.retroarch") { result.items += await retroArch(library, serial: serial) }
        if installed.contains("me.magnum.melondualds") { result.items += await melonDS(library, serial: serial) }
        if installed.contains("org.ppsspp.ppsspp") { result.items += await ppsspp(library, serial: serial) }
        if installed.contains("org.dolphinemu.dolphinemu") { await dolphin(library, serial: serial, into: &result) }
        let edens = Emulators.all.filter { $0.id.hasPrefix("eden") && installed.contains($0.package) }
        if !edens.isEmpty { await eden(edens, library, serial: serial, into: &result) }
        if installed.contains("com.github.stenzek.duckstation") {
            result.notes.append("DuckStation keeps its memory cards and save states private, so they can’t be checked.")
        }

        let sizes = await sizes(result.items.map(\.path), serial: serial)
        result.items = result.items.compactMap { item in
            guard let bytes = sizes[item.path] else { return nil }
            var item = item
            item.bytes = bytes
            return item
        }
        return result
    }

    // MARK: - The library

    struct Library {
        struct Entry { let system: String; let path: String; let size: Int64; let isDir: Bool }
        var files: [Entry] = []
        private var names: Set<String> = []
        private var titles: [Set<String>] = []

        static let saveExtensions = #"(?i)\.(sav|srm|dsv|rtc|ml\d)$"#
        private static let ignored: Set<String> = ["txt", "xml", "nfo", "cfg", "ini", "jpg", "jpeg", "png", "json", "db", "log", "bak", "tmp"]

        static func load(serial: String) async -> Library {
            let roots = "/sdcard/Roms /storage/*/Roms /sdcard/multi_disc_roms /storage/*/multi_disc_roms"
            let command = "for d in \(roots); do [ -d \"$d\" ] && find \"$d\" -mindepth 2 -maxdepth 3 ! -name '.*' -exec stat -c '%s|%F|%n' {} + 2>/dev/null; done; true"
            let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 60)) ?? ""
            var library = Library()
            var seen = Set<String>()
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count == 3, let size = Int64(parts[0]) else { continue }
                // /storage/emulated/0 and /sdcard are the same place.
                let path = parts[2].replacingOccurrences(of: "/storage/emulated/0/", with: "/sdcard/")
                guard seen.insert(path).inserted else { continue }
                let components = path.split(separator: "/").map(String.init)
                guard let root = components.firstIndex(where: { $0 == "Roms" || $0 == "multi_disc_roms" }), root + 1 < components.count else { continue }
                let entry = Entry(system: components[root + 1].lowercased(), path: path, size: size, isDir: parts[1] == "directory")
                library.files.append(entry)
                let name = (path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                if Self.ignored.contains(ext) || name.range(of: saveExtensions, options: .regularExpression) != nil { continue }
                let base = entry.isDir ? name : (name as NSString).deletingPathExtension
                library.names.insert(base.lowercased())
                let tokens = LeftoverScanner.tokens(base, stripBrackets: true)
                if !tokens.isEmpty { library.titles.append(tokens) }
            }
            return library
        }

        /// Whether a game with this name or title is still around. Unknown (empty) titles count as present.
        func has(_ title: String) -> Bool {
            if names.contains(title.lowercased()) { return true }
            let variants = [LeftoverScanner.tokens(title, stripBrackets: true), LeftoverScanner.tokens(title, stripBrackets: false)].filter { !$0.isEmpty }
            guard !variants.isEmpty else { return true }
            return variants.contains { variant in titles.contains { variant.isSubset(of: $0) || $0.isSubset(of: variant) } }
        }

        func entries(in systems: Set<String>) -> [Entry] { files.filter { systems.contains($0.system) } }

        /// .sav/.srm files next to ROMs (melonDS and RetroArch can keep saves there) whose ROM is gone.
        func romFolderSaves() -> [LeftoverItem] {
            files.compactMap { entry in
                let name = (entry.path as NSString).lastPathComponent
                guard !entry.isDir, name.range(of: Self.saveExtensions, options: .regularExpression) != nil else { return nil }
                let base = (name as NSString).deletingPathExtension
                guard !has(base) else { return nil }
                return LeftoverItem(emulator: "\(Systems.name(for: entry.system)) folder", package: nil, kind: .save, gameKey: base.lowercased(), game: base, path: entry.path)
            }
        }
    }

    /// Words of a game name, for matching "Legend of Spyro, The - A New Beginning (Europe)" to "The Legend of Spyro: A New Beginning".
    static func tokens(_ name: String, stripBrackets: Bool) -> Set<String> {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if stripBrackets { s = s.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression) }
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: #"\b(disc|disk|cd)\s*\d+"#, with: " ", options: .regularExpression)
        return Set(s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0 != "the" })
    }

    // MARK: - Name-based emulators

    private static let raPattern = #"(?i)\.(srm|rtc|sav|state\d*|state\.auto)(\.png)?$"#

    private static func retroArch(_ library: Library, serial: String) async -> [LeftoverItem] {
        let dirs = ["\(data)/com.retroarch/files/RetroArch", "/sdcard/RetroArch"].flatMap { ["\($0)/saves", "\($0)/states"] }
        return await files(in: dirs, depth: 2, serial: serial).compactMap { path in
            let name = (path as NSString).lastPathComponent
            guard let suffix = name.range(of: raPattern, options: .regularExpression) else { return nil }
            let base = String(name[..<suffix.lowerBound])
            guard !base.isEmpty, !library.has(base) else { return nil }
            let kind: LeftoverItem.Kind = name[suffix].lowercased().contains("state") ? .state : .save
            return LeftoverItem(emulator: "RetroArch", package: "com.retroarch", kind: kind, gameKey: base.lowercased(), game: base, path: path)
        }
    }

    private static func melonDS(_ library: Library, serial: String) async -> [LeftoverItem] {
        await files(in: ["\(data)/me.magnum.melondualds/files/saves"], depth: 1, serial: serial).compactMap { path in
            let name = (path as NSString).lastPathComponent
            guard name.range(of: Library.saveExtensions, options: .regularExpression) != nil else { return nil }
            let base = (name as NSString).deletingPathExtension
            guard !library.has(base) else { return nil }
            return LeftoverItem(emulator: "melonDS", package: "me.magnum.melondualds", kind: .save, gameKey: base.lowercased(), game: base, path: path)
        }
    }

    // MARK: - PPSSPP (game IDs, titles from the saves themselves)

    private static func ppsspp(_ library: Library, serial: String) async -> [LeftoverItem] {
        let package = "org.ppsspp.ppsspp"
        let roots = ["\(data)/\(package)/files/PSP", "/sdcard/PSP"]
        var titles: [String: String] = [:]
        let saves = await directories(in: roots.map { "\($0)/SAVEDATA" }, serial: serial)
        for dir in saves {
            let id = String((dir as NSString).lastPathComponent.prefix(9))
            guard titles[id] == nil, let sfo = await ADB.shared.data("cat \(ADB.quote(dir + "/PARAM.SFO")) 2>/dev/null", serial: serial, timeout: 5),
                  let title = SFO.value(sfo, key: "TITLE") else { continue }
            titles[id] = title
        }
        let states = await files(in: roots.map { "\($0)/PPSSPP_STATE" }, depth: 1, serial: serial)
        for path in states where path.hasSuffix(".ppst") {
            let id = stateID(path)
            guard titles[id] == nil, let head = await ADB.shared.data("head -c 176 \(ADB.quote(path))", serial: serial, timeout: 5), head.count > 0x30 else { continue }
            let raw = head[0x30...].prefix { $0 != 0 }
            let title = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { titles[id] = title }
        }
        func item(_ path: String, id: String, kind: LeftoverItem.Kind) -> LeftoverItem? {
            guard let title = titles[id], !library.has(title) else { return nil }
            return LeftoverItem(emulator: "PPSSPP", package: package, kind: kind, gameKey: id, game: title, path: path)
        }
        return saves.compactMap { item($0, id: String(($0 as NSString).lastPathComponent.prefix(9)), kind: .save) }
            + states.compactMap { item($0, id: stateID($0), kind: .state) }
    }

    /// "UCES00842_1.00_0.ppst" → "UCES00842"
    private static func stateID(_ path: String) -> String {
        String((path as NSString).lastPathComponent.split(separator: "_").first ?? "")
    }

    // MARK: - Dolphin (6-character game IDs read from the discs)

    private static func dolphin(_ library: Library, serial: String, into result: inout Result) async {
        let package = "org.dolphinemu.dolphinemu"
        let base = "\(data)/\(package)"
        let offsets: [String: Int] = ["iso": 0, "gcm": 0, "rvz": 0x58, "wia": 0x58, "wbfs": 0x200, "ciso": 0x8000]
        let discs = library.entries(in: ["gc", "gamecube", "ngc", "wii"]).filter { !$0.isDir && ["iso", "gcm", "rvz", "wia", "wbfs", "ciso", "gcz"].contains(($0.path as NSString).pathExtension.lowercased()) }
        if let unreadable = discs.first(where: { offsets[($0.path as NSString).pathExtension.lowercased()] == nil }) {
            result.notes.append("Dolphin wasn’t checked: the game ID of \((unreadable.path as NSString).lastPathComponent) can’t be read (GCZ). Converting it to RVZ fixes that.")
            return
        }
        let script = discs.map { disc in
            "printf '%s|' \(ADB.quote(disc.path)); dd if=\(ADB.quote(disc.path)) bs=1 skip=\(offsets[(disc.path as NSString).pathExtension.lowercased()] ?? 0) count=6 2>/dev/null; echo"
        }.joined(separator: "; ")
        let out = discs.isEmpty ? "" : ((try? await ADB.shared.shell(script, serial: serial, timeout: 60)) ?? "")
        var present = Set<String>()
        var read = 0
        for line in out.split(separator: "\n") {
            let id = String(line.split(separator: "|").last ?? "")
            if isGameID(id, length: 6) { present.insert(id); read += 1 }
        }
        guard read == discs.count else {
            result.notes.append("Dolphin wasn’t checked: not every game ID could be read.")
            return
        }
        // Dolphin's own game list also counts, for games kept outside the Roms folders.
        if let cache = await ADB.shared.data("cat \(ADB.quote(base + "/cache/gamelist.cache")) 2>/dev/null", serial: serial, timeout: 15) {
            present.formUnion(lengthPrefixedIDs(cache))
        }
        let present4 = Set(present.map { String($0.prefix(4)) })

        var items: [LeftoverItem] = []
        var names: [String: String] = [:]
        for path in await files(in: ["\(base)/files/GC"], depth: 3, serial: serial) where path.lowercased().hasSuffix(".gci") {
            let parts = (path as NSString).lastPathComponent.split(separator: "-", maxSplits: 2).map(String.init)
            guard parts.count == 3, isGameID(parts[1], length: 4), !present4.contains(parts[1]) else { continue }
            if names[parts[1]] == nil { names[parts[1]] = await gciTitle(path, serial: serial) }
            items.append(LeftoverItem(emulator: "Dolphin", package: package, kind: .save, gameKey: parts[1], game: "", path: path))
        }
        for path in await files(in: ["\(base)/files/StateSaves"], depth: 1, serial: serial) {
            let id = String((path as NSString).lastPathComponent.prefix(6))
            guard isGameID(id, length: 6), !present.contains(id) else { continue }
            items.append(LeftoverItem(emulator: "Dolphin", package: package, kind: .state, gameKey: String(id.prefix(4)), game: "", path: path))
        }
        for path in await files(in: ["\(base)/cache"], depth: 2, serial: serial) {
            let name = (path as NSString).lastPathComponent
            let id: String
            if name.hasSuffix(".uidcache") {
                id = (name as NSString).deletingPathExtension
            } else if let match = name.range(of: #"-[A-Z0-9]{6}-[0-9A-F]+\.cache$"#, options: .regularExpression) {
                id = String(name[match].dropFirst().prefix(6))
            } else { continue }
            guard isGameID(id, length: 6), !present.contains(id) else { continue }
            items.append(LeftoverItem(emulator: "Dolphin", package: package, kind: .cache, gameKey: String(id.prefix(4)), game: "", path: path))
        }
        // Wii disc games keep their saves under title/00010000/<game ID as hex>.
        for dir in await directories(in: ["\(base)/files/Wii/title/00010000"], serial: serial) {
            let hex = (dir as NSString).lastPathComponent
            guard hex.count == 8, let value = UInt32(hex, radix: 16) else { continue }
            let id = String(decoding: withUnsafeBytes(of: value.bigEndian) { Data($0) }, as: UTF8.self)
            guard isGameID(id, length: 4), !present4.contains(id) else { continue }
            items.append(LeftoverItem(emulator: "Dolphin", package: package, kind: .save, gameKey: id, game: "", path: dir))
        }
        result.items += items.map { item in
            var item = item
            item.game = names[item.gameKey].map { "\($0) (\(item.gameKey))" } ?? "Game \(item.gameKey)"
            return item
        }
    }

    private static func isGameID(_ id: String, length: Int) -> Bool {
        id.count == length && id.allSatisfy { ($0.isASCII && $0.isUppercase) || $0.isNumber }
    }

    /// Game IDs stored as length-prefixed strings in Dolphin's gamelist.cache.
    private static func lengthPrefixedIDs(_ data: Data) -> Set<String> {
        var ids = Set<String>()
        let bytes = [UInt8](data)
        var i = 0
        while i + 10 <= bytes.count {
            if bytes[i] == 6, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 0 {
                let id = String(decoding: bytes[(i + 4)..<(i + 10)], as: UTF8.self)
                if isGameID(id, length: 6) { ids.insert(id); i += 10; continue }
            }
            i += 1
        }
        return ids
    }

    /// The game name a GameCube save carries in its comment ("Zelda: The Wind Waker").
    private static func gciTitle(_ path: String, serial: String) async -> String? {
        guard let header = await ADB.shared.data("head -c 64 \(ADB.quote(path))", serial: serial, timeout: 5), header.count == 64 else { return nil }
        let offset = 0x40 + (Int(header[0x3C]) << 24 | Int(header[0x3D]) << 16 | Int(header[0x3E]) << 8 | Int(header[0x3F]))
        guard let comment = await ADB.shared.data("tail -c +\(offset + 1) \(ADB.quote(path)) | head -c 32", serial: serial, timeout: 5) else { return nil }
        let raw = comment.prefix { $0 != 0 }
        let title = (String(data: raw, encoding: .ascii) ?? String(data: raw, encoding: .shiftJIS) ?? "").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    // MARK: - Eden (Switch title IDs)

    private static var titleIDCache: [String: UInt64] = [:]

    private static func eden(_ profiles: [EmulatorProfile], _ library: Library, serial: String, into result: inout Result) async {
        var present = Set<UInt64>()
        var unknown: [Library.Entry] = []
        for entry in library.entries(in: ["switch", "nsw"]) {
            if let id = titleID(in: entry.path) { present.insert(baseID(id)); continue }
            let ext = (entry.path as NSString).pathExtension.lowercased()
            if !entry.isDir, ["nsp", "nsz", "xci", "xcz"].contains(ext) { unknown.append(entry) }
        }
        var key: Data?
        for profile in profiles where key == nil {
            let line = (try? await ADB.shared.shell("grep '^header_key ' \(ADB.quote("\(data)/\(profile.package)/files/keys/prod.keys")) 2>/dev/null", serial: serial, timeout: 5)) ?? ""
            key = hexData(line.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        for entry in unknown {
            let cacheKey = "\(entry.path)|\(entry.size)"
            if let id = titleIDCache[cacheKey] { present.insert(baseID(id)); continue }
            guard let key, let id = await NintendoContainer.titleID(path: entry.path, key: key, serial: serial) else {
                result.notes.append("Switch games weren’t checked: the title of \((entry.path as NSString).lastPathComponent) couldn’t be read\(key == nil ? " (no prod.keys in Eden)" : "").")
                return
            }
            titleIDCache[cacheKey] = id
            present.insert(baseID(id))
        }
        for profile in profiles {
            let root = "\(data)/\(profile.package)/files"
            // Games installed into Eden's own storage count too.
            let installed = (try? await ADB.shared.shell("find \(ADB.quote(root + "/nand/user/Contents/registered")) -name '*.nca' 2>/dev/null", serial: serial, timeout: 20)) ?? ""
            for path in installed.split(separator: "\n").map(String.init) {
                if let key, let id = await NintendoContainer.ncaTitleID(path: path, key: key, serial: serial) { present.insert(baseID(id)) }
            }
        }
        for profile in profiles {
            let root = "\(data)/\(profile.package)/files"
            let saves = await directories(in: ["\(root)/nand/user/save/0000000000000000"], depth: 2, serial: serial)
            let shaders = await directories(in: ["\(root)/cache/shader"], serial: serial)
            for (paths, kind) in [(saves, LeftoverItem.Kind.save), (shaders, .cache)] {
                for path in paths {
                    let name = (path as NSString).lastPathComponent
                    // System titles (below 0100000000010000) belong to the console, not a game.
                    guard name.count == 16, let id = UInt64(name, radix: 16), id >= 0x0100_0000_0001_0000, !present.contains(baseID(id)) else { continue }
                    let tid = String(format: "%016llX", id)
                    result.items.append(LeftoverItem(emulator: profile.name, package: profile.package, kind: kind, gameKey: tid, game: "Switch game \(tid)", path: path))
                }
            }
        }
    }

    /// Updates (…800) and DLC (…1xxx) share the base game's ID with the low 13 bits cleared.
    private static func baseID(_ id: UInt64) -> UInt64 { id & ~0x1FFF }

    private static func titleID(in path: String) -> UInt64? {
        guard let range = path.range(of: #"(?i)0100[0-9a-f]{12}"#, options: .regularExpression) else { return nil }
        return UInt64(path[range], radix: 16)
    }

    private static func hexData(_ hex: String) -> Data? {
        guard hex.count == 64 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Shell helpers

    private static func files(in dirs: [String], depth: Int, serial: String) async -> [String] {
        let command = dirs.map { "find \(ADB.quote($0)) -maxdepth \(depth) -type f ! -name '.*' 2>/dev/null" }.joined(separator: "; ") + "; true"
        return ((try? await ADB.shared.shell(command, serial: serial, timeout: 60)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func directories(in dirs: [String], depth: Int = 1, serial: String) async -> [String] {
        let command = dirs.map { "find \(ADB.quote($0)) -mindepth \(depth) -maxdepth \(depth) -type d 2>/dev/null" }.joined(separator: "; ") + "; true"
        return ((try? await ADB.shared.shell(command, serial: serial, timeout: 60)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func sizes(_ paths: [String], serial: String) async -> [String: Int64] {
        var result: [String: Int64] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 80).map({ Array(paths[$0..<min($0 + 80, paths.count)]) }) {
            let command = chunk.map { "echo \"$(du -sk \(ADB.quote($0)) 2>/dev/null | cut -f1)|\"\(ADB.quote($0))" }.joined(separator: "; ")
            let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 60)) ?? ""
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                if parts.count == 2, let kb = Int64(parts[0]) { result[String(parts[1])] = kb * 1024 }
            }
        }
        return result
    }
}

/// Reads a Switch game's title ID from its NSP/XCI: the first NCA's header, decrypted with Eden's header key.
enum NintendoContainer {
    static func titleID(path: String, key: Data, serial: String) async -> UInt64? {
        guard let head = await read(path, at: 0, count: 0x200, serial: serial), head.count >= 0x140 else { return nil }
        if head.prefix(4) == Data("PFS0".utf8) {
            guard let full = await read(path, at: 0, count: 0x4000, serial: serial), let offset = firstNCA(pfs0: full, base: 0) else { return nil }
            return await ncaTitleID(path: path, offset: offset, key: key, serial: serial)
        }
        if head[0x100..<0x104] == Data("HEAD".utf8) {
            let root = Int(u64(head, 0x130))
            guard let rootTable = await read(path, at: root, count: 0x1000, serial: serial),
                  let secure = hfs0Entry(rootTable, base: root, named: "secure"),
                  let secureTable = await read(path, at: secure, count: 0x4000, serial: serial),
                  let offset = hfs0Entry(secureTable, base: secure, suffix: ".nca") else { return nil }
            return await ncaTitleID(path: path, offset: offset, key: key, serial: serial)
        }
        return nil
    }

    /// An installed NCA: a file, or a folder of 00, 01… parts.
    static func ncaTitleID(path: String, key: Data, serial: String) async -> UInt64? {
        let isDir = ((try? await ADB.shared.shell("[ -d \(ADB.quote(path)) ] && echo d", serial: serial, timeout: 5)) ?? "").contains("d")
        return await ncaTitleID(path: isDir ? path + "/00" : path, offset: 0, key: key, serial: serial)
    }

    private static func ncaTitleID(path: String, offset: Int, key: Data, serial: String) async -> UInt64? {
        // The program ID sits at 0x210, in the header's second 0x200-byte sector.
        guard let sector = await read(path, at: offset + 0x200, count: 0x200, serial: serial), sector.count == 0x200,
              let plain = xtsDecrypt(sector, key: key, sector: 1), plain.prefix(3) == Data("NCA".utf8) else { return nil }
        return u64(plain, 0x10)
    }

    private static func read(_ path: String, at offset: Int, count: Int, serial: String) async -> Data? {
        await ADB.shared.data("tail -c +\(offset + 1) \(ADB.quote(path)) | head -c \(count)", serial: serial, timeout: 20)
    }

    private static func firstNCA(pfs0 d: Data, base: Int) -> Int? {
        let count = Int(u32(d, 4)), strings = Int(u32(d, 8))
        let table = 0x10 + 0x18 * count
        guard table + strings <= d.count else { return nil }
        for i in 0..<count {
            let entry = 0x10 + 0x18 * i
            let name = cString(d, table + Int(u32(d, entry + 16)))
            if name.hasSuffix(".nca") || name.hasSuffix(".ncz") { return base + table + strings + Int(u64(d, entry)) }
        }
        return nil
    }

    private static func hfs0Entry(_ d: Data, base: Int, named: String? = nil, suffix: String? = nil) -> Int? {
        guard d.count >= 0x10, d.prefix(4) == Data("HFS0".utf8) else { return nil }
        let count = Int(u32(d, 4)), strings = Int(u32(d, 8))
        let table = 0x10 + 0x40 * count
        guard table + strings <= d.count else { return nil }
        for i in 0..<count {
            let entry = 0x10 + 0x40 * i
            let name = cString(d, table + Int(u32(d, entry + 16)))
            if name == named || (suffix.map { name.hasSuffix($0) } ?? false) { return base + table + strings + Int(u64(d, entry)) }
        }
        return nil
    }

    /// AES-128-XTS with Nintendo's big-endian sector tweak, built from AES-ECB.
    static func xtsDecrypt(_ data: Data, key: Data, sector: UInt64) -> Data? {
        guard key.count == 32, data.count % 16 == 0 else { return nil }
        var tweakIn = Data(count: 8)
        tweakIn.append(contentsOf: withUnsafeBytes(of: sector.bigEndian) { Array($0) })
        guard var tweak = ecb(tweakIn, key: key.suffix(16), encrypt: true) else { return nil }
        var masked = Data(capacity: data.count)
        var tweaks: [Data] = []
        for block in stride(from: 0, to: data.count, by: 16) {
            tweaks.append(tweak)
            masked.append(contentsOf: zip(data[data.startIndex + block..<data.startIndex + block + 16], tweak).map { $0 ^ $1 })
            // Multiply the tweak by x in GF(2^128), little-endian.
            var carry: UInt8 = 0
            for i in 0..<16 {
                let byte = tweak[i]
                tweak[i] = (byte << 1) | carry
                carry = byte >> 7
            }
            if carry != 0 { tweak[0] ^= 0x87 }
        }
        guard let decrypted = ecb(masked, key: key.prefix(16), encrypt: false) else { return nil }
        var plain = Data(capacity: data.count)
        for (index, tweak) in tweaks.enumerated() {
            plain.append(contentsOf: zip(decrypted[index * 16..<index * 16 + 16], tweak).map { $0 ^ $1 })
        }
        return plain
    }

    private static func ecb(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                Data(key).withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, 16, nil, dataBytes.baseAddress, data.count, outBytes.baseAddress, data.count, &moved)
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * $1) }
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * $1) }
    }

    private static func cString(_ d: Data, _ o: Int) -> String {
        guard o < d.count else { return "" }
        return String(decoding: d[(d.startIndex + o)...].prefix { $0 != 0 }, as: UTF8.self)
    }
}
