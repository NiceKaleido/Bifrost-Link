import Foundation

struct EmulatorProfile: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case caches, junk, states, saves, mods

        var id: String { rawValue }

        var title: String {
            switch self {
            case .caches: return "Shader & pipeline caches"
            case .junk: return "Dumps, logs & temp files"
            case .states: return "Save states"
            case .saves: return "Game saves"
            case .mods: return "Mods & texture packs"
            }
        }

        var note: String {
            switch self {
            case .caches: return "Rebuilt automatically. Games may stutter once while they rebuild."
            case .junk: return "Safe to remove."
            case .states: return "Per game. Backed up before removal."
            case .saves: return "Per game. Backed up before removal."
            case .mods: return "Shown for reference only, never removed."
            }
        }

        var symbol: String {
            switch self {
            case .caches: return "cpu"
            case .junk: return "doc.text"
            case .states: return "bookmark"
            case .saves: return "externaldrive.badge.checkmark"
            case .mods: return "paintpalette"
            }
        }

        var perGame: Bool { self == .states || self == .saves }
    }

    let id: String
    let name: String
    let package: String
    let paths: [Category: [String]]
    var findSaves: String?
    var configs: [String] = []

    func paths(for category: Category) -> [String] { paths[category] ?? [] }
}

enum Emulators {
    static let data = "/sdcard/Android/data"
    static let peanuts = "dev.nxnative.android.peanuts"

    static let all: [EmulatorProfile] = [
        EmulatorProfile(id: "retroarch", name: "RetroArch", package: "com.retroarch", paths: [
            .saves: ["\(data)/com.retroarch/files/RetroArch/saves", "/sdcard/RetroArch/saves"],
            .states: ["\(data)/com.retroarch/files/RetroArch/states", "/sdcard/RetroArch/states"],
            .junk: ["\(data)/com.retroarch/files/RetroArch/temp", "\(data)/com.retroarch/files/RetroArch/logs", "/sdcard/RetroArch/temp", "/sdcard/RetroArch/logs"],
        ], configs: ["\(data)/com.retroarch/files/retroarch.cfg", "\(data)/com.retroarch/files/RetroArch/config", "/sdcard/RetroArch/config"]),
        EmulatorProfile(id: "ppsspp", name: "PPSSPP", package: "org.ppsspp.ppsspp", paths: [
            .saves: ["\(data)/org.ppsspp.ppsspp/files/PSP/SAVEDATA", "/sdcard/PSP/SAVEDATA"],
            .states: ["\(data)/org.ppsspp.ppsspp/files/PSP/PPSSPP_STATE", "/sdcard/PSP/PPSSPP_STATE"],
            .caches: ["\(data)/org.ppsspp.ppsspp/files/PSP/SYSTEM/CACHE"],
            .mods: ["\(data)/org.ppsspp.ppsspp/files/PSP/TEXTURES"],
        ], configs: ["\(data)/org.ppsspp.ppsspp/files/PSP/SYSTEM/ppsspp.ini", "\(data)/org.ppsspp.ppsspp/files/PSP/SYSTEM/controls.ini"]),
        EmulatorProfile(id: "dolphin", name: "Dolphin", package: "org.dolphinemu.dolphinemu", paths: [
            .saves: ["\(data)/org.dolphinemu.dolphinemu/files/GC", "\(data)/org.dolphinemu.dolphinemu/files/Wii/title"],
            .states: ["\(data)/org.dolphinemu.dolphinemu/files/StateSaves"],
            .caches: ["\(data)/org.dolphinemu.dolphinemu/files/Cache", "\(data)/org.dolphinemu.dolphinemu/cache"],
            .junk: ["\(data)/org.dolphinemu.dolphinemu/files/Dump", "\(data)/org.dolphinemu.dolphinemu/files/Logs"],
            .mods: ["\(data)/org.dolphinemu.dolphinemu/files/Load"],
        ], configs: ["\(data)/org.dolphinemu.dolphinemu/files/Config", "\(data)/org.dolphinemu.dolphinemu/files/GameSettings"]),
        EmulatorProfile(id: "duckstation", name: "DuckStation", package: "com.github.stenzek.duckstation", paths: [
            .saves: ["\(data)/com.github.stenzek.duckstation/files/memcards"],
            .states: ["\(data)/com.github.stenzek.duckstation/files/savestates"],
            .caches: ["\(data)/com.github.stenzek.duckstation/files/cache", "\(data)/com.github.stenzek.duckstation/files/shaders"],
            .mods: ["\(data)/com.github.stenzek.duckstation/files/textures"],
        ], configs: ["\(data)/com.github.stenzek.duckstation/files/gamesettings", "\(data)/com.github.stenzek.duckstation/files/inputprofiles"]),
        EmulatorProfile(id: "edenduo", name: "Eden Duo", package: "dev.igawa6.edenduo", paths: [
            .saves: ["\(data)/dev.igawa6.edenduo/files/nand/user/save/0000000000000000"],
            .caches: ["\(data)/dev.igawa6.edenduo/files/cache"],
            .junk: ["\(data)/dev.igawa6.edenduo/files/log"],
            .mods: ["\(data)/dev.igawa6.edenduo/files/load"],
        ], configs: ["\(data)/dev.igawa6.edenduo/files/config"]),
        EmulatorProfile(id: "edennightly", name: "Eden Nightly", package: "dev.eden.eden_emulator.nightly", paths: [
            .saves: ["\(data)/dev.eden.eden_emulator.nightly/files/nand/user/save/0000000000000000"],
            .caches: ["\(data)/dev.eden.eden_emulator.nightly/files/cache"],
            .junk: ["\(data)/dev.eden.eden_emulator.nightly/files/log"],
            .mods: ["\(data)/dev.eden.eden_emulator.nightly/files/load"],
        ], configs: ["\(data)/dev.eden.eden_emulator.nightly/files/config"]),
        EmulatorProfile(id: "azahar", name: "Azahar", package: "io.github.lime3ds.android", paths: [
            .states: ["/sdcard/Azahar_Data/states"],
            .caches: ["/sdcard/Azahar_Data/shaders"],
            .junk: ["/sdcard/Azahar_Data/log"],
            .mods: ["/sdcard/Azahar_Data/load"],
        ], findSaves: "find '/sdcard/Azahar_Data/sdmc/Nintendo 3DS' -path '*/title/*/*/data' -type d 2>/dev/null", configs: ["/sdcard/Azahar_Data/config"]),
        EmulatorProfile(id: "melonds", name: "melonDS", package: "me.magnum.melondualds", paths: [
            .saves: ["\(data)/me.magnum.melondualds/files/saves"],
        ], findSaves: "for d in /sdcard/Roms/nds $(ls -d /storage/*/Roms/nds 2>/dev/null | grep -v emulated); do find \"$d\" -maxdepth 1 -name '*.sav'; done 2>/dev/null"),
        EmulatorProfile(id: "pokedaisy", name: "PokeDaisy", package: "com.pokedaisy.app", paths: [
            .saves: ["\(data)/com.pokedaisy.app/files/saves"],
            .states: ["\(data)/com.pokedaisy.app/files/states"],
        ], configs: ["\(data)/com.pokedaisy.app/files/controls.properties", "\(data)/com.pokedaisy.app/files/hotkeys.properties"]),
        // Peanuts Native keeps one folder per game (plus a `.work` twin it writes through) next to a
        // host folder with the console keys and firmware. Only the game folders are backed up.
        EmulatorProfile(id: "peanuts", name: "Peanuts Native", package: Emulators.peanuts, paths: [:],
                        findSaves: "cd \(data)/\(Emulators.peanuts)/files/saves 2>/dev/null && for d in */; do d=${d%/}; [ -d \"$d/keys\" ] || [ -d \"$d/nand\" ] || echo \"$PWD/$d\"; done"),
        EmulatorProfile(id: "armsx2", name: "ARMSX2", package: "com.armsx2", paths: [
            .saves: ["\(data)/com.armsx2/files/memcards"],
            .states: ["\(data)/com.armsx2/files/sstates"],
            .caches: ["\(data)/com.armsx2/files/cache"],
            .junk: ["\(data)/com.armsx2/files/logs"],
        ]),
    ]
}

struct SnapshotManifest: Codable {
    struct Entry: Codable, Hashable {
        let emulator: String
        let remote: String
        let local: String
        var custom: Bool?
    }
    var created: Date
    var entries: [Entry]
    var label: String?
    var pinned: Bool?
}

struct SaveSnapshot: Identifiable, Hashable {
    let url: URL
    let date: Date
    let bytes: Int64
    let label: String
    let pinned: Bool
    let entries: [SnapshotManifest.Entry]
    var id: URL { url }
    var emulators: [String] { Array(Set(entries.map(\.emulator))).sorted() }
}

struct SaveSource: Identifiable, Hashable {
    let key: String
    let name: String
    let custom: Bool
    let paths: [String]
    let bytes: Int64
    var id: String { key }
    var found: Bool { !paths.isEmpty }
}

struct SnapshotItem: Identifiable, Hashable {
    let name: String
    let bytes: Int64
    let modified: Date?
    let isFolder: Bool
    var id: String { name }
}

struct SnapshotGroup: Identifiable, Hashable {
    let emulator: String
    let custom: Bool
    let bytes: Int64
    let items: [SnapshotItem]
    let locations: [String]
    var id: String { emulator }
}

@MainActor
final class SaveBackupService: ObservableObject {
    @Published private(set) var snapshots: [SaveSnapshot] = []
    @Published private(set) var sources: [SaveSource] = []
    @Published private(set) var scanningSources = false
    @Published private(set) var running = false
    @Published private(set) var progress: String?
    @Published private(set) var fraction: Double?
    @Published private(set) var locked: [String] = []
    var serial: String?
    var toast: ((String, String) -> Void)?
    let settings = LinkSettings.shared

    var root: URL { URL(fileURLWithPath: settings.saveBackupFolder) }
    var totalBytes: Int64 { snapshots.reduce(0) { $0 + $1.bytes } }

    func reset(serial: String?) {
        self.serial = serial
        if serial == nil { sources = [] }
        loadSnapshots()
    }

    func loadSnapshots() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        snapshots = dirs.compactMap { dir in
            guard let manifest = Self.manifest(at: dir) else { return nil }
            return SaveSnapshot(url: dir, date: manifest.created, bytes: FileService.localSize(dir),
                                label: manifest.label ?? Self.label(from: dir.lastPathComponent),
                                pinned: manifest.pinned ?? false, entries: manifest.entries)
        }.sorted { $0.date > $1.date }
    }

    private static func manifest(at dir: URL) -> SnapshotManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(SnapshotManifest.self, from: data)
    }

    private static func write(_ manifest: SnapshotManifest, to dir: URL) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: dir.appendingPathComponent("manifest.json"))
    }

    private static func label(from name: String) -> String {
        for known in ["Before restore", "Before cleanup", "Automatic", "Manual"] where name.hasSuffix(known) { return known }
        return "Manual"
    }

    private func candidates(serial: String) async -> [(key: String, name: String, custom: Bool, paths: [String])] {
        var list: [(key: String, name: String, custom: Bool, paths: [String])] = []
        for emulator in Emulators.all {
            var paths = emulator.paths(for: .saves) + emulator.paths(for: .states)
            if let find = emulator.findSaves {
                let out = (try? await ADB.shared.shell(find, serial: serial, timeout: 60)) ?? ""
                paths += out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            list.append((emulator.name, emulator.name, false, paths))
            if !emulator.configs.isEmpty {
                list.append((Self.configKey(emulator.name), Self.settingsName(emulator.name), false, emulator.configs))
            }
        }
        for folder in settings.customSaveFolders {
            list.append((folder.path, folder.name, true, [folder.path]))
        }
        return list
    }

    func scanSources() async {
        guard let serial, !scanningSources else { return }
        scanningSources = true
        defer { scanningSources = false }
        let all = await candidates(serial: serial)
        let existing = await existingPaths(all.flatMap(\.paths), serial: serial)
        let sizes = await remoteSizes(Array(existing), serial: serial)
        sources = all.map { item in
            let found = item.paths.filter { existing.contains($0) }
            return SaveSource(key: item.key, name: item.name, custom: item.custom, paths: found,
                              bytes: found.reduce(0) { $0 + (sizes[$1] ?? 0) })
        }
    }

    private func remoteSizes(_ paths: [String], serial: String) async -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: Int64] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 60).map({ Array(paths[$0..<min($0 + 60, paths.count)]) }) {
            let out = (try? await ADB.shared.shell("du -sk " + chunk.map(ADB.quote).joined(separator: " ") + " 2>/dev/null", serial: serial, timeout: 60)) ?? ""
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                result[String(parts[1])] = kb * 1024
            }
        }
        return result
    }

    func checkFolder(_ path: String) async -> Bool {
        guard let serial else { return false }
        let out = (try? await ADB.shared.shell("[ -d \(ADB.quote(path)) ] && echo yes", serial: serial, timeout: 10)) ?? ""
        return out.contains("yes")
    }

    func autoBackupIfDue() async {
        guard settings.autoSaveBackup else { return }
        if let last = snapshots.first(where: { $0.label != "Before restore" }), Date().timeIntervalSince(last.date) < 20 * 3600 { return }
        await backup(label: "Automatic", only: nil)
    }

    @discardableResult
    func backup(label: String = "Manual", only: [(emulator: String, remote: String, custom: Bool)]? = nil, protect: URL? = nil) async -> URL? {
        guard let serial, !running else { return nil }
        running = true
        progress = "Looking for saves…"
        fraction = nil
        defer {
            running = false
            progress = nil
            fraction = nil
        }
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return f.string(from: Date())
        }()
        let dir = root.appendingPathComponent("\(stamp) \(label)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var targets: [(emulator: String, remote: String, custom: Bool)] = []
        if let only {
            targets = only
        } else {
            for item in await candidates(serial: serial) where settings.isSaveSourceIncluded(item.key) {
                for path in item.paths { targets.append((item.name, path, item.custom)) }
            }
        }
        let existing = await existingPaths(targets.map(\.remote), serial: serial)
        let present = targets.filter { existing.contains($0.remote) }
        var manifest = SnapshotManifest(created: Date(), entries: [], label: label, pinned: false)
        var lockedEmulators = Set<String>()
        for (index, target) in present.enumerated() {
            progress = "\(target.emulator) · \(index + 1) of \(present.count)"
            fraction = Double(index) / Double(max(1, present.count))
            let folder = target.custom ? "Custom - \(target.emulator)" : target.emulator
            let relative = "\(folder)/" + target.remote.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let local = dir.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try? await ADB.shared.run(["pull", "-a", target.remote, local.path], serial: serial, timeout: 0)
            if result?.ok == true {
                manifest.entries.append(.init(emulator: target.emulator, remote: target.remote, local: relative, custom: target.custom ? true : nil))
            } else {
                if (result?.stderr ?? "").contains("Permission denied") { lockedEmulators.insert(target.emulator) }
                try? FileManager.default.removeItem(at: local)
            }
        }
        if only == nil { locked = lockedEmulators.sorted() }
        for emulatorDir in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            if (try? FileManager.default.contentsOfDirectory(atPath: emulatorDir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: emulatorDir)
            }
        }
        guard !manifest.entries.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            if only == nil { toast?("exclamationmark.triangle", "No saves found to back up") }
            return nil
        }
        Self.write(manifest, to: dir)
        loadSnapshots()
        prune(protect: protect)
        Log.write("save backup: \(manifest.entries.count) item(s) -> \(dir.lastPathComponent)")
        if only == nil {
            let size = FileService.localSize(dir).bytesText
            toast?("externaldrive.badge.checkmark", lockedEmulators.isEmpty ? "Saves tucked away safely (\(size))" : "Saves tucked away (\(size)). \(lockedEmulators.sorted().joined(separator: ", ")) keeps its saves private")
        }
        return dir
    }

    private func existingPaths(_ paths: [String], serial: String) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var found = Set<String>()
        for chunk in stride(from: 0, to: paths.count, by: 80).map({ Array(paths[$0..<min($0 + 80, paths.count)]) }) {
            let command = chunk.map { "[ -e \(ADB.quote($0)) ] && echo \(ADB.quote($0))" }.joined(separator: "; ") + "; true"
            let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 30)) ?? ""
            found.formUnion(out.split(separator: "\n").map(String.init))
        }
        return found
    }

    private func prune(protect: URL? = nil) {
        let keep = settings.saveBackupKeep
        guard keep > 0 else { return }
        let removable = snapshots.filter { !$0.pinned && $0.url != protect }
        let pinnedCount = snapshots.count - removable.count
        let allowed = max(1, keep - pinnedCount)
        var removed = 0
        for old in removable.dropFirst(allowed) {
            try? FileManager.default.removeItem(at: old.url)
            removed += 1
        }
        if removed > 0 {
            Log.write("save backup: replaced \(removed) old backup(s), keeping \(keep)")
            loadSnapshots()
        }
    }

    func setPinned(_ snapshot: SaveSnapshot, _ pinned: Bool) {
        guard var manifest = Self.manifest(at: snapshot.url) else { return }
        manifest.pinned = pinned
        manifest.label = manifest.label ?? snapshot.label
        Self.write(manifest, to: snapshot.url)
        loadSnapshots()
    }

    func delete(_ snapshot: SaveSnapshot) {
        try? FileManager.default.removeItem(at: snapshot.url)
        Log.write("save backup deleted: \(snapshot.url.lastPathComponent)")
        loadSnapshots()
    }

    func restore(_ snapshot: SaveSnapshot, emulators: Set<String>? = nil) async {
        guard let serial, !running else { return }
        let entries = snapshot.entries.filter { emulators?.contains($0.emulator) ?? true }
        guard !entries.isEmpty else { return }
        let safety = entries.map { (emulator: $0.emulator, remote: $0.remote, custom: $0.custom ?? false) }
        let safetyDir = await backup(label: "Before restore", only: safety, protect: snapshot.url)
        running = true
        defer {
            running = false
            progress = nil
            fraction = nil
        }
        let names = Set(entries.map(\.emulator))
        for package in Emulators.all.filter({ names.contains($0.name) || names.contains(Self.settingsName($0.name)) }).map(\.package) {
            _ = try? await ADB.shared.shell("am force-stop \(ADB.quote(package))", serial: serial, timeout: 10)
        }
        var restored = 0
        for (index, entry) in entries.enumerated() {
            progress = "Restoring \(entry.emulator) · \(index + 1) of \(entries.count)"
            fraction = Double(index) / Double(entries.count)
            let local = snapshot.url.appendingPathComponent(entry.local)
            guard FileManager.default.fileExists(atPath: local.path) else { continue }
            let parent = (entry.remote as NSString).deletingLastPathComponent
            let name = (entry.remote as NSString).lastPathComponent
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-restore-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            let named = staged.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: local, to: named)
            let remoteStage = "/data/local/tmp/bifrost-restore-\(UUID().uuidString.prefix(8))"
            let pushed = try? await ADB.shared.run(["push", named.path, remoteStage + "/"], serial: serial, timeout: 0)
            try? FileManager.default.removeItem(at: staged)
            let copy = "mkdir -p \(ADB.quote(parent)) && cp -r \(ADB.quote(remoteStage + "/" + name)) \(ADB.quote(parent + "/")) && chmod -R ug+rw,o+rw \(ADB.quote(parent + "/" + name)) && echo restored; rm -rf \(ADB.quote(remoteStage))"
            let out = pushed?.ok == true ? ((try? await ADB.shared.shell(copy, serial: serial, timeout: 600)) ?? "") : ""
            if pushed?.ok != true { _ = try? await ADB.shared.shell("rm -rf \(ADB.quote(remoteStage))", serial: serial, timeout: 10) }
            if out.contains("restored") { restored += 1 }
        }
        let what = emulators?.count == 1 ? emulators!.first! : "all"
        Log.write("save restore: \(what) from \(snapshot.url.lastPathComponent), \(restored)/\(entries.count) item(s)")
        let undo = safetyDir == nil ? "" : ". Your previous saves are in “Before restore”"
        if restored == 0 {
            toast?("exclamationmark.triangle", "Nothing could be restored")
        } else if what == "all" {
            toast?("arrow.uturn.backward.circle", "Restored \(names.count == 1 ? names.first! : "\(names.count) emulators") from \(snapshot.date.formatted(date: .abbreviated, time: .shortened))\(undo)")
        } else {
            toast?("arrow.uturn.backward.circle", "Restored \(what) saves\(undo)")
        }
        await scanSources()
    }

    nonisolated static func details(for snapshot: SaveSnapshot) async -> [SnapshotGroup] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let containers = Set(Emulators.all.flatMap { $0.paths(for: .saves) + $0.paths(for: .states) + $0.configs })
            var groups: [String: (custom: Bool, items: [SnapshotItem], locations: [String])] = [:]
            for entry in snapshot.entries {
                let local = snapshot.url.appendingPathComponent(entry.local)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: local.path, isDirectory: &isDir) else { continue }
                var items: [SnapshotItem] = []
                if isDir.boolValue && (containers.contains(entry.remote) || entry.custom == true) {
                    let children = (try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                    let kind = containers.contains(entry.remote) && entry.remote.lowercased().contains("state") ? "State" : nil
                    for child in children {
                        let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                        let name = kind.map { "\($0): \(child.lastPathComponent)" } ?? child.lastPathComponent
                        items.append(SnapshotItem(name: name, bytes: FileService.localSize(child), modified: values?.contentModificationDate, isFolder: values?.isDirectory ?? false))
                    }
                } else {
                    let values = try? local.resourceValues(forKeys: [.contentModificationDateKey])
                    items.append(SnapshotItem(name: readableName(entry.remote), bytes: FileService.localSize(local), modified: values?.contentModificationDate, isFolder: isDir.boolValue))
                }
                var group = groups[entry.emulator] ?? (entry.custom == true, [], [])
                group.items += items
                group.locations.append(entry.remote)
                groups[entry.emulator] = group
            }
            return groups.map { name, group in
                SnapshotGroup(emulator: name, custom: group.custom, bytes: group.items.reduce(0) { $0 + $1.bytes },
                              items: group.items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) },
                              locations: group.locations)
            }.sorted { $0.emulator.localizedStandardCompare($1.emulator) == .orderedAscending }
        }.value
    }

    nonisolated static func configKey(_ name: String) -> String { "config:\(name)" }
    nonisolated static func settingsName(_ name: String) -> String { "\(name) settings" }

    nonisolated private static func readableName(_ remote: String) -> String {
        let parts = remote.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(of: "title"), index + 2 < parts.count {
            return "Title \(parts[index + 1])\(parts[index + 2])".uppercased().replacingOccurrences(of: "TITLE ", with: "Title ")
        }
        return parts.last ?? remote
    }
}
