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
    var isZip: Bool { mode == "zip" }
    var outName: String { (name as NSString).deletingPathExtension + (isZip ? ".zip" : ".chd") }
    var outPath: String { directory + "/" + outName }
    var estimatedSavings: Int64 {
        switch mode {
        case "createdvd": return size * 25 / 100
        case "zip": return size * 35 / 100
        default: return size * 40 / 100
        }
    }
    var trackCount: Int { members.count - 1 }
}

struct ShrinkJob: Identifiable {
    enum Status: Equatable { case queued, running, done(Int64), failed(String), cancelled }
    let candidate: ShrinkCandidate
    var status: Status = .queued
    var step = "Waiting"
    var fraction: Double?
    var id: String { candidate.id }
    var isActive: Bool { status == .queued || status == .running }
}

struct ShrinkDone: Identifiable {
    let candidate: ShrinkCandidate
    let newSize: Int64
    var id: String { candidate.path }
    var saved: Int64 { candidate.size - newSize }
}

extension EmulationHub {
    static let shrinkSystems: [String: (exts: Set<String>, dvd: Bool)] = [
        "psx": (["cue", "iso"], false),
        "ps2": (["iso", "cue"], true),
        "psp": (["iso"], true),
        "dreamcast": (["gdi", "cue"], false),
        "saturn": (["cue", "iso"], false),
    ]

    static let zipSystems: [String: Set<String>] = [
        "gb": ["gb"], "gbc": ["gbc"], "gba": ["gba"], "nes": ["nes"], "fds": ["fds"],
        "snes": ["sfc", "smc"], "sfc": ["sfc", "smc"], "n64": ["z64", "n64", "v64"],
        "genesis": ["md", "gen", "smd", "bin"], "megadrive": ["md", "gen", "smd", "bin"],
        "mastersystem": ["sms"], "gamegear": ["gg"], "pcengine": ["pce"], "ngp": ["ngp"], "ngpc": ["ngc"],
        "atari2600": ["a26"], "atari7800": ["a78"], "lynx": ["lnx"], "wonderswan": ["ws"], "wonderswancolor": ["wsc"],
    ]

    var removeOriginalsAfterShrink: Bool {
        get { UserDefaults.standard.bool(forKey: "shrinkRemoveOriginals") }
        set { UserDefaults.standard.set(newValue, forKey: "shrinkRemoveOriginals"); objectWillChange.send() }
    }

    func scanShrinkCandidates() async {
        guard let serial else { return }
        var result: [ShrinkCandidate] = []
        let busy = Set(shrinkJobs.filter(\.isActive).map(\.id))
        for (system, exts) in Self.zipSystems {
            guard let folder = folders[system] else { continue }
            let q = ADB.quote(folder.path)
            guard let out = try? await ADB.shared.shell("find \(q) -maxdepth 3 -type f -exec stat -c '%s|%n' {} + 2>/dev/null", serial: serial, timeout: 60) else { continue }
            var sizes: [String: Int64] = [:]
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let size = Int64(parts[0]) else { continue }
                sizes[String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)] = size
            }
            let archived = Set(sizes.keys.filter { ["zip", "7z"].contains(($0 as NSString).pathExtension.lowercased()) }.map { ($0 as NSString).deletingPathExtension.lowercased() })
            for (path, size) in sizes {
                let ext = (path as NSString).pathExtension.lowercased()
                guard exts.contains(ext), size > 512_000,
                      !archived.contains((path as NSString).deletingPathExtension.lowercased()) else { continue }
                result.append(ShrinkCandidate(path: path, members: [path], system: system, size: size, mode: "zip"))
            }
        }
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
        shrinkCandidates = result.filter { !busy.contains($0.id) }.sorted { $0.size > $1.size }
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

    var shrinkActive: Bool { shrinkJobs.contains(where: \.isActive) }

    func shrinkSelected() {
        let picked = shrinkCandidates.filter { shrinkSelection.contains($0.id) }
        guard !picked.isEmpty else { return }
        shrinkJobs.removeAll { !$0.isActive }
        let known = Set(shrinkJobs.map(\.id))
        shrinkJobs.append(contentsOf: picked.filter { !known.contains($0.id) }.map { ShrinkJob(candidate: $0) })
        shrinkCandidates.removeAll { shrinkSelection.contains($0.id) }
        shrinkSelection.removeAll()
        guard shrinkTask == nil else { return }
        shrinkTask = Task { [weak self] in
            await self?.runShrinkQueue()
            self?.shrinkTask = nil
        }
    }

    func cancelShrink(_ id: String) {
        guard let index = shrinkJobs.firstIndex(where: { $0.id == id }), shrinkJobs[index].isActive else { return }
        let wasRunning = shrinkJobs[index].status == .running
        shrinkJobs[index].status = .cancelled
        shrinkJobs[index].step = "Cancelled"
        shrinkJobs[index].fraction = nil
        if wasRunning {
            shrinkItemTask?.cancel()
            shrinkProcesses.forEach { $0.terminate() }
        }
        Log.write("shrink: cancelled \(shrinkJobs[index].candidate.name)")
    }

    func cancelAllShrinks() {
        for job in shrinkJobs where job.isActive { cancelShrink(job.id) }
    }

    func clearFinishedShrinks() {
        shrinkJobs.removeAll { !$0.isActive }
    }

    private func updateJob(_ id: String, _ change: (inout ShrinkJob) -> Void) {
        guard let index = shrinkJobs.firstIndex(where: { $0.id == id }) else { return }
        guard shrinkJobs[index].status != .cancelled else { return }
        change(&shrinkJobs[index])
    }

    private func runShrinkQueue() async {
        guard let serial else { return }
        var done: [ShrinkDone] = []
        var failed: [String] = []
        while let job = shrinkJobs.first(where: { $0.status == .queued }) {
            let candidate = job.candidate
            updateJob(job.id) { $0.status = .running; $0.step = "Preparing" }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-shrink-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let free = (try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
            if free <= candidate.size * 2 + 1_000_000_000 {
                updateJob(job.id) { $0.status = .failed("Not enough space on the Mac") }
                try? FileManager.default.removeItem(at: work)
                continue
            }
            let itemTask = Task { [weak self] () -> ShrinkDone? in
                await self?.shrinkOne(candidate, work: work, serial: serial)
            }
            shrinkItemTask = itemTask
            let result = await itemTask.value
            shrinkItemTask = nil
            shrinkProcesses.removeAll()
            try? FileManager.default.removeItem(at: work)
            let cancelled = shrinkJobs.first(where: { $0.id == job.id })?.status == .cancelled
            if let result, !cancelled {
                done.append(result)
                updateJob(job.id) { $0.status = .done(result.saved); $0.step = "Saved \(result.saved.bytesText)"; $0.fraction = 1 }
                Log.write("shrink: \(candidate.name) \(candidate.size) -> \(result.newSize)")
                if removeOriginalsAfterShrink { await removeOriginals([result], announce: false) }
            } else if cancelled {
                if let result { _ = try? await ADB.shared.shell("rm -f \(ADB.quote(result.candidate.outPath))", serial: serial, timeout: 10) }
                shrinkCandidates.append(candidate)
                shrinkCandidates.sort { $0.size > $1.size }
            } else {
                failed.append(candidate.name)
                updateJob(job.id) { $0.status = .failed("Didn’t work, the original is untouched") }
                shrinkCandidates.append(candidate)
                shrinkCandidates.sort { $0.size > $1.size }
            }
        }
        guard !done.isEmpty || !failed.isEmpty else { return }
        let saved = done.reduce(Int64(0)) { $0 + $1.saved }
        if !removeOriginalsAfterShrink && !done.isEmpty {
            shrunk.append(contentsOf: done)
            askRemoveOriginals = true
        }
        var message = done.isEmpty ? "Nothing was shrunk" : "Shrunk \(done.count) game\(done.count == 1 ? "" : "s"), saved \(saved.bytesText)"
        if !failed.isEmpty { message += ". \(failed.count) failed" }
        if !done.isEmpty && removeOriginalsAfterShrink { message += ". Rescan in Cocoon" }
        toast?(failed.isEmpty ? "arrow.down.right.and.arrow.up.left" : "exclamationmark.triangle", message)
    }

    private func track(_ process: Process) {
        let holder = ProcessHolder()
        holder.set(process)
        shrinkProcesses.append(holder)
    }

    private func shrinkOne(_ candidate: ShrinkCandidate, work: URL, serial: String) async -> ShrinkDone? {
        let id = candidate.id
        func report(_ step: String, _ fraction: Double?) {
            updateJob(id) { $0.step = step; $0.fraction = fraction }
        }
        func advance(_ value: Double) {
            updateJob(id) { $0.fraction = max($0.fraction ?? 0, min(1, value)) }
        }
        if let files, !files.isIdle {
            report("Waiting for file transfers", nil)
            await files.waitUntilIdle()
        }
        guard !Task.isCancelled else { return nil }
        report("Copying to the Mac", 0)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                let have = (try? FileManager.default.subpathsOfDirectory(atPath: work.path))?.reduce(Int64(0)) { sum, sub in
                    sum + Int64((try? FileManager.default.attributesOfItem(atPath: work.appendingPathComponent(sub).path)[.size] as? Int) ?? 0)
                } ?? 0
                if candidate.size > 0, have > 0 { advance(Double(have) / Double(candidate.size)) }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        var pulled = true
        for remote in candidate.members {
            let r = try? await ADB.shared.run(["pull", remote, work.path], serial: serial, timeout: 0) { process in
                Task { @MainActor in self.track(process) }
            }
            if r?.ok != true || Task.isCancelled { pulled = false; break }
        }
        poll.cancel()
        guard pulled, !Task.isCancelled else { return nil }

        let input = work.appendingPathComponent(candidate.name)
        let output = work.appendingPathComponent(candidate.outName)
        let created: Bool
        if candidate.isZip {
            report("Zipping", nil)
            created = await Self.runTool("/usr/bin/zip", ["-9", "-j", "-X", "-q", output.path, input.path], onStart: { p in Task { @MainActor in self.track(p) } })
        } else {
            guard let tool = Self.tools["chdman"] ?? nil else { return nil }
            report("Compressing", 0)
            created = await Self.runTool(tool, [candidate.mode, "-i", input.path, "-o", output.path, "-f"],
                                         progress: { value in Task { @MainActor in advance(value) } },
                                         onStart: { p in Task { @MainActor in self.track(p) } })
        }
        guard created, !Task.isCancelled,
              let newSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), newSize > 0 else { return nil }

        report("Checking the new file", candidate.isZip ? nil : 0)
        let verified: Bool
        if candidate.isZip {
            verified = await Self.runTool("/usr/bin/unzip", ["-tqq", output.path], onStart: { p in Task { @MainActor in self.track(p) } })
        } else if let tool = Self.tools["chdman"] ?? nil {
            verified = await Self.runTool(tool, ["verify", "-i", output.path],
                                          progress: { value in Task { @MainActor in advance(value) } },
                                          onStart: { p in Task { @MainActor in self.track(p) } })
        } else {
            verified = false
        }
        guard verified, !Task.isCancelled else { return nil }
        try? FileManager.default.removeItem(at: input)

        if let files, !files.isIdle {
            report("Waiting for file transfers", nil)
            await files.waitUntilIdle()
        }
        guard !Task.isCancelled else { return nil }
        report("Sending back to the \(DeviceInfo.name)", 0)
        let pushPoll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let size = Int64(((try? await ADB.shared.shell("stat -c %s \(ADB.quote(candidate.outPath)) 2>/dev/null", serial: serial, timeout: 5)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if !Task.isCancelled, size > 0 { advance(Double(size) / Double(newSize)) }
            }
        }
        let push = try? await ADB.shared.run(["push", output.path, candidate.outPath], serial: serial, timeout: 0) { process in
            Task { @MainActor in self.track(process) }
        }
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
