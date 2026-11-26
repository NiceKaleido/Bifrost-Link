import Foundation
import CryptoKit

struct RecompaIndex: Codable {
    let schemaVersion: Int
    let generatedAt: String?
    let ports: [RecompaPort]
    let platforms: [RecompaPlatform]?
    let servers: RecompaServers?
}

struct RecompaServers: Codable {
    let catalog: [String]?
}

struct RecompaPlatform: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct RecompaReport: Codable, Hashable {
    let device: String
    let great: Int
    let playable: Int
    let broken: Int
    let lastTag: String?
}

struct RecompaFile: Codable, Hashable {
    let name: String
    let url: String
    let size: Int64?
    let sha256: String?
    let entry: RecompaZipEntry?
}

struct RecompaZipEntry: Codable, Hashable {
    let path: String
    let size: Int64?
    let sha256: String?
}

struct RecompaRelease: Codable, Hashable {
    let tag: String
    let name: String?
    let publishedAt: String?
    let prerelease: Bool?
    let asset: RecompaFile?

    var installHash: String? { asset?.entry?.sha256 ?? asset?.sha256 }
    var installSize: Int64? { asset?.entry?.size ?? asset?.size }
    var date: Date? { publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

struct RecompaFork: Codable, Hashable, Identifiable {
    let repo: String
    let downloads: Int?
    let release: RecompaRelease?
    let history: [RecompaRelease]?
    let package: String?
    let signerSha256: String?
    let reports: [RecompaReport]?
    let name: String?
    let channel: String?
    let dualScreen: Bool?
    var id: String { repo }
    var allReleases: [RecompaRelease] { (release.map { [$0] } ?? []) + (history ?? []) }
}

struct RecompaAccepted: Codable, Hashable {
    let sha1: String?
    let label: String?
    let format: String?
}

struct RecompaDelivery: Codable, Hashable {
    let mode: String
    let path: String?
}

struct RecompaAsset: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let accepted: [RecompaAccepted]?
    let convertFrom: [String]?
    let zipOk: Bool?
    let manual: Bool?
    let delivery: RecompaDelivery?
    let instructionsMd: String?
}

struct RecompaRequirements: Codable, Hashable {
    let abi: [String]?
    let minSdk: Int?
}

struct RecompaArt: Codable, Hashable {
    let cover: String?
    let hero: String?
    let screenshots: [String]?
}

struct RecompaPort: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let game: String?
    let originalPlatform: String
    let type: String
    let description: String?
    let forks: [RecompaFork]
    let requirements: RecompaRequirements?
    let assets: [RecompaAsset]?
    let art: RecompaArt?
    let genres: [String]?
    let reports: [RecompaReport]?
    let downloads: Int?
    let addedAt: String?
    let aliases: [String]?

    var typeTitle: String {
        switch type {
        case "recomp": return "Recompilation"
        case "decomp": return "Decompilation"
        case "source-port": return "Source port"
        case "emulator": return "Single-game emulator"
        default: return type.capitalized
        }
    }

    var dualScreen: Bool { forks.contains { $0.dualScreen == true } }
    var aliasNames: [String] { aliases ?? [] }
}

struct ThorRating: Hashable {
    var great = 0, playable = 0, broken = 0
    var total: Int { great + playable + broken }
    var score: Double { total == 0 ? -1 : (Double(great) * 2 + Double(playable)) / Double(total * 2) }

    init() {}

    init(_ reports: [RecompaReport]) {
        for report in reports where DeviceInfo.matches(report: report.device) {
            great += report.great
            playable += report.playable
            broken += report.broken
        }
    }

    var verdict: String {
        guard total > 0 else { return "No \(DeviceInfo.name) reports" }
        if great >= playable && great >= broken { return "Great on \(DeviceInfo.name)" }
        if broken > great + playable { return "Broken on \(DeviceInfo.name)" }
        return "Playable on \(DeviceInfo.name)"
    }
}

struct InstalledPort: Hashable {
    let package: String
    let versionName: String
    let hash: String
    var portId: String?
    var repo: String?
    var tag: String?
    var exact: Bool
}

struct PortJob: Identifiable, Equatable {
    enum Status: Equatable {
        case queued, downloading, verifying, installing, done, failed(String), cancelled, needsUninstall
    }
    let id = UUID()
    let portName: String
    let package: String
    let repo: String
    let release: RecompaRelease
    var status: Status = .queued
    var fraction: Double?
    var isActive: Bool {
        switch status {
        case .queued, .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

struct LibraryMatch: Identifiable, Hashable {
    let portId: String
    let path: String
    let exact: Bool
    let label: String
    var id: String { portId + "|" + path }
    var fileName: String { (path as NSString).lastPathComponent }
}

struct GameFileMatch: Identifiable, Hashable {
    let path: String
    let label: String
    let onThor: Bool
    var id: String { path }
}

@MainActor
final class PortCatalog: ObservableObject {
    @Published private(set) var index: RecompaIndex?
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    @Published private(set) var updated: Date?
    @Published private(set) var installed: [String: InstalledPort] = [:]
    @Published private(set) var detecting = false
    @Published var jobs: [PortJob] = []
    @Published private(set) var gameFiles: [String: [GameFileMatch]] = [:]
    @Published private(set) var searchingFiles: Set<String> = []
    @Published private(set) var libraryMatches: [String: [LibraryMatch]] = [:]
    @Published private(set) var matchingLibrary = false
    @Published private(set) var libraryMatchedAt: Date?
    var serial: String?
    var romFolders: (() -> [String: String])?
    var backups: SaveBackupService?
    var toast: ((String, String) -> Void)?
    private var sdk = 33
    private var abis: [String] = ["arm64-v8a"]
    private var runner: Task<Void, Never>?
    private var currentDownload: URLSessionDownloadTask?
    private var lastFetch = Date.distantPast

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bifrost Link")
    private var cacheFile: URL { folder.appendingPathComponent("recompa-index.json") }
    static let defaultServers = ["https://recompa.app/index.json", "https://files.recompa.app/index.json", "https://recompa-web.recompa.workers.dev/files/index.json"]

    init() {
        if let data = try? Data(contentsOf: cacheFile), let decoded = Self.decode(data) {
            index = decoded
            updated = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    nonisolated private static func decode(_ data: Data) -> RecompaIndex? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(RecompaIndex.self, from: data), decoded.schemaVersion == 1 else { return nil }
        return decoded
    }

    var ports: [RecompaPort] { index?.ports ?? [] }
    var platforms: [RecompaPlatform] { index?.platforms ?? [] }

    func platformName(_ id: String) -> String { platforms.first { $0.id == id }?.name ?? id.uppercased() }

    func rating(_ port: RecompaPort) -> ThorRating {
        ThorRating((port.reports ?? []) + port.forks.flatMap { $0.reports ?? [] })
    }

    func rating(_ fork: RecompaFork) -> ThorRating { ThorRating(fork.reports ?? []) }

    var packages: Set<String> { Set(ports.flatMap { $0.forks.compactMap(\.package) }) }

    func refresh(force: Bool = false) async {
        // Some ports publish several releases a day, so the catalog is checked hourly.
        guard !loading, force || Date().timeIntervalSince(lastFetch) > 3600 || index == nil else { return }
        loading = true
        defer { loading = false }
        let servers = index?.servers?.catalog?.filter { $0.hasPrefix("https://") } ?? Self.defaultServers
        for server in servers {
            guard let url = URL(string: server) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("BifrostLink", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            guard let decoded = await Task.detached(operation: { Self.decode(data) }).value else {
                problem = "The Recompa catalog changed its format. Showing the last copy that worked."
                continue
            }
            index = decoded
            updated = Date()
            lastFetch = Date()
            problem = nil
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            Log.write("recompa catalog: \(decoded.ports.count) ports from \(url.host ?? server)")
            return
        }
        if index == nil { problem = "The Recompa catalog couldn’t be loaded. Check your internet connection." }
        else if problem == nil { problem = "Couldn’t reach Recompa, showing the copy from \(updated?.formatted(date: .abbreviated, time: .shortened) ?? "earlier")." }
    }

    private var forkChoices: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "portForkChoice") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "portForkChoice") }
    }

    private var installedTags: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "portInstalledTags") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "portInstalledTags") }
    }

    func chooseFork(_ repo: String, for package: String) {
        forkChoices[package] = repo
        if var entry = installed[package] {
            entry.repo = repo
            entry.portId = ports.first { $0.forks.contains { $0.repo == repo } }?.id
            installed[package] = entry
        }
    }

    func reset(serial: String?) {
        self.serial = serial
        if serial == nil { installed = [:] }
    }

    func detectInstalled() async {
        guard let serial, !detecting, index != nil else { return }
        detecting = true
        defer { detecting = false }
        let props = (try? await ADB.shared.shell("getprop ro.build.version.sdk; getprop ro.product.cpu.abilist", serial: serial, timeout: 5)) ?? ""
        let lines = props.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        if let first = lines.first, let value = Int(first) { sdk = value }
        if lines.count > 1 { abis = lines[1].split(separator: ",").map(String.init) }
        let list = (try? await ADB.shared.shell("pm list packages -3", serial: serial, timeout: 20)) ?? ""
        let present = Set(list.split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        let candidates = packages.intersection(present).sorted()
        guard !candidates.isEmpty else {
            installed = [:]
            return
        }
        let script = candidates.map { pkg in
            "p=$(pm path \(pkg) | head -1 | cut -d: -f2); h=$(sha256sum \"$p\" 2>/dev/null | cut -d' ' -f1); v=$(dumpsys package \(pkg) | grep -m1 versionName | cut -d= -f2); echo \"\(pkg)|$h|$v\""
        }.joined(separator: "; ")
        let out = (try? await ADB.shared.shell(script, serial: serial, timeout: 120)) ?? ""
        var hashIndex: [String: (port: String, repo: String, tag: String)] = [:]
        for port in ports {
            for fork in port.forks {
                for release in fork.allReleases {
                    if let hash = release.installHash { hashIndex[hash] = (port.id, fork.repo, release.tag) }
                    if let zip = release.asset?.sha256, release.asset?.entry == nil { hashIndex[zip] = (port.id, fork.repo, release.tag) }
                }
            }
        }
        var result: [String: InstalledPort] = [:]
        let choices = forkChoices
        let tags = installedTags
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 else { continue }
            let (package, hash, version) = (parts[0], parts[1], parts[2])
            var entry = InstalledPort(package: package, versionName: version, hash: hash, exact: false)
            if let match = hashIndex[hash] {
                entry.portId = match.port
                entry.repo = match.repo
                entry.tag = match.tag
                entry.exact = true
            } else {
                let owners = ports.flatMap { port in port.forks.filter { $0.package == package }.map { (port.id, $0.repo) } }
                if let chosen = choices[package], let owner = owners.first(where: { $0.1 == chosen }) {
                    entry.portId = owner.0
                    entry.repo = owner.1
                } else if owners.count == 1 {
                    entry.portId = owners[0].0
                    entry.repo = owners[0].1
                }
                if let remembered = tags[package] {
                    let pieces = remembered.split(separator: "|", maxSplits: 1).map(String.init)
                    if pieces.count == 2, pieces[0] == entry.repo { entry.tag = pieces[1] }
                }
            }
            result[package] = entry
        }
        installed = result
        Log.write("recompa: \(result.count) installed port(s), \(result.values.filter(\.exact).count) matched exactly, \(updates.count) update(s)")
    }

    func installedEntry(for fork: RecompaFork) -> InstalledPort? {
        guard let package = fork.package, let entry = installed[package] else { return nil }
        return entry
    }

    func isInstalled(_ fork: RecompaFork) -> Bool {
        guard let entry = installedEntry(for: fork) else { return false }
        return entry.repo == nil || entry.repo == fork.repo
    }

    func hasUpdate(_ fork: RecompaFork) -> Bool {
        guard let entry = installedEntry(for: fork), entry.repo == fork.repo, let latest = fork.release else { return false }
        if entry.exact { return entry.tag != latest.tag }
        if let tag = entry.tag { return tag != latest.tag }
        return false
    }

    func isInstalled(_ port: RecompaPort) -> Bool { port.forks.contains(where: isInstalled) }

    func installedFork(_ port: RecompaPort) -> RecompaFork? {
        port.forks.first { fork in
            guard let entry = installedEntry(for: fork) else { return false }
            return entry.repo == fork.repo
        } ?? port.forks.first(where: isInstalled)
    }

    var updates: [(port: RecompaPort, fork: RecompaFork)] {
        ports.flatMap { port in port.forks.filter(hasUpdate).map { (port, $0) } }
    }

    func ambiguous(_ port: RecompaPort) -> [RecompaFork]? {
        for fork in port.forks {
            guard let package = fork.package, let entry = installed[package], entry.repo == nil else { continue }
            let owners = ports.flatMap { $0.forks.filter { $0.package == package } }
            if owners.count > 1 { return owners }
        }
        return nil
    }

    func compatibility(_ port: RecompaPort) -> String? {
        if let minSdk = port.requirements?.minSdk, minSdk > sdk { return "Needs Android SDK \(minSdk), the \(DeviceInfo.name) has \(sdk)" }
        if let wanted = port.requirements?.abi, !wanted.isEmpty, !wanted.contains(where: abis.contains) { return "Built for \(wanted.joined(separator: ", ")), not the \(DeviceInfo.name)’s processor" }
        return nil
    }

    func install(_ port: RecompaPort, fork: RecompaFork, release: RecompaRelease? = nil) {
        // "Install"/"Update" means the newest release *now*: re-check the catalog first unless it's
        // only a few minutes old, so an already-outdated version isn't installed.
        guard release == nil, Date().timeIntervalSince(lastFetch) > 300 else {
            enqueue(port, fork: fork, release: release)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refresh(force: true)
            let freshPort = self.ports.first { $0.id == port.id } ?? port
            let freshFork = freshPort.forks.first { $0.repo == fork.repo } ?? fork
            if let newer = freshFork.release?.tag, newer != fork.release?.tag {
                Log.write("recompa: \(port.name) newest release is now \(newer) (catalog was \(fork.release?.tag ?? "?"))")
            }
            self.enqueue(freshPort, fork: freshFork, release: nil)
        }
    }

    private func enqueue(_ port: RecompaPort, fork: RecompaFork, release: RecompaRelease?) {
        guard let package = fork.package, let chosen = release ?? fork.release, chosen.asset != nil else {
            toast?("exclamationmark.triangle", "\(port.name) has no installable release")
            return
        }
        guard !jobs.contains(where: { $0.package == package && $0.isActive }) else { return }
        jobs.append(PortJob(portName: port.name, package: package, repo: fork.repo, release: chosen))
        run()
    }

    func updateAll() {
        Task { [weak self] in
            guard let self else { return }
            await self.refresh(force: true)
            for item in self.updates { self.enqueue(item.port, fork: item.fork, release: nil) }
        }
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].status == .queued {
            jobs[i].status = .cancelled
        } else if jobs[i].isActive {
            jobs[i].status = .cancelled
            currentDownload?.cancel()
        }
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    private func run() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let i = self.jobs.firstIndex(where: { $0.status == .queued }) {
                await self.process(self.jobs[i].id)
            }
            self?.runner = nil
        }
    }

    private func update(_ id: UUID, _ change: (inout PortJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func status(_ id: UUID) -> PortJob.Status? { jobs.first { $0.id == id }?.status }

    private func process(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), let asset = job.release.asset, let url = URL(string: asset.url) else { return }
        guard let serial else {
            update(id) { $0.status = .failed("The \(DeviceInfo.name) isn’t linked") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-port-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        update(id) { $0.status = .downloading; $0.fraction = 0 }
        let downloaded = work.appendingPathComponent(asset.name)
        let ok = await download(url, to: downloaded) { [weak self] fraction in self?.update(id) { $0.fraction = fraction } }
        guard status(id) != .cancelled else { return }
        guard ok else {
            update(id) { $0.status = .failed("Download failed") }
            return
        }
        update(id) { $0.status = .verifying; $0.fraction = nil }
        if let expected = asset.sha256?.lowercased(), await Self.sha256(downloaded) != expected {
            update(id) { $0.status = .failed("The download doesn’t match the catalog’s checksum, nothing was installed") }
            Log.write("recompa: checksum mismatch for \(asset.name)")
            return
        }
        var apk = downloaded
        if let entry = asset.entry {
            apk = work.appendingPathComponent("port.apk")
            guard await Self.unzip(downloaded, entry: entry.path, to: apk) else {
                update(id) { $0.status = .failed("The APK couldn’t be taken out of the zip") }
                return
            }
            if let expected = entry.sha256?.lowercased(), await Self.sha256(apk) != expected {
                update(id) { $0.status = .failed("The APK inside the zip doesn’t match the catalog, nothing was installed") }
                return
            }
        }
        if let aapt = EmulatorUpdater.aapt {
            let badging = await Self.run(aapt, ["dump", "badging", apk.path])
            let name = badging.range(of: #"package: name='([^']+)'"#, options: .regularExpression)
                .map { String(badging[$0]).replacingOccurrences(of: "package: name='", with: "").replacingOccurrences(of: "'", with: "") }
            guard name == job.package else {
                update(id) { $0.status = .failed("The APK is \(name ?? "an unknown app"), not \(job.package)") }
                return
            }
        }
        guard status(id) != .cancelled else { return }
        update(id) { $0.status = .installing }
        let result = try? await ADB.shared.run(["install", "-r", "-d", apk.path], serial: serial, timeout: 900)
        let output = (result?.stdout ?? "") + (result?.stderr ?? "")
        if result?.ok == true && output.contains("Success") {
            update(id) { $0.status = .done }
            var tags = installedTags
            tags[job.package] = job.repo + "|" + job.release.tag
            installedTags = tags
            forkChoices[job.package] = job.repo
            Log.write("recompa: installed \(job.package) \(job.repo) \(job.release.tag)")
            toast?("arrow.down.app", "\(job.portName) \(job.release.tag) is installed")
            await detectInstalled()
        } else if output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || output.contains("INSTALL_FAILED_VERSION_DOWNGRADE") {
            update(id) { $0.status = .needsUninstall }
        } else {
            let reason = output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("INSTALL_") }.map(String.init) ?? "unknown error"
            update(id) { $0.status = .failed(reason) }
        }
    }

    func uninstallAndInstall(_ id: UUID) async {
        guard let serial, let job = jobs.first(where: { $0.id == id }) else { return }
        let dataPath = "/sdcard/Android/data/\(job.package)"
        if let backups {
            update(id) { $0.status = .installing; $0.fraction = nil }
            _ = await backups.backup(label: "Before reinstall", only: [(emulator: job.portName, remote: dataPath, custom: true)])
        }
        _ = try? await ADB.shared.shell("pm uninstall \(ADB.quote(job.package))", serial: serial, timeout: 60)
        Log.write("recompa: uninstalled \(job.package) to switch to \(job.repo)")
        update(id) { $0.status = .queued }
        run()
    }

    private func download(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            var request = URLRequest(url: url)
            request.setValue("BifrostLink", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: request) { temp, response, _ in
                guard let temp, (response as? HTTPURLResponse)?.statusCode == 200,
                      (try? FileManager.default.moveItem(at: temp, to: destination)) != nil else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
            currentDownload = task
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let value = p.fractionCompleted
                DispatchQueue.main.async { progress(value) }
            }
            objc_setAssociatedObject(task, "bifrostProgress", observation, .OBJC_ASSOCIATION_RETAIN)
            task.resume()
        }
    }

    nonisolated static func sha256(_ url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    nonisolated static func sha1(_ url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            var hasher = Insecure.SHA1()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    nonisolated private static func unzip(_ zip: URL, entry: String, to output: URL) async -> Bool {
        await Task.detached {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: output) else { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", zip.path, entry]
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            try? handle.close()
            return process.terminationStatus == 0 && FileService.localSize(output) > 0
        }.value
    }

    nonisolated private static func run(_ path: String, _ args: [String]) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    static let systemFolders: [String: String] = [
        "n64": "n64", "gamecube": "gc", "wii": "wii", "ds": "nds", "switch": "switch", "gba": "gba", "gbc": "gbc", "gb": "gb",
        "snes": "snes", "nes": "nes", "genesis": "genesis", "ps1": "psx", "ps2": "ps2", "psp": "psp", "xbox": "xbox", "3ds": "n3ds",
        "mastersystem": "mastersystem", "dreamcast": "dreamcast",
    ]

    func findGameFiles(_ port: RecompaPort, asset: RecompaAsset) async {
        let key = port.id + "/" + asset.id
        guard let serial, let accepted = asset.accepted, !accepted.isEmpty, !searchingFiles.contains(key) else { return }
        searchingFiles.insert(key)
        defer { searchingFiles.remove(key) }
        let folders = romFolders?() ?? [:]
        var roots: [String] = []
        if let system = Self.systemFolders[port.originalPlatform], let path = folders[system] { roots.append(path) }
        if roots.isEmpty { roots = Array(folders.values) }
        let extensions = Set(accepted.compactMap { $0.format?.lowercased() })
        guard !roots.isEmpty, !extensions.isEmpty else {
            gameFiles[key] = []
            return
        }
        let names = extensions.map { "-iname '*.\($0)'" }.joined(separator: " -o ")
        let command = "find \(roots.map(ADB.quote).joined(separator: " ")) -maxdepth 2 -type f \\( \(names) \\) -exec sha1sum {} + 2>/dev/null"
        let out = (try? await ADB.shared.shell(command, serial: serial, timeout: 300)) ?? ""
        var matches: [GameFileMatch] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let hit = accepted.first(where: { $0.sha1?.lowercased() == parts[0].lowercased() }) else { continue }
            matches.append(GameFileMatch(path: parts[1], label: hit.label ?? "Verified", onThor: true))
        }
        gameFiles[key] = matches
    }

    func deliveryFolder(_ port: RecompaPort, asset: RecompaAsset) -> String {
        if let path = asset.delivery?.path, !path.isEmpty {
            return "/sdcard/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "/sdcard/Recompa/" + port.name.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression)
    }

    func deliver(_ match: GameFileMatch, port: RecompaPort, asset: RecompaAsset) async {
        guard let serial else { return }
        let target = deliveryFolder(port, asset: asset)
        let name = (match.path as NSString).lastPathComponent
        let ok: Bool
        if match.onThor {
            let out = (try? await ADB.shared.shell("mkdir -p \(ADB.quote(target)) && cp \(ADB.quote(match.path)) \(ADB.quote(target + "/" + name)) && echo ok", serial: serial, timeout: 600)) ?? ""
            ok = out.contains("ok")
        } else {
            _ = try? await ADB.shared.shell("mkdir -p \(ADB.quote(target))", serial: serial, timeout: 10)
            ok = (try? await ADB.shared.run(["push", match.path, target + "/" + name], serial: serial, timeout: 0))?.ok == true
        }
        Log.write("recompa: delivered \(name) for \(port.name) to \(target): \(ok)")
        toast?(ok ? "checkmark.circle" : "exclamationmark.triangle", ok ? "\(name) is in \(target.replacingOccurrences(of: "/sdcard/", with: "Internal/"))" : "Couldn’t copy \(name) to the \(DeviceInfo.name)")
    }

    func checkLocal(_ url: URL, port: RecompaPort, asset: RecompaAsset) async -> GameFileMatch? {
        guard let accepted = asset.accepted else { return nil }
        var file = url
        let ext = url.pathExtension.lowercased()
        if let convert = asset.convertFrom, convert.contains(ext), let converted = Self.toZ64(url) { file = converted }
        let hash = await Self.sha1(file)
        guard let hit = accepted.first(where: { $0.sha1?.lowercased() == hash }) else { return nil }
        return GameFileMatch(path: file.path, label: hit.label ?? "Verified", onThor: false)
    }

    nonisolated static func toZ64(_ url: URL) -> URL? {
        guard var bytes = try? [UInt8](Data(contentsOf: url)), bytes.count >= 4 else { return nil }
        switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
        case (0x37, 0x80, 0x40, 0x12):
            for i in stride(from: 0, to: bytes.count - 1, by: 2) { bytes.swapAt(i, i + 1) }
        case (0x40, 0x12, 0x37, 0x80):
            for i in stride(from: 0, to: bytes.count - 3, by: 4) {
                bytes.swapAt(i, i + 3)
                bytes.swapAt(i + 1, i + 2)
            }
        default:
            return url
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".z64")
        try? Data(bytes).write(to: out)
        return out
    }

    nonisolated static func normalizedTitle(_ name: String) -> String {
        var text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        if let dot = text.range(of: #"\.[a-z0-9]{2,5}$"#, options: .regularExpression) { text.removeSubrange(dot) }
        text = text.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|\{[^}]*\}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&", with: " and ")
        text = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        text = text.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        var words = text.split(separator: " ").map(String.init).filter { $0 != "the" }
        if words.last == "64", words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }

    func scanLibraryMatches() async {
        guard let serial, !matchingLibrary, index != nil else { return }
        matchingLibrary = true
        defer { matchingLibrary = false }
        let folders = romFolders?() ?? [:]
        var byFolder: [String: [RecompaPort]] = [:]
        for port in ports {
            guard let system = Self.systemFolders[port.originalPlatform], let folder = folders[system] else { continue }
            byFolder[folder, default: []].append(port)
        }
        guard !byFolder.isEmpty else {
            libraryMatches = [:]
            libraryMatchedAt = Date()
            return
        }
        var result: [String: [LibraryMatch]] = [:]
        let listing = (try? await ADB.shared.shell(byFolder.keys.map { "find \(ADB.quote($0)) -maxdepth 2 -type f ! -name '.*' 2>/dev/null" }.joined(separator: "; "), serial: serial, timeout: 60)) ?? ""
        let files = listing.split(separator: "\n").map(String.init)
        let skip: Set<String> = ["txt", "xml", "cfg", "ini", "png", "jpg", "sav", "srm", "state"]
        for (folder, group) in byFolder {
            let inFolder = files.filter { $0.hasPrefix(folder + "/") && !skip.contains(($0 as NSString).pathExtension.lowercased()) }
            var titles: [String: [String]] = [:]
            for file in inFolder {
                titles[Self.normalizedTitle((file as NSString).lastPathComponent), default: []].append(file)
            }
            for port in group {
                let names = Set(([port.game, port.name] + (port.aliasNames)).compactMap { $0 }.map(Self.normalizedTitle).filter { $0.count >= 3 })
                for name in names {
                    for file in titles[name] ?? [] where !(result[port.id] ?? []).contains(where: { $0.path == file }) {
                        result[port.id, default: []].append(LibraryMatch(portId: port.id, path: file, exact: false, label: "Same game"))
                    }
                }
            }
            var hashes: [String: (port: RecompaPort, label: String)] = [:]
            var extensions = Set<String>()
            for port in group {
                for asset in port.assets ?? [] {
                    for accepted in asset.accepted ?? [] {
                        guard let sha1 = accepted.sha1?.lowercased(), let format = accepted.format?.lowercased(), format != "iso" else { continue }
                        hashes[sha1] = (port, accepted.label ?? "Verified copy")
                        extensions.insert(format)
                    }
                }
            }
            guard !extensions.isEmpty else { continue }
            let names = extensions.sorted().map { "-iname '*.\($0)'" }.joined(separator: " -o ")
            let out = (try? await ADB.shared.shell("find \(ADB.quote(folder)) -maxdepth 2 -type f \\( \(names) \\) -size -600M -exec sha1sum {} + 2>/dev/null", serial: serial, timeout: 300)) ?? ""
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let hit = hashes[parts[0].lowercased()] else { continue }
                var list = result[hit.port.id] ?? []
                list.removeAll { $0.path == parts[1] }
                list.insert(LibraryMatch(portId: hit.port.id, path: parts[1], exact: true, label: hit.label), at: 0)
                result[hit.port.id] = list
            }
        }
        libraryMatches = result
        libraryMatchedAt = Date()
        Log.write("recompa: \(result.count) port(s) match games in the Roms folders, \(result.values.filter { $0.contains(where: \.exact) }.count) exactly")
    }
}
