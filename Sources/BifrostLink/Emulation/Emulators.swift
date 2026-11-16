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

    func paths(for category: Category) -> [String] { paths[category] ?? [] }
}

enum Emulators {
    static let data = "/sdcard/Android/data"

    static let all: [EmulatorProfile] = [
        EmulatorProfile(id: "retroarch", name: "RetroArch", package: "com.retroarch", paths: [
            .saves: ["/sdcard/RetroArch/saves"],
            .states: ["/sdcard/RetroArch/states"],
            .junk: ["/sdcard/RetroArch/temp", "/sdcard/RetroArch/logs"],
        ]),
        EmulatorProfile(id: "ppsspp", name: "PPSSPP", package: "org.ppsspp.ppsspp", paths: [
            .saves: ["\(data)/org.ppsspp.ppsspp/files/PSP/SAVEDATA", "/sdcard/PSP/SAVEDATA"],
            .states: ["\(data)/org.ppsspp.ppsspp/files/PSP/PPSSPP_STATE", "/sdcard/PSP/PPSSPP_STATE"],
            .caches: ["\(data)/org.ppsspp.ppsspp/files/PSP/SYSTEM/CACHE"],
            .mods: ["\(data)/org.ppsspp.ppsspp/files/PSP/TEXTURES"],
        ]),
        EmulatorProfile(id: "dolphin", name: "Dolphin", package: "org.dolphinemu.dolphinemu", paths: [
            .saves: ["\(data)/org.dolphinemu.dolphinemu/files/GC", "\(data)/org.dolphinemu.dolphinemu/files/Wii/title"],
            .states: ["\(data)/org.dolphinemu.dolphinemu/files/StateSaves"],
            .caches: ["\(data)/org.dolphinemu.dolphinemu/files/Cache", "\(data)/org.dolphinemu.dolphinemu/cache"],
            .junk: ["\(data)/org.dolphinemu.dolphinemu/files/Dump", "\(data)/org.dolphinemu.dolphinemu/files/Logs"],
            .mods: ["\(data)/org.dolphinemu.dolphinemu/files/Load"],
        ]),
        EmulatorProfile(id: "duckstation", name: "DuckStation", package: "com.github.stenzek.duckstation", paths: [
            .saves: ["\(data)/com.github.stenzek.duckstation/files/memcards"],
            .states: ["\(data)/com.github.stenzek.duckstation/files/savestates"],
            .caches: ["\(data)/com.github.stenzek.duckstation/files/cache", "\(data)/com.github.stenzek.duckstation/files/shaders"],
            .mods: ["\(data)/com.github.stenzek.duckstation/files/textures"],
        ]),
        EmulatorProfile(id: "edenduo", name: "Eden Duo", package: "dev.igawa6.edenduo", paths: [
            .saves: ["\(data)/dev.igawa6.edenduo/files/nand/user/save/0000000000000000"],
            .caches: ["\(data)/dev.igawa6.edenduo/files/cache"],
            .junk: ["\(data)/dev.igawa6.edenduo/files/log"],
            .mods: ["\(data)/dev.igawa6.edenduo/files/load"],
        ]),
        EmulatorProfile(id: "edennightly", name: "Eden Nightly", package: "dev.eden.eden_emulator.nightly", paths: [
            .saves: ["\(data)/dev.eden.eden_emulator.nightly/files/nand/user/save/0000000000000000"],
            .caches: ["\(data)/dev.eden.eden_emulator.nightly/files/cache"],
            .junk: ["\(data)/dev.eden.eden_emulator.nightly/files/log"],
            .mods: ["\(data)/dev.eden.eden_emulator.nightly/files/load"],
        ]),
        EmulatorProfile(id: "azahar", name: "Azahar", package: "io.github.lime3ds.android", paths: [
            .states: ["/sdcard/Azahar_Data/states"],
            .caches: ["/sdcard/Azahar_Data/shaders"],
            .junk: ["/sdcard/Azahar_Data/log"],
            .mods: ["/sdcard/Azahar_Data/load"],
        ], findSaves: "find '/sdcard/Azahar_Data/sdmc/Nintendo 3DS' -path '*/title/*/*/data' -type d 2>/dev/null"),
        EmulatorProfile(id: "melonds", name: "melonDS", package: "me.magnum.melondualds", paths: [
            .saves: ["\(data)/me.magnum.melondualds/files/saves"],
        ], findSaves: "for d in /sdcard/Roms/nds $(ls -d /storage/*/Roms/nds 2>/dev/null | grep -v emulated); do find \"$d\" -maxdepth 1 -name '*.sav'; done 2>/dev/null"),
        EmulatorProfile(id: "armsx2", name: "ARMSX2", package: "com.armsx2", paths: [
            .saves: ["\(data)/com.armsx2/files/memcards"],
            .states: ["\(data)/com.armsx2/files/sstates"],
            .caches: ["\(data)/com.armsx2/files/cache"],
            .junk: ["\(data)/com.armsx2/files/logs"],
        ]),
    ]
}

struct SaveSnapshot: Identifiable, Hashable {
    let url: URL
    let date: Date
    let bytes: Int64
    let emulators: [String]
    var id: URL { url }
}

struct SnapshotManifest: Codable {
    struct Entry: Codable {
        let emulator: String
        let remote: String
        let local: String
    }
    var created: Date
    var entries: [Entry]
}

@MainActor
final class SaveBackupService: ObservableObject {
    @Published private(set) var snapshots: [SaveSnapshot] = []
    @Published private(set) var running = false
    @Published private(set) var progress: String?
    @Published private(set) var locked: [String] = []
    var serial: String?
    var toast: ((String, String) -> Void)?
    let settings = LinkSettings.shared

    var root: URL { URL(fileURLWithPath: settings.saveBackupFolder) }

    func reset(serial: String?) {
        self.serial = serial
        loadSnapshots()
    }

    func loadSnapshots() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        snapshots = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data) else { return nil }
            return SaveSnapshot(url: dir, date: manifest.created, bytes: FileService.localSize(dir),
                                emulators: Array(Set(manifest.entries.map(\.emulator))).sorted())
        }.sorted { $0.date > $1.date }
    }

    func autoBackupIfDue() async {
        guard settings.autoSaveBackup else { return }
        if let last = snapshots.first, Date().timeIntervalSince(last.date) < 20 * 3600 { return }
        await backup(label: "Automatic", only: nil)
    }

    @discardableResult
    func backup(label: String = "Manual", only: [(emulator: String, remote: String)]? = nil) async -> URL? {
        guard let serial, !running else { return nil }
        running = true
        defer {
            running = false
            progress = nil
        }
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return f.string(from: Date())
        }()
        let dir = root.appendingPathComponent("\(stamp) \(label)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var targets: [(emulator: String, remote: String)] = []
        if let only {
            targets = only
        } else {
            for emulator in Emulators.all {
                for path in emulator.paths(for: .saves) + emulator.paths(for: .states) { targets.append((emulator.name, path)) }
                if let find = emulator.findSaves {
                    let out = (try? await ADB.shared.shell(find, serial: serial, timeout: 60)) ?? ""
                    for line in out.split(separator: "\n") { targets.append((emulator.name, String(line))) }
                }
            }
        }
        let existing = await existingPaths(targets.map(\.remote), serial: serial)
        var manifest = SnapshotManifest(created: Date(), entries: [])
        var lockedEmulators = Set<String>()
        for (index, target) in targets.enumerated() where existing.contains(target.remote) {
            progress = "\(target.emulator) (\(index + 1)/\(targets.count))"
            let relative = "\(target.emulator)/" + target.remote.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let local = dir.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try? await ADB.shared.run(["pull", "-a", target.remote, local.path], serial: serial, timeout: 0)
            if result?.ok == true {
                manifest.entries.append(.init(emulator: target.emulator, remote: target.remote, local: relative))
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
        guard !manifest.entries.isEmpty, let data = try? JSONEncoder().encode(manifest) else {
            try? FileManager.default.removeItem(at: dir)
            toast?("exclamationmark.triangle", "No saves found to back up")
            return nil
        }
        try? data.write(to: dir.appendingPathComponent("manifest.json"))
        prune()
        loadSnapshots()
        Log.write("save backup: \(manifest.entries.count) item(s) -> \(dir.lastPathComponent)")
        let size = ByteCountFormatter.string(fromByteCount: FileService.localSize(dir), countStyle: .file)
        toast?("externaldrive.badge.checkmark", lockedEmulators.isEmpty ? "Saves tucked away safely (\(size))" : "Saves tucked away (\(size)). \(lockedEmulators.sorted().joined(separator: ", ")) keeps its saves private")
        return dir
    }

    private func existingPaths(_ paths: [String], serial: String) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let command = paths.map { "[ -e \(ADB.quote($0)) ] && echo \(ADB.quote($0))" }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 30)) ?? ""
        return Set(out.split(separator: "\n").map(String.init))
    }

    private func prune() {
        let keep = max(1, settings.saveBackupKeep)
        let sorted = snapshots.sorted { $0.date > $1.date }
        for old in sorted.dropFirst(keep - 1) where old.url.lastPathComponent.hasSuffix("Automatic") {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    func restore(_ snapshot: SaveSnapshot, emulator: String) async {
        guard let serial, let data = try? Data(contentsOf: snapshot.url.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data) else { return }
        running = true
        defer {
            running = false
            progress = nil
        }
        if let package = Emulators.all.first(where: { $0.name == emulator })?.package {
            _ = try? await ADB.shared.shell("am force-stop \(package)", serial: serial, timeout: 10)
        }
        var restored = 0
        for entry in manifest.entries where entry.emulator == emulator {
            progress = "Restoring \(emulator)…"
            let local = snapshot.url.appendingPathComponent(entry.local)
            let parent = (entry.remote as NSString).deletingLastPathComponent
            let name = (entry.remote as NSString).lastPathComponent
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-restore-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            let named = staged.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: local, to: named)
            _ = try? await ADB.shared.shell("mkdir -p \(ADB.quote(parent))", serial: serial, timeout: 10)
            let result = try? await ADB.shared.run(["push", named.path, parent + "/"], serial: serial, timeout: 0)
            try? FileManager.default.removeItem(at: staged)
            if result?.ok == true { restored += 1 }
        }
        Log.write("save restore: \(emulator) from \(snapshot.url.lastPathComponent), \(restored) item(s)")
        toast?("arrow.uturn.backward.circle", restored > 0 ? "Restored \(emulator) saves from \(snapshot.url.lastPathComponent)" : "Nothing restored for \(emulator)")
    }
}
