import Foundation

struct ShrinkCandidate: Identifiable, Hashable {
    let path: String
    let members: [String]
    let system: String
    let size: Int64
    let mode: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var outName: String { (name as NSString).deletingPathExtension + ".chd" }
    var outPath: String { directory + "/" + outName }
    var estimatedSavings: Int64 { mode == "createdvd" ? size * 25 / 100 : size * 40 / 100 }
    var trackCount: Int { members.count - 1 }
}

struct ShrinkProgress {
    var index: Int
    var total: Int
    var name: String
    var step: String
    var fraction: Double?
    var saved: Int64
}

struct ShrinkDone: Identifiable {
    let candidate: ShrinkCandidate
    let newSize: Int64
    var id: String { candidate.path }
    var saved: Int64 { candidate.size - newSize }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
}

extension EmulationHub {
    static let shrinkSystems: [String: (exts: Set<String>, dvd: Bool)] = [
        "psx": (["cue", "iso"], false),
        "ps2": (["iso", "cue"], true),
        "psp": (["iso"], true),
        "dreamcast": (["gdi", "cue"], false),
        "saturn": (["cue", "iso"], false),
    ]

    var removeOriginalsAfterShrink: Bool {
        get { UserDefaults.standard.bool(forKey: "shrinkRemoveOriginals") }
        set { UserDefaults.standard.set(newValue, forKey: "shrinkRemoveOriginals"); objectWillChange.send() }
    }

    func scanShrinkCandidates() async {
        guard let serial else { return }
        var result: [ShrinkCandidate] = []
        for (system, spec) in Self.shrinkSystems {
            guard let folder = folders[system] else { continue }
            let q = ADB.quote(folder.path)
            let command = "find \(q) -maxdepth 3 -type f -exec stat -c '%s|%n' {} + 2>/dev/null; echo '@@SHEETS'; find \(q) -maxdepth 3 -type f \\( -iname '*.cue' -o -iname '*.gdi' \\) -size -256k -exec sh -c 'for f; do echo \"@@FILE $f\"; cat \"$f\"; echo; done' sh {} + 2>/dev/null"
            guard let out = try? await ADB.shared.shell(command, serial: serial, timeout: 60) else { continue }
            let halves = out.components(separatedBy: "@@SHEETS")
            var sizes: [String: Int64] = [:]
            var byLower: [String: String] = [:]
            for line in halves[0].split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let size = Int64(parts[0]) else { continue }
                let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                sizes[path] = size
                byLower[path.lowercased()] = path
            }
            var sheets: [String: [String]] = [:]
            if halves.count > 1 {
                for block in halves[1].components(separatedBy: "@@FILE ").dropFirst() {
                    let lines = block.components(separatedBy: .newlines)
                    guard let sheet = lines.first?.trimmingCharacters(in: .whitespaces), !sheet.isEmpty else { continue }
                    let dir = (sheet as NSString).deletingLastPathComponent
                    let isGdi = sheet.lowercased().hasSuffix(".gdi")
                    var refs: [String] = []
                    for line in lines.dropFirst() {
                        guard let name = Self.sheetReference(line, gdi: isGdi) else { continue }
                        let full = dir + "/" + name
                        refs.append(byLower[full.lowercased()] ?? full)
                    }
                    sheets[sheet] = refs
                }
            }
            let referenced = Set(sheets.values.flatMap { $0 })
            let converted = Set(sizes.keys.filter { $0.lowercased().hasSuffix(".chd") }.map { ($0 as NSString).deletingPathExtension.lowercased() })
            for (path, size) in sizes {
                let ext = (path as NSString).pathExtension.lowercased()
                guard spec.exts.contains(ext), !referenced.contains(path),
                      !converted.contains((path as NSString).deletingPathExtension.lowercased()) else { continue }
                var members = [path]
                var total = size
                if ext == "cue" || ext == "gdi" {
                    guard let refs = sheets[path], !refs.isEmpty, refs.allSatisfy({ sizes[$0] != nil }) else { continue }
                    let unique = Array(Set(refs)).sorted()
                    members += unique
                    total += unique.reduce(0) { $0 + (sizes[$1] ?? 0) }
                }
                guard total > 50_000_000 else { continue }
                result.append(ShrinkCandidate(path: path, members: members, system: system, size: total,
                                              mode: spec.dvd && ext == "iso" ? "createdvd" : "createcd"))
            }
        }
        shrinkCandidates = result.sorted { $0.size > $1.size }
        shrinkSelection = shrinkSelection.intersection(result.map(\.id))
    }

    static func sheetReference(_ line: String, gdi: Bool) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.firstIndex(of: "\""), let last = trimmed.lastIndex(of: "\""), first < last,
           !gdi ? trimmed.uppercased().hasPrefix("FILE") : true {
            return String(trimmed[trimmed.index(after: first)..<last])
        }
        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if gdi { return tokens.count >= 6 ? String(tokens[4]) : nil }
        guard tokens.count >= 3, tokens[0].uppercased() == "FILE" else { return nil }
        return tokens[1..<(tokens.count - 1)].joined(separator: " ")
    }

    func shrinkSelected() {
        let queue = shrinkCandidates.filter { shrinkSelection.contains($0.id) }
        guard !queue.isEmpty, shrinkTask == nil else { return }
        shrinkTask = Task { [weak self] in
            await self?.runShrink(queue)
            self?.shrinkTask = nil
            self?.shrinkProgress = nil
        }
    }

    func cancelShrink() {
        shrinkTask?.cancel()
    }

    private func runShrink(_ queue: [ShrinkCandidate]) async {
        guard let serial, let tool = Self.tools["chdman"] ?? nil else {
            toast?("wrench.and.screwdriver", "chdman is missing from this copy of Bifrost")
            return
        }
        var done: [ShrinkDone] = []
        var failed: [String] = []
        var saved: Int64 = 0
        for (index, candidate) in queue.enumerated() {
            if Task.isCancelled { break }
            shrinkProgress = ShrinkProgress(index: index + 1, total: queue.count, name: candidate.name, step: "Preparing", fraction: nil, saved: saved)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-shrink-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let free = (try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
            guard free > candidate.size * 2 + 1_000_000_000 else {
                toast?("externaldrive.badge.exclamationmark", "Not enough space on the Mac for \(candidate.name), stopped")
                break
            }
            if let result = await shrinkOne(candidate, work: work, tool: tool, serial: serial, index: index, total: queue.count, savedSoFar: saved) {
                done.append(result)
                saved += result.saved
                shrinkCandidates.removeAll { $0.id == candidate.id }
                shrinkSelection.remove(candidate.id)
                Log.write("shrink: \(candidate.name) \(candidate.size) -> \(result.newSize)")
                if removeOriginalsAfterShrink { await removeOriginals([result], announce: false) }
            } else if !Task.isCancelled {
                failed.append(candidate.name)
            }
        }
        let cancelled = Task.isCancelled
        if removeOriginalsAfterShrink || done.isEmpty {
            if !done.isEmpty { await refreshShrinkList() }
        } else {
            shrunk.append(contentsOf: done)
            askRemoveOriginals = true
        }
        var message = done.isEmpty ? "Nothing was shrunk" : "Shrunk \(done.count) of \(queue.count), saved \(saved.bytesText)"
        if !failed.isEmpty { message += ". Failed: \(failed.prefix(2).joined(separator: ", "))\(failed.count > 2 ? " and \(failed.count - 2) more" : "")" }
        if cancelled { message += ". Stopped" }
        if done.count > 0 && removeOriginalsAfterShrink { message += ". Rescan in Cocoon" }
        toast?(failed.isEmpty ? "arrow.down.right.and.arrow.up.left" : "exclamationmark.triangle", message)
    }

    private func shrinkOne(_ candidate: ShrinkCandidate, work: URL, tool: String, serial: String, index: Int, total: Int, savedSoFar: Int64) async -> ShrinkDone? {
        func report(_ step: String, _ fraction: Double?) {
            shrinkProgress = ShrinkProgress(index: index + 1, total: total, name: candidate.name, step: step, fraction: fraction, saved: savedSoFar)
        }
        report("Copying to the Mac", 0)
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                let have = (try? FileManager.default.subpathsOfDirectory(atPath: work.path))?.reduce(Int64(0)) { sum, sub in
                    sum + Int64((try? FileManager.default.attributesOfItem(atPath: work.appendingPathComponent(sub).path)[.size] as? Int) ?? 0)
                } ?? 0
                if candidate.size > 0 { self?.shrinkProgress?.fraction = min(1, Double(have) / Double(candidate.size)) }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        var pulled = true
        for remote in candidate.members {
            let process = ProcessHolder()
            let r = await withTaskCancellationHandler {
                try? await ADB.shared.run(["pull", remote, work.path], serial: serial, timeout: 0) { process.set($0) }
            } onCancel: { process.terminate() }
            if r?.ok != true { pulled = false; break }
        }
        poll.cancel()
        guard pulled, !Task.isCancelled else { return nil }

        let input = work.appendingPathComponent(candidate.name)
        let output = work.appendingPathComponent(candidate.outName)
        let box = ProgressBox()
        report("Compressing", 0)
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.shrinkProgress?.fraction = box.get()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let created = await Self.runTool(tool, [candidate.mode, "-i", input.path, "-o", output.path, "-f"]) { box.set($0) }
        ticker.cancel()
        guard created, !Task.isCancelled,
              let newSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), newSize > 0 else { return nil }

        report("Checking the new image", nil)
        let verifyBox = ProgressBox()
        let verifyTicker = Task { [weak self] in
            while !Task.isCancelled {
                self?.shrinkProgress?.fraction = verifyBox.get()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let verified = await Self.runTool(tool, ["verify", "-i", output.path]) { verifyBox.set($0) }
        verifyTicker.cancel()
        guard verified, !Task.isCancelled else { return nil }
        try? FileManager.default.removeItem(at: input)

        report("Sending back to the Thor", 0)
        let pushPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let size = Int64(((try? await ADB.shared.shell("stat -c %s \(ADB.quote(candidate.outPath)) 2>/dev/null", serial: serial, timeout: 5)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if !Task.isCancelled { self?.shrinkProgress?.fraction = min(1, Double(size) / Double(newSize)) }
            }
        }
        let pushProcess = ProcessHolder()
        let push = await withTaskCancellationHandler {
            try? await ADB.shared.run(["push", output.path, candidate.outPath], serial: serial, timeout: 0) { pushProcess.set($0) }
        } onCancel: { pushProcess.terminate() }
        pushPoll.cancel()
        let remoteSize = Int64(((try? await ADB.shared.shell("stat -c %s \(ADB.quote(candidate.outPath)) 2>/dev/null", serial: serial, timeout: 10)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard push?.ok == true, remoteSize == newSize, !Task.isCancelled else {
            _ = try? await ADB.shared.shell("rm -f \(ADB.quote(candidate.outPath))", serial: serial, timeout: 10)
            return nil
        }
        return ShrinkDone(candidate: candidate, newSize: newSize)
    }

    func removeOriginals(_ items: [ShrinkDone], announce: Bool = true) async {
        guard let serial, !items.isEmpty else { return }
        for item in items {
            let check = Int64(((try? await ADB.shared.shell("stat -c %s \(ADB.quote(item.candidate.outPath)) 2>/dev/null", serial: serial, timeout: 10)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard check == item.newSize else {
                Log.write("shrink: kept \(item.candidate.name), \(item.candidate.outName) is missing on the Thor")
                continue
            }
            _ = try? await ADB.shared.shell("rm -f " + item.candidate.members.map { ADB.quote($0) }.joined(separator: " "), serial: serial, timeout: 30)
            Log.write("shrink: removed original \(item.candidate.path) (\(item.candidate.members.count) files)")
        }
        await updateReferences(items, serial: serial)
        shrunk.removeAll { done in items.contains { $0.id == done.id } }
        if announce {
            let freed = items.reduce(0) { $0 + $1.candidate.size }
            toast?("trash", "Removed \(items.count == 1 ? "the original" : "\(items.count) originals"), \(freed.bytesText) back. Rescan in Cocoon")
            await refreshShrinkList()
        }
    }

    private func updateReferences(_ items: [ShrinkDone], serial: String) async {
        for (dir, group) in Dictionary(grouping: items, by: { $0.candidate.directory }) {
            let list = (try? await ADB.shared.shell("ls -1 \(ADB.quote(dir)) 2>/dev/null | grep -i '\\.m3u$'", serial: serial, timeout: 10)) ?? ""
            for name in list.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
                let path = dir + "/" + name
                guard let text = try? await ADB.shared.shell("cat \(ADB.quote(path))", serial: serial, timeout: 10) else { continue }
                var updated = text
                for item in group { updated = updated.replacingOccurrences(of: item.candidate.name, with: item.candidate.outName) }
                if updated != text { await pushText(updated, to: path, serial: serial) }
            }
        }
        guard let cocoonRoot else { return }
        for (system, group) in Dictionary(grouping: items, by: { $0.candidate.system }) {
            guard let folder = folders[system] else { continue }
            let gamelist = cocoonRoot + "/gamelists/" + system + "/gamelist.xml"
            guard let xml = try? await ADB.shared.shell("cat \(ADB.quote(gamelist)) 2>/dev/null", serial: serial, timeout: 30), xml.contains("<gameList") else { continue }
            var updated = xml
            for item in group {
                let relative = "./" + String(item.candidate.path.dropFirst(folder.path.count + 1))
                let newRelative = ((relative as NSString).deletingLastPathComponent as NSString).appendingPathComponent(item.candidate.outName)
                updated = updated.replacingOccurrences(of: "<path>\(Self.xmlEscape(relative))</path>", with: "<path>\(Self.xmlEscape(newRelative))</path>")
            }
            guard updated != xml else { continue }
            let backup = URL(fileURLWithPath: LinkSettings.shared.saveBackupFolder).deletingLastPathComponent()
                .appendingPathComponent("Cocoon gamelists").appendingPathComponent("before shrink " + Self.stamp()).appendingPathComponent(system)
            try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try? xml.write(to: backup.appendingPathComponent("gamelist.xml"), atomically: true, encoding: .utf8)
            await pushText(updated, to: gamelist, serial: serial)
        }
    }

    private func pushText(_ text: String, to path: String, serial: String) async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? text.write(to: temp, atomically: true, encoding: .utf8)) != nil else { return }
        _ = try? await ADB.shared.run(["push", temp.path, path], serial: serial, timeout: 60)
    }

    private func refreshShrinkList() async {
        await scanShrinkCandidates()
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}

final class ProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    func set(_ p: Process) { lock.lock(); process = p; lock.unlock() }
    func terminate() { lock.lock(); let p = process; lock.unlock(); if p?.isRunning == true { p?.terminate() } }
}
