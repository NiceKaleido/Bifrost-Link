import Foundation
import AppKit

struct RemoteFile: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isLink: Bool
    let size: Int64
    let modified: Date?
    var id: String { path }

    var ext: String { (name as NSString).pathExtension.lowercased() }

    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp": return "photo"
        case "mp4", "mkv", "mov", "webm", "avi": return "film"
        case "mp3", "flac", "wav", "ogg", "m4a", "opus": return "music.note"
        case "apk", "xapk": return "app.badge"
        case "zip", "7z", "rar", "gz", "tar", "xz": return "doc.zipper"
        case "txt", "md", "log", "json", "xml", "ini", "cfg": return "doc.text"
        case "pdf": return "doc.richtext"
        case "iso", "chd", "rvz", "nsp", "xci", "3ds", "cia", "nds", "gba", "gb", "gbc", "sfc", "smc", "nes", "n64", "z64", "bin", "cue", "wbfs", "pbp", "cso", "psp": return "gamecontroller"
        default: return "doc"
        }
    }
}

struct FileClipboard {
    let files: [RemoteFile]
    let cut: Bool
    var pathsText: String { files.map(\.path).joined(separator: "\n") }
}

struct Transfer: Identifiable {
    enum Direction { case upload, download }
    enum Status: Equatable { case queued, running, done, cancelled, failed(String) }
    let id = UUID()
    let direction: Direction
    let name: String
    let totalBytes: Int64
    var transferred: Int64 = 0
    var status: Status = .queued
    let destination: String
    var args: [String] = []
    var source: String = ""
    var isActive: Bool { status == .queued || status == .running }
    var progress: Double { totalBytes > 0 ? min(1, Double(transferred) / Double(totalBytes)) : 0 }
}

@MainActor
final class FileService: ObservableObject {
    @Published private(set) var path = "/sdcard"
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var transfers: [Transfer] = []
    @Published var showHidden = false { didSet { sizeCache.removeAll(); Task { await reload() } } }
    @Published var sizeMode = false { didSet { if sizeMode { Task { await measure() } } else { applySort() } } }
    @Published private(set) var measuring = false
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var largest: [RemoteFile] = []
    @Published private(set) var scanningLargest = false
    private var sizeCache: [String: [String: Int64]] = [:]
    @Published private(set) var clipboard: FileClipboard?
    @Published private(set) var pasting: String?
    @Published var pasteError: String?
    @Published private(set) var volumes: [Place] = []
    @Published private(set) var space: [VolumeSpace] = []

    struct VolumeSpace: Identifiable, Hashable {
        let name: String
        let path: String
        let symbol: String
        let total: Int64
        let free: Int64
        var id: String { path }
        var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
    }
    var serial: String?
    var onPushed: ((String) -> Void)?

    struct Place: Hashable {
        let name: String
        let path: String
        let symbol: String
    }

    static let folderPlaces: [Place] = [
        Place(name: "Download", path: "/sdcard/Download", symbol: "arrow.down.circle"),
        Place(name: "Pictures", path: "/sdcard/Pictures", symbol: "photo.on.rectangle"),
        Place(name: "Screenshots", path: "/sdcard/Pictures/Screenshots", symbol: "camera.viewfinder"),
        Place(name: "Movies", path: "/sdcard/Movies", symbol: "film"),
        Place(name: "Music", path: "/sdcard/Music", symbol: "music.note.list"),
        Place(name: "Documents", path: "/sdcard/Documents", symbol: "doc.on.doc"),
    ]

    var places: [Place] {
        [Place(name: "Internal", path: "/sdcard", symbol: "internaldrive")] + volumes + Self.folderPlaces
    }

    func displayName(forPath path: String) -> String? {
        if path == "/sdcard" { return "Internal" }
        return volumes.first { $0.path == path }?.name
    }

    func loadSpace() async {
        guard let serial else { space = []; return }
        let roots = [Place(name: "Internal", path: "/sdcard", symbol: "internaldrive")] + volumes
        let script = roots.map { "df -k \(ADB.quote($0.path)) 2>/dev/null | tail -1" }.joined(separator: "; ")
        guard let out = try? await ADB.shared.shell(script, serial: serial, timeout: 8) else { return }
        let lines = out.split(separator: "\n").map(String.init)
        var result: [VolumeSpace] = []
        for (place, line) in zip(roots, lines) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, let total = Int64(cols[1]), let available = Int64(cols[3]) else { continue }
            result.append(VolumeSpace(name: place.name, path: place.path, symbol: place.symbol, total: total * 1024, free: available * 1024))
        }
        space = result
    }

    func loadVolumes() async {
        guard let serial else { volumes = []; return }
        let out = (try? await ADB.shared.shell("sm list-volumes public 2>/dev/null; ls /storage 2>/dev/null", serial: serial, timeout: 8)) ?? ""
        var found: [String] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ").map(String.init)
            if parts.count >= 3, parts[0].hasPrefix("public:"), parts[1] == "mounted", parts[2] != "null" {
                found.append(parts[2])
            } else if parts.count == 1, line.range(of: #"^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$"#, options: .regularExpression) != nil {
                found.append(line)
            }
        }
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0).inserted }
        volumes = unique.enumerated().map { index, uuid in
            Place(name: index == 0 ? "SD Card" : "Storage \(uuid)", path: "/storage/\(uuid)", symbol: "sdcard")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    func reset(serial: String?) {
        self.serial = serial
        path = "/sdcard"
        entries = []
        transfers = []
        clipboard = nil
        volumes = []
        space = []
        if serial != nil {
            Task {
                await loadVolumes()
                await reload()
                await loadSpace()
            }
        }
    }

    func open(_ newPath: String) {
        path = newPath
        Task { await reload() }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        open(parent.isEmpty ? "/" : parent)
    }

    func reload() async {
        guard let serial else { return }
        loading = true
        defer { loading = false }
        let flags = showHidden ? "-lA" : "-l"
        let target = path.hasSuffix("/") ? path : path + "/"
        do {
            let result = try await ADB.shared.run(["shell", "ls \(flags) \(ADB.quote(target))"], serial: serial, timeout: 20)
            let parsed = Self.parse(result.stdout, base: path)
            if parsed.isEmpty && !result.stderr.isEmpty && result.stdout.isEmpty {
                error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                error = nil
            }
            entries = parsed
            sizes = sizeCache[path] ?? [:]
            applySort()
            if sizeMode && sizeCache[path] == nil {
                Task { await measure() }
            }
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
    }

    func size(of file: RemoteFile) -> Int64? {
        sizes[file.path] ?? (file.isDirectory ? nil : file.size)
    }

    var largestEntrySize: Int64 {
        entries.compactMap { size(of: $0) }.max() ?? 0
    }

    private func applySort() {
        if sizeMode {
            entries.sort { (size(of: $0) ?? -1) > (size(of: $1) ?? -1) }
        } else {
            entries.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    func measure() async {
        guard let serial else { return }
        let target = path
        if let cached = sizeCache[target] {
            sizes = cached
            applySort()
            return
        }
        measuring = true
        defer { if path == target { measuring = false } }
        let globs = showHidden ? "* .[!.]*" : "*"
        let command = "cd \(ADB.quote(target)) && du -sk -- \(globs) 2>/dev/null"
        guard let out = try? await ADB.shared.shell(command, serial: serial, timeout: 300) else { return }
        var result: [String: Int64] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0]) else { continue }
            let name = String(parts[1])
            let full = target == "/" ? "/" + name : target + "/" + name
            result[full] = kb * 1024
        }
        sizeCache[target] = result
        guard path == target else { return }
        sizes = result
        applySort()
    }

    var currentVolumeRoot: String {
        volumes.first { path.hasPrefix($0.path) }?.path ?? "/sdcard"
    }

    func findLargestFiles() async {
        guard let serial else { return }
        scanningLargest = true
        defer { scanningLargest = false }
        let root = currentVolumeRoot
        let command = "find \(ADB.quote(root + "/")) -type f -size +20000k -exec stat -c '%s|%n' {} + 2>/dev/null | sort -t'|' -k1 -rn | head -100"
        guard let out = try? await ADB.shared.shell(command, serial: serial, timeout: 300) else { return }
        largest = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let bytes = Int64(parts[0]) else { return nil }
            var full = String(parts[1])
            if full.hasPrefix(root + "//") { full = root + String(full.dropFirst(root.count + 1)) }
            return RemoteFile(name: (full as NSString).lastPathComponent, path: full, isDirectory: false, isLink: false, size: bytes, modified: nil)
        }
    }

    func reveal(_ file: RemoteFile) {
        open((file.path as NSString).deletingLastPathComponent)
    }

    static func parse(_ output: String, base: String) -> [RemoteFile] {
        let pattern = #"^([dlcbps\-])[rwxsStT\-]{9}\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var files: [RemoteFile] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let type = ns.substring(with: m.range(at: 1))
            let size = Int64(ns.substring(with: m.range(at: 2))) ?? 0
            let date = dateFormatter.date(from: ns.substring(with: m.range(at: 3)))
            var name = ns.substring(with: m.range(at: 4))
            let isLink = type == "l"
            if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            let full = base == "/" ? "/" + name : base + "/" + name
            let isDir = type == "d" || (isLink && !name.contains("."))
            files.append(RemoteFile(name: name, path: full, isDirectory: isDir, isLink: isLink, size: size, modified: date))
        }
        return files
    }

    func makeFolder(_ name: String) async {
        guard let serial, !name.isEmpty else { return }
        let target = (path as NSString).appendingPathComponent(name)
        _ = try? await ADB.shared.shell("mkdir -p \(ADB.quote(target))", serial: serial)
        await reload()
    }

    func rename(_ file: RemoteFile, to newName: String) async {
        guard let serial, !newName.isEmpty, newName != file.name else { return }
        let target = ((file.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
        _ = try? await ADB.shared.shell("mv \(ADB.quote(file.path)) \(ADB.quote(target))", serial: serial)
        forgetFromClipboard([file.path])
        await reload()
    }

    func delete(_ files: [RemoteFile]) async {
        guard let serial, !files.isEmpty else { return }
        let list = files.map { ADB.quote($0.path) }.joined(separator: " ")
        _ = try? await ADB.shared.shell("rm -rf \(list)", serial: serial, timeout: 120)
        forgetFromClipboard(files.map(\.path))
        sizeCache.removeAll()
        largest.removeAll { file in files.contains { $0.path == file.path } }
        await reload()
        await loadSpace()
    }

    func copyToClipboard(_ files: [RemoteFile], cut: Bool) {
        guard !files.isEmpty else { return }
        let clip = FileClipboard(files: files, cut: cut)
        clipboard = clip
        // Replaces whatever Finder files were on the pasteboard, so ⌘V pastes these.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip.pathsText, forType: .string)
    }

    func clearClipboard() {
        clipboard = nil
    }

    private func forgetFromClipboard(_ paths: [String]) {
        guard let clip = clipboard else { return }
        let gone = { (file: RemoteFile) in paths.contains { file.path == $0 || file.path.hasPrefix($0 + "/") } }
        let remaining = clip.files.filter { !gone($0) }
        clipboard = remaining.isEmpty ? nil : FileClipboard(files: remaining, cut: clip.cut)
    }

    func isCut(_ file: RemoteFile) -> Bool {
        guard let clipboard, clipboard.cut else { return false }
        return clipboard.files.contains { $0.path == file.path }
    }

    /// ⌘V: files copied in Finder get uploaded; otherwise whatever was copied or
    /// cut on the device is pasted.
    func pasteFromPasteboard(into dir: String? = nil) async {
        let pb = NSPasteboard.general
        let macFiles = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !macFiles.isEmpty {
            upload(macFiles, to: dir)
            return
        }
        await paste(into: dir)
    }

    func paste(into dir: String? = nil) async {
        guard let serial, let clip = clipboard, pasting == nil else { return }
        let dest = dir ?? path
        // Always read the destination fresh, hidden files included; `entries` can be stale or filtered.
        var taken = Set(await names(in: dest, serial: serial))
        var commands: [String] = []
        var moving: [String] = []
        var refused: [String] = []
        for file in clip.files {
            if file.isDirectory && (dest == file.path || dest.hasPrefix(file.path + "/")) {
                refused.append(file.name)
                continue
            }
            let parent = (file.path as NSString).deletingLastPathComponent
            if clip.cut && parent == dest { continue }
            let name = Self.freeName(file.name, isDirectory: file.isDirectory, taken: taken)
            taken.insert(name)
            moving.append(file.name)
            let target = (dest as NSString).appendingPathComponent(name)
            // -n: never overwrite, even if the name check above missed something.
            commands.append("\(clip.cut ? "mv -n" : "cp -Rn") \(ADB.quote(file.path)) \(ADB.quote(target)) || fail=1")
        }
        if commands.isEmpty {
            if clip.cut && refused.isEmpty { clipboard = nil }
            if !refused.isEmpty { pasteError = "A folder can’t be \(clip.cut ? "moved" : "copied") into itself." }
            return
        }
        let label = moving.count == 1 ? "“\(moving[0])”" : "\(moving.count) items"
        pasting = "\(clip.cut ? "Moving" : "Copying") \(label)…"
        let script = "fail=0; " + commands.joined(separator: "; ") + "; exit $fail"
        let result = try? await ADB.shared.run(["shell", script], serial: serial, timeout: 3 * 3600)
        pasting = nil
        // Whatever was cut has moved (or partly moved); the old paths are no longer worth pasting.
        if clip.cut { clipboard = nil }
        if result?.ok == true {
            if !refused.isEmpty { pasteError = "A folder can’t be \(clip.cut ? "moved" : "copied") into itself, so it was skipped." }
        } else {
            let detail = result?.stderr.split(separator: "\n").last.map(String.init) ?? "The \(DeviceInfo.name) didn’t answer."
            pasteError = "Some items couldn’t be \(clip.cut ? "moved" : "copied"). \(detail)"
            Log.write("paste failed: \(result?.stderr ?? "no result")")
        }
        sizeCache.removeAll()
        await reload()
        await loadSpace()
    }

    private func names(in dir: String, serial: String) async -> [String] {
        let target = dir.hasSuffix("/") ? dir : dir + "/"
        guard let result = try? await ADB.shared.run(["shell", "ls -A \(ADB.quote(target))"], serial: serial, timeout: 20) else {
            return dir == path ? entries.map(\.name) : []
        }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// Finder-style names: “Photo copy.png”, “Photo copy 2.png”, …
    nonisolated static func freeName(_ name: String, isDirectory: Bool, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = "\(base) copy\(suffix)"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) copy \(n)\(suffix)"
            n += 1
        }
        return candidate
    }

    func upload(_ urls: [URL], to remoteDir: String? = nil) {
        let dir = remoteDir ?? path
        for url in urls {
            let remote = (dir as NSString).appendingPathComponent(url.lastPathComponent)
            var transfer = Transfer(direction: .upload, name: url.lastPathComponent, totalBytes: Self.localSize(url), destination: remote)
            transfer.args = ["push", url.path, remote]
            transfer.source = url.path
            transfers.append(transfer)
        }
        pump()
    }

    func download(_ files: [RemoteFile], to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var claimed = Set(transfers.filter(\.isActive).map(\.destination))
        for file in files {
            var local = folder.appendingPathComponent(file.name)
            var n = 2
            while FileManager.default.fileExists(atPath: local.path) || claimed.contains(local.path) {
                let base = (file.name as NSString).deletingPathExtension
                let ext = (file.name as NSString).pathExtension
                local = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            claimed.insert(local.path)
            var transfer = Transfer(direction: .download, name: file.name, totalBytes: file.isDirectory ? 0 : file.size, destination: local.path)
            transfer.args = ["pull", "-a", file.path, local.path]
            transfer.source = file.path
            transfers.append(transfer)
        }
        pump()
    }

    var activeCount: Int { transfers.filter(\.isActive).count }
    var isIdle: Bool { activeCount == 0 }

    func waitUntilIdle() async {
        while !isIdle && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private var current: (id: UUID, process: Process?)?

    private func pump() {
        guard current == nil, let next = transfers.first(where: { $0.status == .queued }) else { return }
        guard let serial else { return }
        let id = next.id
        current = (id, nil)
        update(id) { $0.status = .running }
        Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let bytes = await self.measureProgress(next) else { continue }
                    self.update(id) { if bytes > $0.transferred { $0.transferred = min(bytes, max($0.totalBytes, bytes)) } }
                }
            }
            let result = try? await ADB.shared.run(next.args, serial: serial, timeout: 0) { process in
                Task { @MainActor in if self.current?.id == id { self.current = (id, process) } }
            }
            poller.cancel()
            let ok = result?.ok ?? false
            self.update(id) {
                guard $0.status != .cancelled else { return }
                $0.status = ok ? .done : .failed(result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Transfer failed")
                if ok { $0.transferred = max($0.totalBytes, $0.transferred) }
            }
            if ok, next.direction == .upload {
                self.sizeCache.removeAll()
                self.onPushed?(next.destination)
                if (next.destination as NSString).deletingLastPathComponent == self.path { await self.reload() }
            }
            self.current = nil
            if self.isIdle { await self.loadSpace() }
            self.pump()
        }
    }

    private func measureProgress(_ transfer: Transfer) async -> Int64? {
        if transfer.direction == .download {
            let size = Self.localSize(URL(fileURLWithPath: transfer.destination))
            return size > 0 ? size : nil
        }
        guard let serial, let out = try? await ADB.shared.shell("du -sk \(ADB.quote(transfer.destination)) 2>/dev/null | cut -f1", serial: serial, timeout: 4),
              let kb = Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)), kb > 0 else { return nil }
        return kb * 1024
    }

    func cancel(_ transfer: Transfer) {
        guard let index = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
        let wasRunning = transfers[index].status == .running
        guard transfers[index].isActive else { return }
        transfers[index].status = .cancelled
        guard wasRunning else { return }
        current?.process?.terminate()
        let destination = transfer.destination
        let direction = transfer.direction
        let serial = self.serial
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if direction == .download {
                try? FileManager.default.removeItem(atPath: destination)
            } else if let serial {
                _ = try? await ADB.shared.shell("rm -rf \(ADB.quote(destination))", serial: serial, timeout: 15)
            }
        }
    }

    func cancelAll() {
        for transfer in transfers where transfer.isActive { cancel(transfer) }
    }

    private func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    nonisolated static func localSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
