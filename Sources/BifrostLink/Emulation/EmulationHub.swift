import Foundation
import AppKit

struct ImportItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let candidates: [String]
    var system: String
}

struct UnsortedRom: Identifiable, Hashable {
    let path: String
    let size: Int64
    let candidates: [String]
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct SystemSpace: Identifiable {
    let system: String
    let path: String
    let bytes: Int64
    let files: Int
    var id: String { system }
}

struct OrphanMedia: Identifiable, Hashable {
    let system: String
    let path: String
    let size: Int64
    var id: String { path }
}

struct OrphanEntry: Identifiable, Hashable {
    let system: String
    let name: String
    let file: String
    let gamelist: String
    var id: String { gamelist + "|" + file }
}

struct BiosStatus: Identifiable {
    let system: String
    let label: String
    let found: String?
    let required: Bool
    var id: String { system + label }
}

@MainActor
final class EmulationHub: ObservableObject {
    @Published private(set) var folders: [String: RomFolder] = [:]
    @Published var importItems: [ImportItem] = []
    @Published private(set) var unsorted: [UnsortedRom] = []
    @Published private(set) var space: [SystemSpace] = []
    @Published private(set) var orphanMedia: [OrphanMedia] = []
    @Published private(set) var orphanEntries: [OrphanEntry] = []
    @Published private(set) var cleaningOrphans = false
    @Published private(set) var bios: [BiosStatus] = []
    @Published var shrinkCandidates: [ShrinkCandidate] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    @Published var shrinkProgress: ShrinkProgress?
    @Published var shrinkSelection: Set<String> = []
    @Published var shrunk: [ShrinkDone] = []
    @Published var askRemoveOriginals = false
    var shrinkTask: Task<Void, Never>?
    @Published private(set) var cocoonRoot: String?

    var serial: String?
    weak var files: FileService?
    var toast: ((String, String) -> Void)?

    nonisolated static let tools: [String: String?] = [
        "chdman": [Bundle.main.resourceURL?.appendingPathComponent("tools/chdman").path, "/opt/homebrew/bin/chdman", "/usr/local/bin/chdman"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) },
        "dolphin-tool": ["/opt/homebrew/bin/dolphin-tool", "/usr/local/bin/dolphin-tool"].first { FileManager.default.isExecutableFile(atPath: $0) },
    ]

    func reset(serial: String?) {
        self.serial = serial
        folders = [:]
        importItems = []
        unsorted = []
        space = []
        orphanMedia = []
        orphanEntries = []
        bios = []
        shrinkCandidates = []
        lastScan = nil
        cocoonRoot = nil
        guard serial != nil else { return }
        Task { await refreshFolders() }
    }

    func refreshFolders() async {
        guard let serial else { return }
        folders = await RomLocator.folders(serial: serial)
        let probe = (try? await ADB.shared.shell("for d in /storage/*/Cocoon_Data /sdcard/Cocoon_Data; do [ -d \"$d\" ] && echo \"$d\" && break; done", serial: serial, timeout: 8)) ?? ""
        cocoonRoot = probe.split(separator: "\n").first.map(String.init)
    }

    func targetFolder(for system: String) -> String {
        if let existing = folders[system] { return existing.path }
        let roots = Dictionary(grouping: folders.values.map { ($0.path as NSString).deletingLastPathComponent }, by: { $0 })
        let root = roots.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
            ?? files?.volumes.first.map { $0.path + "/Roms" } ?? "/sdcard/Roms"
        return root + "/" + system
    }

    var installedSystems: [String] {
        folders.keys.sorted { Systems.name(for: $0).localizedCaseInsensitiveCompare(Systems.name(for: $1)) == .orderedAscending }
    }

    func prepareImport(_ urls: [URL]) {
        Task {
            if folders.isEmpty { await refreshFolders() }
            var items: [ImportItem] = []
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let (candidates, _) = Systems.detect(localFile: url)
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let preferred = candidates.first { folders[$0] != nil } ?? "unsorted"
                items.append(ImportItem(url: url, size: size, candidates: candidates, system: preferred))
            }
            importItems = items
        }
    }

    func performImport() async {
        guard let serial, let files else { return }
        let items = importItems
        importItems = []
        let grouped = Dictionary(grouping: items, by: \.system)
        for (system, group) in grouped {
            let target = targetFolder(for: system)
            _ = try? await ADB.shared.shell("mkdir -p \(ADB.quote(target))", serial: serial, timeout: 10)
            files.upload(group.map(\.url), to: target)
        }
        Log.write("rom import: \(items.count) file(s) into \(grouped.keys.sorted())")
        toast?("square.and.arrow.down.on.square", items.count == 1 ? "Sending \(items[0].url.lastPathComponent) to \(Systems.name(for: items[0].system)). Rescan in Cocoon to see it" : "Sending \(items.count) ROMs to their systems. Rescan in Cocoon to see them")
        await refreshFolders()
    }

    func scan() async {
        guard let serial else { return }
        scanning = true
        defer {
            scanning = false
            lastScan = Date()
        }
        await refreshFolders()
        await scanUnsorted(serial: serial)
        await scanSpace(serial: serial)
        await scanBios(serial: serial)
        await scanHealth(serial: serial)
        await scanShrinkCandidates()
    }

    private func scanUnsorted(serial: String) async {
        let roots = ["/sdcard", "/sdcard/Download"] + (files?.volumes.flatMap { [$0.path, $0.path + "/Download"] } ?? [])
        let command = roots.map { "find \(ADB.quote($0)) -maxdepth 1 -type f -exec stat -c '%s|%n' {} + 2>/dev/null" }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 30)) ?? ""
        unsorted = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let size = Int64(parts[0]) else { return nil }
            let path = String(parts[1])
            guard Systems.isRom(path) else { return nil }
            var candidates = Systems.candidates(forExtension: (path as NSString).pathExtension)
            if let known = candidates.first(where: { folders[$0] != nil }) {
                candidates.removeAll { $0 == known }
                candidates.insert(known, at: 0)
            }
            return UnsortedRom(path: path, size: size, candidates: candidates)
        }
    }

    func moveUnsorted(_ rom: UnsortedRom, to system: String) async {
        guard let serial else { return }
        let target = targetFolder(for: system)
        let result = try? await ADB.shared.run(["shell", "mkdir -p \(ADB.quote(target)) && mv \(ADB.quote(rom.path)) \(ADB.quote(target + "/"))"], serial: serial, timeout: 1800)
        if result?.ok == true {
            unsorted.removeAll { $0.path == rom.path }
            Log.write("rom moved: \(rom.path) -> \(target)")
            toast?("checkmark.circle", "Moved \(rom.name) to \(Systems.name(for: system))")
        } else {
            toast?("exclamationmark.triangle", "Could not move \(rom.name)")
        }
    }

    private func scanSpace(serial: String) async {
        let list = folders.values.sorted { $0.system < $1.system }
        guard !list.isEmpty else { space = []; return }
        let command = list.map { "echo \"$(du -sk \(ADB.quote($0.path)) 2>/dev/null | cut -f1)|$(ls -1 \(ADB.quote($0.path)) 2>/dev/null | wc -l)|\($0.system)\"" }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 300)) ?? ""
        var result: [SystemSpace] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 3, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)), let folder = folders[parts[2]] else { continue }
            result.append(SystemSpace(system: parts[2], path: folder.path, bytes: kb * 1024, files: Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0))
        }
        space = result.sorted { $0.bytes > $1.bytes }
    }

    private func scanBios(serial: String) async {
        let dirs = (files?.volumes.map { $0.path + "/bios" } ?? []) + ["/sdcard/bios", "/sdcard/RetroArch/system"]
        let command = dirs.map { "ls -1 \(ADB.quote($0)) 2>/dev/null" }.joined(separator: "; ")
        let names = ((try? await ADB.shared.shell(command, serial: serial, timeout: 15)) ?? "").split(separator: "\n").map { $0.lowercased() }
        var result: [BiosStatus] = []
        for systemId in folders.keys.sorted() {
            guard let system = Systems.system(systemId) else { continue }
            for requirement in system.bios {
                let match = names.first { name in requirement.patterns.contains { name.contains($0) } }
                result.append(BiosStatus(system: systemId, label: requirement.label, found: match, required: requirement.required))
            }
        }
        bios = result
    }

    private func scanHealth(serial: String) async {
        var media: [OrphanMedia] = []
        var entries: [OrphanEntry] = []
        guard let cocoon = cocoonRoot else {
            orphanMedia = []
            orphanEntries = []
            return
        }
        func base(_ name: String) -> String { ((name as NSString).deletingPathExtension).lowercased() }
        for folder in folders.values.sorted(by: { $0.system < $1.system }) {
            let listing = ((try? await ADB.shared.shell("ls -1 \(ADB.quote(folder.path))", serial: serial, timeout: 20)) ?? "")
                .split(separator: "\n").map(String.init)
            guard !listing.isEmpty else { continue }
            let multiDiscRoots = (files?.volumes.map { $0.path } ?? []) + ["/sdcard"]
            let multiDisc = ((try? await ADB.shared.shell(multiDiscRoots.map { "ls -1 \(ADB.quote($0 + "/multi_disc_roms/" + folder.system)) 2>/dev/null" }.joined(separator: "; "), serial: serial, timeout: 15)) ?? "")
                .split(separator: "\n").map(String.init)
            let known = listing + multiDisc
            let present = Set(known.map(base))
            let presentTitles = Set(known.flatMap { name -> [String] in
                let title = Self.normalizedTitle(name)
                let withoutDisc = title.replacingOccurrences(of: #"\s*(disc|disk|cd)\s*\d+"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
                return [title, withoutDisc]
            }.filter { !$0.isEmpty })
            let gamelistPath = cocoon + "/gamelists/" + folder.system + "/gamelist.xml"
            var referenced = Set<String>()
            if let xml = try? await ADB.shared.shell("cat \(ADB.quote(gamelistPath)) 2>/dev/null", serial: serial, timeout: 30), xml.contains("<gameList") {
                for entry in GamelistParser.parse(xml) where !entry.path.hasPrefix("content:") {
                    let file = (entry.path as NSString).lastPathComponent
                    if present.contains(base(file)) {
                        referenced.formUnion(entry.media.map { $0.lowercased() })
                    } else {
                        entries.append(OrphanEntry(system: folder.system, name: entry.name, file: file, gamelist: gamelistPath))
                    }
                }
            }
            let mediaDir = cocoon + "/downloaded_media/" + folder.system
            let out = (try? await ADB.shared.shell("find \(ADB.quote(mediaDir)) -type f ! -name '.*' -exec stat -c '%s|%n' {} + 2>/dev/null", serial: serial, timeout: 60)) ?? ""
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let size = Int64(parts[0]) else { continue }
                let path = String(parts[1])
                let name = (path as NSString).lastPathComponent
                if referenced.contains(name.lowercased()) { continue }
                if present.contains(Self.mediaBase(name)) { continue }
                if presentTitles.contains(Self.normalizedTitle(Self.mediaBase(name) + ".x")) { continue }
                media.append(OrphanMedia(system: folder.system, path: path, size: size))
            }
        }
        orphanMedia = media
        orphanEntries = entries
    }

    func cleanOrphans() async {
        guard let serial, !orphanMedia.isEmpty || !orphanEntries.isEmpty else { return }
        cleaningOrphans = true
        defer { cleaningOrphans = false }
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return f.string(from: Date())
        }()
        let backupRoot = URL(fileURLWithPath: LinkSettings.shared.saveBackupFolder).deletingLastPathComponent()
            .appendingPathComponent("Cocoon gamelists").appendingPathComponent(stamp)
        var removedEntries = 0
        for (gamelist, group) in Dictionary(grouping: orphanEntries, by: \.gamelist) {
            guard let xml = try? await ADB.shared.shell("cat \(ADB.quote(gamelist))", serial: serial, timeout: 30), xml.contains("<gameList") else { continue }
            let system = group.first?.system ?? "system"
            let local = backupRoot.appendingPathComponent(system)
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try? xml.write(to: local.appendingPathComponent("gamelist.xml"), atomically: true, encoding: .utf8)
            let missing = Set(group.map { $0.file.lowercased() })
            let (cleaned, removed) = GamelistParser.removing(files: missing, from: xml)
            guard removed > 0 else { continue }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gamelist-\(UUID().uuidString).xml")
            try? cleaned.write(to: temp, atomically: true, encoding: .utf8)
            let push = try? await ADB.shared.run(["push", temp.path, gamelist], serial: serial, timeout: 60)
            try? FileManager.default.removeItem(at: temp)
            if push?.ok == true { removedEntries += removed }
        }
        let freed = orphanMedia.reduce(0) { $0 + $1.size }
        for chunk in stride(from: 0, to: orphanMedia.count, by: 40) {
            let paths = orphanMedia[chunk..<min(chunk + 40, orphanMedia.count)].map { ADB.quote($0.path) }.joined(separator: " ")
            _ = try? await ADB.shared.shell("rm -f \(paths)", serial: serial, timeout: 60)
        }
        Log.write("scraped cleanup: \(orphanMedia.count) media files, \(removedEntries) gamelist entries, gamelists backed up to \(backupRoot.path)")
        toast?("sparkles", "Freed \(freed.bytesText) of old artwork and tidied \(removedEntries) entries. Rescan in Cocoon")
        orphanMedia = []
        orphanEntries = []
    }

    static func mediaBase(_ filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        if let range = name.range(of: "__cocoon_edit") { name = String(name[..<range.lowerBound]) }
        name = name.replacingOccurrences(of: #"\s\(\d+\)$"#, with: "", options: .regularExpression)
        return name.lowercased()
    }

    static func normalizedTitle(_ filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        let disc = name.range(of: #"(?i)(disc|disk|cd)\s*\d+"#, options: .regularExpression).map { " " + name[$0] } ?? ""
        name = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression) + disc
        name = name.replacingOccurrences(of: #"[^a-zA-Z0-9]+"#, with: " ", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    nonisolated static func runTool(_ path: String, _ args: [String], progress: (@Sendable (Double) -> Void)? = nil) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        if let progress {
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let text = String(decoding: handle.availableData, as: UTF8.self)
                if let r = text.range(of: #"(\d+(\.\d+)?)% complete"#, options: [.regularExpression, .backwards]),
                   let value = Double(text[r].split(separator: "%").first ?? "") {
                    progress(value / 100)
                }
            }
        } else {
            errPipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: $0.terminationStatus == 0 && $0.terminationReason == .exit)
                }
                do { try process.run() } catch { continuation.resume(returning: false) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

struct GamelistEntry {
    let path: String
    let name: String
    let boxart: String
    let hero: String
    let playtime: Int
    let media: [String]
}

enum GamelistParser {
    static func parse(_ xml: String) -> [GamelistEntry] {
        var entries: [GamelistEntry] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let start = xml.range(of: "<game>", range: searchRange),
              let end = xml.range(of: "</game>", range: start.upperBound..<xml.endIndex) {
            let body = String(xml[start.upperBound..<end.lowerBound])
            entries.append(GamelistEntry(
                path: unescape(tag("path", in: body)),
                name: unescape(tag("name", in: body)),
                boxart: tag("cocoon:boxartlocal", in: body),
                hero: tag("cocoon:herolocal", in: body),
                playtime: Int(tag("cocoon:playtime", in: body)) ?? 0,
                media: mediaFiles(in: body)))
            searchRange = end.upperBound..<xml.endIndex
        }
        return entries
    }

    static func mediaFiles(in body: String) -> [String] {
        var files: [String] = []
        var cursor = body.startIndex
        while let open = body.range(of: "local>", range: cursor..<body.endIndex),
              let close = body.range(of: "</", range: open.upperBound..<body.endIndex) {
            let value = String(body[open.upperBound..<close.lowerBound])
            let decoded = value.removingPercentEncoding ?? value
            let name = (decoded.replacingOccurrences(of: "%2F", with: "/") as NSString).lastPathComponent
            if !name.isEmpty { files.append(name) }
            cursor = close.upperBound
        }
        return files
    }

    static func tag(_ name: String, in body: String) -> String {
        guard let open = body.range(of: "<\(name)>"), let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else { return "" }
        return String(body[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removing(files: Set<String>, from xml: String) -> (String, Int) {
        var result = ""
        var removed = 0
        var cursor = xml.startIndex
        while let start = xml.range(of: "<game>", range: cursor..<xml.endIndex),
              let end = xml.range(of: "</game>", range: start.upperBound..<xml.endIndex) {
            var blockStart = start.lowerBound
            while blockStart > cursor, xml[xml.index(before: blockStart)] == "\t" || xml[xml.index(before: blockStart)] == " " {
                blockStart = xml.index(before: blockStart)
            }
            var blockEnd = end.upperBound
            if blockEnd < xml.endIndex, xml[blockEnd] == "\n" { blockEnd = xml.index(after: blockEnd) }
            let body = String(xml[start.upperBound..<end.lowerBound])
            let file = (unescape(tag("path", in: body)) as NSString).lastPathComponent.lowercased()
            result += xml[cursor..<blockStart]
            if files.contains(file) {
                removed += 1
            } else {
                result += xml[blockStart..<blockEnd]
            }
            cursor = blockEnd
        }
        result += xml[cursor...]
        return (result, removed)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
