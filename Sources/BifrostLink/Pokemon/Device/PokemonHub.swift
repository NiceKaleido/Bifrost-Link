import Foundation
import AppKit

/// A Pokémon save found on the device.
struct FoundSave: Identifiable, Hashable {
    let remote: String              // the main file
    let companions: [String]        // written alongside (BDSP Backup.bin, Peanuts .work copies)
    let source: String              // PokeDaisy, Peanuts Native, RetroArch …
    var romPath: String?
    var game: PKGame?
    var trainer = ""
    var modified: Date?
    var trainerID = 0
    var count = 0                   // Pokémon in party + boxes
    var error: String?
    var readOnly: String?
    var id: String { remote }
    var fileName: String { (remote as NSString).lastPathComponent }
    var title: String { game?.title ?? (fileName as NSString).deletingPathExtension }
}

/// One opened save with its pending changes.
@MainActor
final class OpenSave: ObservableObject, Identifiable {
    let found: FoundSave
    let file: SaveFile
    @Published private(set) var revision = 0
    @Published var dirty = false
    nonisolated var id: String { found.remote }

    init(found: FoundSave, file: SaveFile) {
        self.found = found
        self.file = file
    }

    func touch() { revision += 1; dirty = true }
    func saved() { revision += 1; dirty = false }
}

/// Finds Pokémon saves on the device, opens them, and writes changes back safely.
@MainActor
final class PokemonHub: ObservableObject {
    @Published private(set) var allSaves: [FoundSave] = []
    /// The saves shown in the tab (hidden ones left out).
    var saves: [FoundSave] { allSaves.filter { LinkSettings.shared.hiddenPokemonSaves[$0.id] == nil } }

    func hide(_ save: FoundSave) {
        LinkSettings.shared.hiddenPokemonSaves[save.id] = "\(save.title) · \(save.source) (\(save.fileName))"
        if selection == save.id { selection = saves.filter { $0.error == nil }.max { $0.count < $1.count }?.id }
        objectWillChange.send()
    }

    func unhide(_ id: String) {
        LinkSettings.shared.hiddenPokemonSaves[id] = nil
        objectWillChange.send()
    }
    @Published private(set) var opened: [String: OpenSave] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var busy: String?
    @Published private(set) var lastScan: Date?
    @Published var selection: String?
    /// What the scan is doing right now, with progress.
    @Published private(set) var phase: String?
    @Published private(set) var progress: Double?
    /// Box art per game from Cocoon / PokeDaisy on the device (cached on this Mac).
    @Published private(set) var art: [PKGame: NSImage] = [:]
    /// Pokémon ROMs on the device (icons are read from these).
    private(set) var roms: [String] = []

    var serial: String?
    var toast: ((String, String) -> Void)?
    weak var backups: SaveBackupService?
    /// Cocoon's data folder as found by the Library (set up by the user in Cocoon).
    var cocoonRoot: () async -> String? = { nil }
    let icons = IconCache()

    /// Writing to Peanuts Native saves (which keep `.work` copies and `.lock` files) stays off until
    /// a round trip has been confirmed on the device.
    static let peanutsWritesVerified = true

    static let cache: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bifrost Link/Pokemon/saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Game artwork

    private static let artCache: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bifrost Link/Pokemon/art", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        for game in PKGame.allCases {
            if let image = NSImage(contentsOf: Self.artCache.appendingPathComponent("\(game.rawValue).png")) { art[game] = image }
        }
    }

    /// A mainline Pokémon title ("Super Mario Land 2 - 6 Golden Coins" contains "gold" but isn't one).
    static func isPokemonTitle(_ name: String) -> Bool {
        name.range(of: #"(?i)pok[eé]mon"#, options: .regularExpression) != nil && !isSpinOff(name)
    }

    /// Spin-offs share words with the main games ("Pinball - Ruby & Sapphire"); they're skipped.
    static func isSpinOff(_ name: String) -> Bool {
        name.range(of: #"(?i)pinball|mystery dungeon|ranger|trozei|dash|card game|puzzle|stadium|snap|rumble|battle revolution|channel|conquest|pokepark|poképark|shuffle|picross"#, options: .regularExpression) != nil
    }

    /// Box art for the found games, in this order:
    /// 1. Peanuts Native games: the Cocoon shortcut icon for that title id
    /// 2. the box art chosen in Cocoon for the game's ROM (Cocoon's game lists)
    /// 3. any Cocoon icon/logo whose name matches the game, then PokeDaisy's covers
    func fetchArt() async {
        guard let serial else { return }
        let games = saves.filter { $0.game != nil }
        guard !games.isEmpty else { return }
        phase = "Getting game artwork…"
        defer { phase = nil }
        var found = await cocoonRoot()
        if found == nil { found = await EmulationHub.findCocoonRoot(serial: serial) }
        guard let cocoon = found else {
            // Without Cocoon only PokeDaisy's covers are available.
            return await fetchCoversOnly(serial: serial, games: games)
        }
        let roots = ADB.quote(cocoon)
        let listing = """
        for c in \(roots); do \
          ls -1 "$c/downloaded_media/shortcut/icon" 2>/dev/null | grep -i peanuts | sed "s|^|SHORTCUT $c/downloaded_media/shortcut/icon/|"; \
          for s in gb gbc gba nds n3ds gc switch; do \
            [ -f "$c/gamelists/$s/gamelist.xml" ] && grep -E "<path>|boxartlocal>" "$c/gamelists/$s/gamelist.xml" | sed "s|^|LIST $c |"; \
            for k in icon logo; do ls -1 "$c/downloaded_media/$s/$k" 2>/dev/null | grep -i pok | sed "s|^|MEDIA $c/downloaded_media/$s/$k/|"; done; \
          done; \
        done; \
        ls -1 \(Emulators.data)/com.pokedaisy.app/files/covers 2>/dev/null | grep -i pok | sed "s|^|COVER \(Emulators.data)/com.pokedaisy.app/files/covers/|"; true
        """
        let out = (try? await ADB.shared.shell(listing, serial: serial, timeout: 60)) ?? ""
        var shortcuts: [String: String] = [:]          // title id → icon path (newest Cocoon edit wins)
        var chosen: [String: String] = [:]             // rom file name (lowercased) → box art path
        var media: [PKGame: String] = [:]
        var covers: [PKGame: String] = [:]
        var lastPath: String?
        for raw in out.split(separator: "\n").map(String.init) {
            if raw.hasPrefix("SHORTCUT ") {
                let path = String(raw.dropFirst(9))
                if let tid = PKGame.allCases.compactMap(\.switchTitle).first(where: { path.uppercased().contains($0) }) {
                    if shortcuts[tid].map({ $0 < path }) ?? true { shortcuts[tid] = path }
                }
            } else if raw.hasPrefix("LIST ") {
                let rest = raw.dropFirst(5)
                guard let space = rest.firstIndex(of: " ") else { continue }
                let root = String(rest[..<space])
                let line = String(rest[rest.index(after: space)...])
                if let r = line.range(of: "<path>"), let e = line.range(of: "</path>") {
                    lastPath = (String(line[r.upperBound..<e.lowerBound]) as NSString).lastPathComponent.lowercased()
                } else if let r = line.range(of: "Cocoon_Data%2F"), let e = line.range(of: "</cocoon:boxartlocal>"), let file = lastPath {
                    let relative = String(line[r.upperBound..<e.lowerBound]).removingPercentEncoding ?? ""
                    chosen[file] = (root as NSString).appendingPathComponent(relative)
                }
            } else if raw.hasPrefix("MEDIA ") {
                let path = String(raw.dropFirst(6))
                let name = (path as NSString).lastPathComponent
                guard Self.isPokemonTitle(name), let game = SaveDetector.game(fromName: name) else { continue }
                if let current = media[game], current.contains("/icon/") || !path.contains("/icon/") { continue }
                media[game] = path
            } else if raw.hasPrefix("COVER ") {
                let path = String(raw.dropFirst(6))
                if Self.isPokemonTitle((path as NSString).lastPathComponent), let game = SaveDetector.game(fromName: (path as NSString).lastPathComponent), covers[game] == nil { covers[game] = path }
            }
        }
        var pick: [PKGame: String] = [:]
        for save in games {
            guard let game = save.game, pick[game] == nil else { continue }
            if let tid = game.switchTitle, let icon = shortcuts[tid] { pick[game] = icon; continue }
            if let rom = save.romPath.map({ ($0 as NSString).lastPathComponent.lowercased() }), let art = chosen[rom] { pick[game] = art; continue }
            // Same file name as the save (e.g. "Pokemon - Gold Version (…).sav" ↔ "…zip"), in any system folder.
            let stem = (save.fileName as NSString).deletingPathExtension.lowercased()
            if let art = chosen.first(where: { ($0.key as NSString).deletingPathExtension == stem })?.value { pick[game] = art; continue }
            // Otherwise a Pokémon entry for the same game (sorted, so the choice is stable).
            if let art = chosen.filter({ Self.isPokemonTitle($0.key) && SaveDetector.game(fromName: $0.key) == game }).sorted(by: { $0.key < $1.key }).first?.value {
                pick[game] = art; continue
            }
            if let art = media[game] ?? covers[game] { pick[game] = art }
        }
        for save in games { Log.write("pokemon art: \(save.game?.rawValue ?? "?") \(save.fileName) rom=\(save.romPath ?? "-") → \(save.game.flatMap { pick[$0] } ?? "none")") }
        Log.write("pokemon art: \(chosen.count) Cocoon entries, \(shortcuts.count) shortcuts, \(media.count) media, \(covers.count) covers")
        for (game, remote) in pick {
            let marker = Self.artCache.appendingPathComponent("\(game.rawValue).source")
            if art[game] != nil, (try? String(contentsOf: marker, encoding: .utf8)) == remote { continue }
            let local = Self.artCache.appendingPathComponent("\(game.rawValue)-raw")
            guard (try? await ADB.shared.run(["pull", remote, local.path], serial: serial, timeout: 30))?.ok == true,
                  let image = NSImage(contentsOf: local) else { continue }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: Self.artCache.appendingPathComponent("\(game.rawValue).png"))
                try? remote.write(to: marker, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.removeItem(at: local)
            art[game] = image
        }
    }

    private func fetchCoversOnly(serial: String, games: [FoundSave]) async {
        let out = (try? await ADB.shared.shell("ls -1 \(Emulators.data)/com.pokedaisy.app/files/covers 2>/dev/null | grep -i pok; true", serial: serial, timeout: 15)) ?? ""
        for name in out.split(separator: "\n").map(String.init) where !Self.isSpinOff(name) {
            guard let game = SaveDetector.game(fromName: name), art[game] == nil, games.contains(where: { $0.game == game }) else { continue }
            let local = Self.artCache.appendingPathComponent("\(game.rawValue).png")
            if (try? await ADB.shared.run(["pull", "\(Emulators.data)/com.pokedaisy.app/files/covers/\(name)", local.path], serial: serial, timeout: 30))?.ok == true,
               let image = NSImage(contentsOf: local) { art[game] = image }
        }
    }

    func reset(serial: String?) {
        self.serial = serial
        icons.serial = serial
        if serial == nil {
            allSaves = []
            opened = [:]
            lastScan = nil
        }
    }

    // MARK: - Finding saves

    private static let data = Emulators.data

    /// Shell command listing every file that could be a Pokémon save, one path per line.
    private static var findCommand: String {
        let d = data
        var parts: [String] = []
        // PokeDaisy, RetroArch, melonDS (folder saves and saves next to ROMs)
        parts.append("find \(d)/com.pokedaisy.app/files/saves -maxdepth 1 -type f \\( -iname '*.sav' -o -iname '*.srm' \\)")
        parts.append("find \(d)/com.retroarch/files/RetroArch/saves /sdcard/RetroArch/saves -maxdepth 3 -type f \\( -iname '*.srm' -o -iname '*.sav' \\)")
        parts.append("find \(d)/me.magnum.melondualds/files/saves -maxdepth 2 -type f \\( -iname '*.sav' -o -iname '*.dsv' \\)")
        parts.append("for r in /sdcard/Roms $(ls -d /storage/*/Roms 2>/dev/null | grep -v emulated); do find \"$r/gb\" \"$r/gbc\" \"$r/gba\" \"$r/nds\" -maxdepth 1 -type f \\( -iname '*.sav' -o -iname '*.srm' -o -iname '*.dsv' \\); done")
        // Azahar (3DS) – every Pokémon title, installed or not
        let titles = PKGame.allCases.compactMap(\.threeDSTitle).joined(separator: "|")
        parts.append("find '/sdcard/Azahar_Data/sdmc/Nintendo 3DS' -path '*/title/00040000/*/data/00000001/main' 2>/dev/null | grep -iE '/(\(titles))/'")
        // Dolphin (GameCube)
        parts.append("find \(d)/org.dolphinemu.dolphinemu/files/GC -maxdepth 3 -type f -iname '*.gci' | grep -iE 'GC6|GXX|GPX'")
        // Peanuts Native (Switch) – every Pokémon title id
        for game in PKGame.allCases {
            guard let tid = game.switchTitle else { continue }
            let dir = "\(d)/\(Emulators.peanuts)/files/saves/\(tid)"
            // Shared storage ignores case, so stop at the first name that exists.
            parts.append("for f in main SaveData.bin savedata.bin; do [ -f \"\(dir)/$f\" ] && { echo \"\(dir)/$f\"; break; }; done")
        }
        // Other native ports (Emerald Recomp and friends): saves of Pokémon-shaped sizes
        parts.append("find \(d)/*/files -maxdepth 4 -type f \\( -size 131072c -o -size 131088c -o -size 32768c -o -size 32816c -o -size 524288c \\) \\( -iname '*.sav' -o -iname '*.srm' -o -iname '*.bin' -o -iname '*.dat' \\) | grep -vE 'com.pokedaisy.app|com.retroarch|melondualds|dolphinemu|\(Emulators.peanuts)'")
        return parts.map { "\($0) 2>/dev/null" }.joined(separator: "; ") + "; true"
    }

    static func sourceName(for path: String) -> String {
        if path.contains("com.pokedaisy.app") { return "PokeDaisy" }
        if path.contains(Emulators.peanuts) { return "Peanuts Native" }
        if path.contains("retroarch") || path.contains("/RetroArch/") { return "RetroArch" }
        if path.contains("melondualds") || path.contains("/Roms/nds/") { return "melonDS" }
        if path.contains("Azahar") { return "Azahar" }
        if path.contains("dolphinemu") { return "Dolphin" }
        if path.contains("/Roms/") { return "Roms folder" }
        let parts = path.split(separator: "/")
        if let i = parts.firstIndex(of: "data"), i + 1 < parts.count { return String(parts[i + 1]) }
        return "Device"
    }

    func scan() async {
        guard let serial, !scanning else { return }
        scanning = true
        defer { scanning = false; lastScan = Date() }
        phase = "Looking for Pokémon saves…"
        progress = nil
        defer { phase = nil; progress = nil }
        let out = (try? await ADB.shared.shell(Self.findCommand, serial: serial, timeout: 90)) ?? ""
        var paths: [String] = []
        var seen = Set<String>()
        for raw in out.split(separator: "\n") {
            let path = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/storage/emulated/0/", with: "/sdcard/")
            guard !path.isEmpty, !path.contains("pokedaisy-backups"), seen.insert(path.lowercased()).inserted else { continue }
            paths.append(path)
        }
        var modified: [String: Date] = [:]
        if !paths.isEmpty {
            let stat = paths.map { "stat -c '%Y|%n' \(ADB.quote($0)) 2>/dev/null" }.joined(separator: "; ")
            for line in ((try? await ADB.shared.shell(stat, serial: serial, timeout: 30)) ?? "").split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2, let t = Double(parts[0]) { modified[parts[1].replacingOccurrences(of: "/storage/emulated/0/", with: "/sdcard/")] = Date(timeIntervalSince1970: t) }
            }
        }
        let library = await LeftoverScanner.Library.load(serial: serial)
        roms = library.files.filter { entry in
            let name = (entry.path as NSString).lastPathComponent
            return ["gba", "nds", "zip", "7z"].contains((name as NSString).pathExtension.lowercased()) && name.lowercased().contains("pok")
        }.map(\.path)
        var found: [FoundSave] = []
        var newOpened: [String: OpenSave] = [:]
        for (index, path) in paths.enumerated() {
            phase = "Reading saves (\(index + 1) of \(paths.count))…"
            progress = Double(index) / Double(max(paths.count, 1))
            guard let bytes = await Self.pull(path, serial: serial), bytes.count > 0x1000 else { continue }
            var item = FoundSave(remote: path, companions: await companions(for: path, serial: serial), source: Self.sourceName(for: path))
            item.romPath = Self.matchROM(for: path, in: library)
            item.modified = modified[path]
            let nameForHint = item.romPath.map { ($0 as NSString).lastPathComponent } ?? item.fileName
            var hint = SaveDetector.Hint(fileName: Self.isPokemonTitle(nameForHint) ? nameForHint : "")
            hint.titleID = Self.titleID(in: path)
            hint.companions = item.companions.map { ($0 as NSString).lastPathComponent }
            if let rom = item.romPath { hint.romCode = await Self.romCode(rom, serial: serial) }
            do {
                let save = try SaveDetector.open(bytes, hint: hint)
                // Romhacks can't be edited, so they aren't listed.
                if (save as? SaveGen3Container)?.isRomhack == true { continue }
                item.game = save.game
                item.trainer = save.trainerName
                item.trainerID = save.trainerID
                item.count = save.allSlots.count
                item.readOnly = save.readOnlyReason ?? (item.source == "Peanuts Native" && !Self.peanutsWritesVerified
                    ? "Peanuts Native saves can be looked at for now; changing them gets switched on once it's been tested on the \(DeviceInfo.name)." : nil)
                newOpened[path] = opened[path].flatMap { $0.dirty ? $0 : nil } ?? OpenSave(found: item, file: save)
                try? Data(bytes).write(to: Self.cache.appendingPathComponent(Self.cacheName(path)))
            } catch {
                // Never-saved files (all 0xFF / 0x00) have nothing to show.
                if bytes.isAllFF || bytes.isAllZero || bytes.filter({ $0 != 0xFF }).count < bytes.count / 50 { continue }
                // Only list unreadable files that are clearly Pokémon (named or in a Pokémon app's folder).
                // Only list unreadable files that are clearly Pokémon ("6 Golden Coins" is not Gold).
                let named = Self.isPokemonTitle(item.fileName) || item.source == "Peanuts Native" || hint.titleID != nil
                guard named else { continue }
                item.game = (Self.isPokemonTitle(item.fileName) ? SaveDetector.game(fromName: item.fileName) : nil)
                    ?? hint.titleID.flatMap { PKGame.from(switchTitle: $0) ?? PKGame.from(threeDSTitle: $0) }
                item.error = error.localizedDescription
            }
            found.append(item)
        }
        // Games with Pokémon first, then empty ones, then the ones that can't be read.
        func rank(_ s: FoundSave) -> Int { s.error != nil ? 2 : (s.count == 0 ? 1 : 0) }
        allSaves = found.sorted { (rank($0), $0.game?.originVersion ?? 999, $0.title) < (rank($1), $1.game?.originVersion ?? 999, $1.title) }
        opened = newOpened
        if selection == nil || !saves.contains(where: { $0.id == selection && $0.count > 0 }) {
            selection = saves.filter { $0.error == nil }.max { $0.count < $1.count }?.id
        }
        Log.write("pokemon scan: \(saves.count) save(s), \(opened.count) readable")
    }

    private func companions(for path: String, serial: String) async -> [String] {
        guard path.contains(Emulators.peanuts) else { return [] }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // Peanuts mirrors every save folder in "<title>.work". Backup.bin is the game's own previous
        // save and is left alone.
        let candidates = ["\(dir).work/\(name)"]
        let check = candidates.map { "[ -f \(ADB.quote($0)) ] && echo \(ADB.quote($0))" }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(check + "; true", serial: serial, timeout: 10)) ?? ""
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func cacheName(_ remote: String) -> String {
        remote.replacingOccurrences(of: "/", with: "_")
    }

    static func titleID(in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let tid = parts.first(where: { $0.count == 16 && $0.uppercased().hasPrefix("01") && PKGame.from(switchTitle: $0) != nil }) { return tid }
        if let i = parts.firstIndex(of: "00040000"), i + 1 < parts.count { return parts[i + 1] }
        return nil
    }

    /// The ROM next to a save, matched by file name in the Roms folders.
    static func matchROM(for path: String, in library: LeftoverScanner.Library) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let romExtensions: Set<String> = ["gb", "gbc", "gba", "nds", "zip", "7z"]
        return library.files.first { entry in
            let name = (entry.path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            return romExtensions.contains(ext) && (name as NSString).deletingPathExtension.lowercased() == stem
        }?.path
    }

    /// Game code / title from a ROM header (GB 0x134, GBA 0xAC, NDS 0x0C). Zipped ROMs are skipped.
    static func romCode(_ rom: String, serial: String) async -> String? {
        let ext = (rom as NSString).pathExtension.lowercased()
        let (offset, count): (Int, Int)
        switch ext {
        case "gb", "gbc": (offset, count) = (0x134, 15)
        case "gba": (offset, count) = (0xAC, 4)
        case "nds": (offset, count) = (0x0C, 4)
        default: return nil
        }
        guard let data = await ADB.shared.data("tail -c +\(offset + 1) \(ADB.quote(rom)) | head -c \(count)", serial: serial, timeout: 15) else { return nil }
        return String(bytes: data.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii)
    }

    static func pull(_ path: String, serial: String) async -> [UInt8]? {
        guard let data = await ADB.shared.data("cat \(ADB.quote(path))", serial: serial, timeout: 60), !data.isEmpty else { return nil }
        return [UInt8](data)
    }

    // MARK: - Editing

    func open(_ id: String?) -> OpenSave? { id.flatMap { opened[$0] } }

    /// Replaces a Pokémon in a save (in memory). Call `write` to put the save back on the device.
    func update(_ save: OpenSave, slot: SlotRef, with mon: Mon) throws {
        try save.file.set(mon, at: slot)
        save.file.registerDex(mon)
        save.touch()
    }

    // MARK: - Organising boxes (kept in memory until saved)

    /// The save as it was before the first unsaved box change, for Undo.
    @Published private var pristine: [String: [UInt8]] = [:]

    /// Every open save with changes that aren't on the device yet.
    var unsavedSaves: [OpenSave] { saves.compactMap { pristine[$0.id] != nil ? opened[$0.id] : nil } }

    /// Throws away all unsaved changes in every game.
    func discardAll() { for save in unsavedSaves { discardChanges(save) } }

    private func rememberPristine(_ save: OpenSave) throws {
        // Every in-memory change goes through here: refresh everything that shows the save
        // (boxes, "Ready to evolve", the save bar), not just the box grid.
        objectWillChange.send()
        if pristine[save.id] == nil { pristine[save.id] = try save.file.serialize() }
    }

    /// Moves a Pokémon to another slot of the same game, swapping with whatever is there.
    func organize(_ save: OpenSave, from a: SlotRef, to b: SlotRef) throws {
        guard a != b, let moving = save.file.mon(at: a) else { return }
        if let reason = save.file.readOnlyReason ?? save.found.readOnly { throw PKError.readOnly(reason) }
        try rememberPristine(save)
        let other = save.file.mon(at: b)
        if a.area == .party && other == nil && save.file.party().count <= 1 {
            throw PKError.unsupported("At least one Pokémon has to stay in the party.")
        }
        if let other {
            try save.file.set(other, at: a)
            try save.file.set(moving, at: b)
        } else if a.area == .party && b.area == .party {
            // Party slots are packed: moving to an empty party slot just reorders to the end.
            try save.file.set(nil, at: a)
            try save.file.set(moving, at: .party(save.file.party().count))
        } else {
            try save.file.set(moving, at: b)
            // Removing afterwards keeps packed (Game Boy) lists in order.
            try save.file.set(nil, at: a)
        }
        save.touch()
    }

    /// Changes one Pokémon (rename, trade evolution …) in memory; saved with the other box changes.
    func edit(_ save: OpenSave, slot: SlotRef, to mon: Mon) throws {
        if let reason = save.file.readOnlyReason ?? save.found.readOnly { throw PKError.readOnly(reason) }
        try rememberPristine(save)
        try save.file.set(mon, at: slot)
        save.file.registerDex(mon)
        save.touch()
    }

    /// Releases a Pokémon (removes it from the save) in memory.
    func release(_ save: OpenSave, slot: SlotRef) throws {
        if let reason = save.file.readOnlyReason ?? save.found.readOnly { throw PKError.readOnly(reason) }
        if slot.area == .party && save.file.party().count <= 1 { throw PKError.unsupported("The last Pokémon in the party can't be released.") }
        try rememberPristine(save)
        try save.file.set(nil, at: slot)
        save.touch()
    }

    /// Releases several Pokémon at once (highest slot first, so packed Game Boy boxes don't shift).
    func releaseMany(_ save: OpenSave, slots: [SlotRef]) throws {
        if let reason = save.file.readOnlyReason ?? save.found.readOnly { throw PKError.readOnly(reason) }
        let partyLeaving = slots.filter { $0.area == .party }.count
        if partyLeaving > 0 && partyLeaving >= save.file.party().count {
            throw PKError.unsupported("At least one Pokémon has to stay in the party.")
        }
        try rememberPristine(save)
        let ordered = slots.sorted { ($0.area == .party ? 1 : 0, $0.box, $0.index) > ($1.area == .party ? 1 : 0, $1.box, $1.index) }
        for slot in ordered where save.file.mon(at: slot) != nil { try save.file.set(nil, at: slot) }
        save.touch()
    }

    /// Longest nickname the game takes.
    static func maxNameLength(_ game: PKGame) -> Int { game.generation <= 5 ? 10 : 12 }

    /// Renames a Pokémon; an empty name (or the species name) gives it back its normal name.
    static func renamed(_ mon: Mon, to name: String, in game: PKGame) -> Mon {
        var m = mon
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength(game)))
        let species = PokeData.shared.speciesName(mon.species)
        if clean.isEmpty || clean.caseInsensitiveCompare(species) == .orderedSame {
            m.isNicknamed = false
            m.nickname = game.generation <= 4 ? species.uppercased() : species
        } else {
            m.isNicknamed = true
            m.nickname = clean
        }
        return m
    }

    enum BoxOrder: String, CaseIterable {
        case level, dex, name

        func label(ascending: Bool) -> String {
            switch self {
            case .level: return ascending ? "Level, lowest first" : "Level, highest first"
            case .dex: return ascending ? "Pokédex number, 1 first" : "Pokédex number, highest first"
            case .name: return ascending ? "Name, A to Z" : "Name, Z to A"
            }
        }
    }

    /// Sorts every Pokémon in the boxes (the party stays as it is) and lays them out from the
    /// first box on, with no gaps.
    func sortBoxes(_ save: OpenSave, by order: BoxOrder, ascending: Bool = true) throws {
        if let reason = save.file.readOnlyReason ?? save.found.readOnly { throw PKError.readOnly(reason) }
        let file = save.file
        let mons = (0..<file.boxCount).flatMap { file.boxContents($0).compactMap { $0 } }
        guard mons.count > 1 else { return }
        try rememberPristine(save)
        var sorted: [Mon]
        switch order {
        case .dex: sorted = mons.sorted { ($0.species, $0.form, $0.level) < ($1.species, $1.form, $1.level) }
        case .level: sorted = mons.sorted { ($0.level, $0.species) < ($1.level, $1.species) }
        case .name: sorted = mons.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if !ascending { sorted.reverse() }
        for b in stride(from: file.boxCount - 1, through: 0, by: -1) {
            for i in stride(from: file.boxSize - 1, through: 0, by: -1) where file.mon(at: .box(b, i)) != nil {
                try file.set(nil, at: .box(b, i))
            }
        }
        for (n, mon) in sorted.enumerated() { try file.set(mon, at: .box(n / file.boxSize, n % file.boxSize)) }
        save.touch()
    }

    /// True when the save has box changes that aren't on the device yet.
    func hasUnsavedChanges(_ save: OpenSave) -> Bool { pristine[save.id] != nil }

    /// Throws away unsaved box changes.
    func discardChanges(_ save: OpenSave) {
        objectWillChange.send()
        guard let bytes = pristine.removeValue(forKey: save.id) else { return }
        try? reload(save, from: bytes)
    }

    /// Moves a Pokémon from one save to another. Both saves are backed up and written.
    func move(_ mon: Mon, from source: OpenSave, slot: SlotRef, to target: OpenSave, plan: TransferPlan) async throws {
        try await moveMany([(slot, plan)], from: source, to: target)
    }

    /// Moves several Pokémon from one save to another with one backup and one write per save.
    /// Pokémon whose plan is blocked are skipped.
    func moveMany(_ items: [(slot: SlotRef, plan: TransferPlan)], from source: OpenSave, to target: OpenSave) async throws {
        let movable = items.filter { $0.plan.isPossible }
        guard !movable.isEmpty else { throw PKError.unsupported(items.first?.plan.blocked ?? "None of them can go there.") }
        if let reason = target.file.readOnlyReason ?? target.found.readOnly { throw PKError.readOnly(reason) }
        if let reason = source.file.readOnlyReason ?? source.found.readOnly { throw PKError.readOnly(reason) }
        let partyLeaving = movable.filter { $0.slot.area == .party }.count
        if partyLeaving > 0 && partyLeaving >= source.file.party().count {
            throw PKError.unsupported("At least one Pokémon has to stay in the party.")
        }
        let beforeTarget = try target.file.serialize()
        let beforeSource = source === target ? beforeTarget : try source.file.serialize()
        var placed: [SlotRef] = []
        do {
            placed = try Self.applyMoves(movable, from: source.file, to: target.file)
        } catch {
            // Roll back in memory so nothing half-moved is left behind.
            try? reload(target, from: beforeTarget)
            if source !== target { try? reload(source, from: beforeSource) }
            throw error
        }
        target.touch()
        source.touch()
        try await write(source === target ? [source] : [target, source], label: "Before Pokémon move")
        let names = movable.count == 1 ? movable[0].plan.mon.name : "\(movable.count) Pokémon"
        let where_ = placed.first.map { " (\(target.file.boxName($0.box)))" } ?? ""
        toast?("arrow.left.arrow.right", "\(names) moved to \(target.found.title)\(where_)")
    }

    /// The in-memory part of a move: takes the Pokémon out of `source` and puts them into free box
    /// slots of `target`. Returns where they went.
    nonisolated static func applyMoves(_ items: [(slot: SlotRef, plan: TransferPlan)], from source: SaveFile, to target: SaveFile) throws -> [SlotRef] {
        // Take them out first (highest slot first, so packed Game Boy boxes don't shift under us)…
        let ordered = items.sorted { a, b in
            (a.slot.area == .party ? 1 : 0, a.slot.box, a.slot.index) > (b.slot.area == .party ? 1 : 0, b.slot.box, b.slot.index)
        }
        for item in ordered { try source.set(nil, at: item.slot) }
        // …then put them into the first free box slots of the other game.
        var placed: [SlotRef] = []
        for item in items {
            guard let free = target.firstFreeBoxSlot() else { throw PKError.unsupported("There isn't enough free box space.") }
            try target.set(item.plan.mon, at: free)
            target.registerDex(item.plan.mon)
            placed.append(free)
        }
        return placed
    }

    private func reload(_ save: OpenSave, from bytes: [UInt8]) throws {
        var hint = SaveDetector.Hint(fileName: save.found.romPath.map { ($0 as NSString).lastPathComponent } ?? save.found.fileName)
        hint.titleID = Self.titleID(in: save.found.remote)
        hint.companions = save.found.companions.map { ($0 as NSString).lastPathComponent }
        let file = try SaveDetector.open(bytes, hint: hint)
        opened[save.found.remote] = OpenSave(found: save.found, file: file)
    }

    // MARK: - Writing back

    /// Apps that have one of these saves open right now.
    func runningApps(for saves: [OpenSave]) async -> [String] {
        guard let serial else { return [] }
        // The app that owns each save: a known emulator/player, or the package whose folder it's in.
        let packages = Set(saves.compactMap { save -> String? in
            if let profile = Emulators.all.first(where: { $0.name == save.found.source }) { return profile.package }
            if save.found.source.contains(".") { return save.found.source }
            return save.found.game?.playerPackages.first
        })
        var running: [String] = []
        for package in packages {
            let out = (try? await ADB.shared.shell("pidof \(ADB.quote(package))", serial: serial, timeout: 5)) ?? ""
            if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { running.append(package) }
        }
        return running
    }

    func closeApps(_ packages: [String]) async {
        guard let serial else { return }
        for package in packages {
            _ = try? await ADB.shared.shell("am force-stop \(ADB.quote(package))", serial: serial, timeout: 10)
        }
    }

    /// Backs up, verifies and writes the saves to the device.
    func write(_ list: [OpenSave], label: String = "Before Pokémon change") async throws {
        guard let serial else { throw PKError.unsupported("The \(DeviceInfo.name) isn't connected.") }
        busy = "Backing up…"
        defer { busy = nil }
        // 1. Check the files on the device: unchanged since they were read, and accepted by the game.
        var originals: [String: [UInt8]] = [:]
        var outputs: [(OpenSave, [UInt8], [String: [UInt8]])] = []
        for save in list {
            busy = "Checking \(save.found.title)…"
            guard let current = await Self.pull(save.found.remote, serial: serial) else {
                throw PKError.unsupported("Couldn't read \(save.found.title) from the \(DeviceInfo.name), so nothing was changed.")
            }
            let loaded = (try? Data(contentsOf: Self.cache.appendingPathComponent(Self.cacheName(save.found.remote)))).map { [UInt8]($0) }
            if let loaded, loaded != current {
                throw PKError.unsupported("\(save.found.title) was saved on the \(DeviceInfo.name) after it was read here. Press Rescan first so nothing gets lost.")
            }
            var hint = SaveDetector.Hint(fileName: save.found.romPath.map { ($0 as NSString).lastPathComponent } ?? save.found.fileName)
            hint.titleID = Self.titleID(in: save.found.remote)
            hint.companions = save.found.companions.map { ($0 as NSString).lastPathComponent }
            if let problem = (try? SaveDetector.open(current, hint: hint))?.integrityProblem {
                throw PKError.unsupported("\(save.found.title) can't be changed safely: the original file doesn't pass the game's own check (\(problem)).")
            }
            // 2. The changed file must open again, keep every Pokémon, and pass every check the game does.
            let bytes = try save.file.serialize()
            let check = try SaveDetector.open(bytes, hint: hint)
            guard check.game.family == save.file.game.family, check.allSlots.count == save.file.allSlots.count else {
                throw PKError.corrupt("The changed save didn't check out, so nothing was written.")
            }
            if let problem = check.integrityProblem {
                throw PKError.corrupt("The changed \(save.found.title) save wouldn't be accepted by the game (\(problem)), so nothing was written.")
            }
            originals[save.id] = current
            outputs.append((save, bytes, try save.file.companionFiles()))
        }
        // 3. Back up everything we're about to replace.
        busy = "Backing up…"
        if let backups {
            let entries = list.flatMap { save in ([save.found.remote] + save.found.companions).map { (emulator: save.found.source, remote: $0, custom: false) } }
            guard await backups.backup(label: label, only: entries) != nil else {
                throw PKError.unsupported("The backup didn't work, so nothing was changed.")
            }
        }
        // 4. Push each file next to its target, swap it in, read it back and compare.
        busy = "Writing…"
        for (save, bytes, companions) in outputs {
            var files: [(String, [UInt8])] = [(save.found.remote, bytes)]
            for path in save.found.companions {
                let name = (path as NSString).lastPathComponent
                if let data = companions[name] { files.append((path, data)) }
                else if name == save.found.fileName { files.append((path, bytes)) }     // .work mirror
            }
            for (remote, data) in files {
                try await Self.push(data, to: remote, serial: serial)
                let readBack = await Self.pull(remote, serial: serial)
                if readBack != data {
                    // Put the original back right away.
                    if remote == save.found.remote, let original = originals[save.id] { try? await Self.push(original, to: remote, serial: serial) }
                    Log.write("pokemon write: read-back mismatch for \(remote), original restored")
                    throw PKError.corrupt("Writing \(save.found.title) didn't come out right, so the original was put back.")
                }
            }
            try? Data(bytes).write(to: Self.cache.appendingPathComponent(Self.cacheName(save.found.remote)))
            save.saved()
            pristine[save.id] = nil
            Log.write("pokemon write: \(save.found.remote) (\(files.count) file(s), verified)")
        }
    }

    static func push(_ bytes: [UInt8], to remote: String, serial: String) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-pk-\(UUID().uuidString)")
        try Data(bytes).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let staged = "/data/local/tmp/bifrost-pk-\(UUID().uuidString.prefix(8))"
        let pushed = try await ADB.shared.run(["push", local.path, staged], serial: serial, timeout: 120)
        guard pushed.ok else { throw PKError.unsupported("Couldn't send the save to the \(DeviceInfo.name).") }
        let dir = (remote as NSString).deletingLastPathComponent
        let temp = "\(dir)/.bifrost-\(UUID().uuidString.prefix(6))"
        let size = bytes.count
        let command = """
        cp \(ADB.quote(staged)) \(ADB.quote(temp)) && [ "$(stat -c %s \(ADB.quote(temp)))" = "\(size)" ] && \
        mv -f \(ADB.quote(temp)) \(ADB.quote(remote)) && chmod 666 \(ADB.quote(remote)) 2>/dev/null; \
        [ "$(stat -c %s \(ADB.quote(remote)))" = "\(size)" ] && echo written; rm -f \(ADB.quote(staged)) \(ADB.quote(temp))
        """
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 60)) ?? ""
        guard out.contains("written") else { throw PKError.unsupported("Couldn't replace \((remote as NSString).lastPathComponent) on the \(DeviceInfo.name).") }
    }
}
