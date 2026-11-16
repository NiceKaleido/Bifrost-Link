import Foundation

struct CleanupItem: Identifiable, Hashable {
    let emulator: String
    let package: String
    let category: EmulatorProfile.Category
    let path: String
    let title: String
    let bytes: Int64
    let modified: Date?
    var locked = false
    var id: String { path }
}

struct EmulatorUsage: Identifiable {
    let profile: EmulatorProfile
    var byCategory: [EmulatorProfile.Category: Int64]
    var items: [CleanupItem]
    var id: String { profile.id }
    var reclaimable: Int64 { byCategory.filter { $0.key == .caches || $0.key == .junk }.values.reduce(0, +) }
}

@MainActor
final class CleanupService: ObservableObject {
    @Published private(set) var usage: [EmulatorUsage] = []
    @Published private(set) var scanning = false
    @Published private(set) var working: String?
    @Published var selection: Set<String> = []
    var serial: String?
    weak var backups: SaveBackupService?
    var toast: ((String, String) -> Void)?

    func reset(serial: String?) {
        self.serial = serial
        usage = []
        selection = []
    }

    var installed: Set<String> = []

    func scan() async {
        guard let serial else { return }
        scanning = true
        defer { scanning = false }
        let packages = ((try? await ADB.shared.shell("pm list packages", serial: serial, timeout: 15)) ?? "")
        installed = Set(packages.split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        var result: [EmulatorUsage] = []
        for profile in Emulators.all where installed.contains(profile.package) {
            var byCategory: [EmulatorProfile.Category: Int64] = [:]
            var items: [CleanupItem] = []
            for category in EmulatorProfile.Category.allCases {
                let paths = profile.paths(for: category)
                guard !paths.isEmpty else { continue }
                if category.perGame {
                    let entries = await listChildren(paths, serial: serial)
                    for entry in entries {
                        let title = await resolveTitle(profile: profile, path: entry.path, serial: serial)
                        items.append(CleanupItem(emulator: profile.name, package: profile.package, category: category, path: entry.path, title: title, bytes: entry.bytes, modified: entry.modified, locked: !entry.readable))
                    }
                    byCategory[category] = entries.reduce(0) { $0 + $1.bytes }
                } else {
                    let sizes = await sizes(of: paths, serial: serial)
                    byCategory[category] = sizes.values.reduce(0, +)
                    if category != .mods {
                        for (path, bytes) in sizes where bytes > 0 {
                            items.append(CleanupItem(emulator: profile.name, package: profile.package, category: category, path: path, title: (path as NSString).lastPathComponent, bytes: bytes, modified: nil))
                        }
                    }
                }
            }
            if byCategory.values.contains(where: { $0 > 0 }) {
                result.append(EmulatorUsage(profile: profile, byCategory: byCategory, items: items.sorted { $0.bytes > $1.bytes }))
            }
        }
        usage = result.sorted { $0.reclaimable > $1.reclaimable }
        selection = Set(result.flatMap { $0.items.filter { $0.category == .junk }.map(\.id) })
    }

    private func sizes(of paths: [String], serial: String) async -> [String: Int64] {
        let command = paths.map { "[ -e \(ADB.quote($0)) ] && echo \"$(du -sk \(ADB.quote($0)) | cut -f1)|\($0)\"" }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 120)) ?? ""
        var result: [String: Int64] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            if parts.count == 2, let kb = Int64(parts[0]) { result[String(parts[1])] = kb * 1024 }
        }
        return result
    }

    private struct Child { let path: String; let bytes: Int64; let modified: Date?; let readable: Bool }

    private func listChildren(_ paths: [String], serial: String) async -> [Child] {
        let command = paths.map { p in
            "[ -d \(ADB.quote(p)) ] && for f in \(ADB.quote(p))/*; do [ -e \"$f\" ] && echo \"$(du -sk \"$f\" | cut -f1)|$(stat -c %Y \"$f\")|$( ( [ -d \"$f\" ] || cat \"$f\" >/dev/null 2>&1 ) && echo r || echo n)|$f\"; done"
        }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 120)) ?? ""
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count == 4, let kb = Int64(parts[0]) else { return nil }
            return Child(path: String(parts[3]), bytes: kb * 1024, modified: Double(parts[1]).map { Date(timeIntervalSince1970: $0) }, readable: parts[2] == "r")
        }
    }

    private func resolveTitle(profile: EmulatorProfile, path: String, serial: String) async -> String {
        let name = (path as NSString).lastPathComponent
        if profile.id == "ppsspp", !name.contains("."),
           let data = await ADB.shared.data("cat \(ADB.quote(path + "/PARAM.SFO")) 2>/dev/null", serial: serial, timeout: 5),
           let title = SFO.title(data) {
            return title
        }
        return (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }

    func clean(_ items: [CleanupItem]) async -> Int64 {
        guard let serial, !items.isEmpty else { return 0 }
        let perGame = items.filter { $0.category.perGame }
        if !perGame.isEmpty {
            working = "Backing up \(perGame.count) save item(s) first…"
            let backup = await backups?.backup(label: "Before cleanup", only: perGame.map { ($0.emulator, $0.path) })
            guard backup != nil else {
                working = nil
                toast?("exclamationmark.triangle", "Backup failed, nothing was removed")
                return 0
            }
        }
        working = "Cleaning…"
        for package in Set(items.map(\.package)) {
            _ = try? await ADB.shared.shell("am force-stop \(package)", serial: serial, timeout: 10)
        }
        let command = items.map { item -> String in
            item.category.perGame ? "rm -rf \(ADB.quote(item.path))" : "rm -rf \(ADB.quote(item.path))/* \(ADB.quote(item.path))/.[!.]* 2>/dev/null"
        }.joined(separator: "; ")
        _ = try? await ADB.shared.shell(command, serial: serial, timeout: 300)
        let freed = items.reduce(0) { $0 + $1.bytes }
        for item in items { Log.write("cleanup: removed \(item.category.rawValue) \(item.path)") }
        working = nil
        selection.subtract(items.map(\.id))
        toast?("sparkles", "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)). Your Thor says thanks")
        await scan()
        return freed
    }
}

enum SFO {
    static func title(_ data: Data) -> String? {
        guard data.count > 20, data.prefix(4) == Data([0x00, 0x50, 0x53, 0x46]) else { return nil }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        let keyTable = u32(8), dataTable = u32(12), count = u32(16)
        for i in 0..<count {
            let entry = 20 + i * 16
            guard entry + 16 <= data.count else { return nil }
            let keyOffset = keyTable + u16(entry)
            let length = u32(entry + 4)
            let dataOffset = dataTable + u32(entry + 12)
            guard keyOffset < data.count, dataOffset + length <= data.count else { continue }
            let keyEnd = data[keyOffset...].firstIndex(of: 0) ?? data.endIndex
            let key = String(decoding: data[keyOffset..<keyEnd], as: UTF8.self)
            if key == "SAVEDATA_TITLE" || key == "TITLE" {
                let value = String(decoding: data[dataOffset..<(dataOffset + length)], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
