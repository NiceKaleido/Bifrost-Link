import Foundation

struct SideloadedApp: Identifiable, Hashable {
    let package: String
    let name: String
    let installedVersion: String
    var repo: String?
    var latestTag: String?
    var assetName: String?
    var assetURL: URL?
    var assetSize: Int64 = 0
    var note: String?
    var id: String { package }

    var updateAvailable: Bool {
        guard let latestTag, assetURL != nil else { return false }
        let tag = latestTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return !installedVersion.contains(tag) && !tag.contains(installedVersion)
    }
}

@MainActor
final class EmulatorUpdater: ObservableObject {
    @Published private(set) var apps: [SideloadedApp] = []
    @Published private(set) var checking = false
    @Published private(set) var installing: String?
    var serial: String?
    var toast: ((String, String) -> Void)?

    static let knownRepos: [String: String] = [
        "com.armsx2": "ARMSX2/ARMSX2",
    ]

    static let knownNames: [String: String] = Dictionary(uniqueKeysWithValues: Emulators.all.map { ($0.package, $0.name) }).merging([
        "com.rfandango.haku_x": "hakuX",
        "com.pokedaisy.app": "PokeDaisy",
        "com.stormpanda.betterdualscreenassistant": "Better Dual Screen Assistant",
        "com.med.sleepmanager": "Sleep Manager",
        "rip.moth.cocoonshell": "Cocoon",
    ]) { a, _ in a }

    private static let reposKey = "updateRepos"

    private var userRepos: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.reposKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.reposKey) }
    }

    static var aapt: String? {
        [Bundle.main.resourceURL?.appendingPathComponent("tools/aapt2").path,
         "/opt/homebrew/share/android-commandlinetools/build-tools/36.0.0/aapt2"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var excludedPackages: Set<String> = []

    func reset(serial: String?) {
        self.serial = serial
        apps = []
    }

    static func prettyName(_ package: String) -> String {
        let parts = package.split(separator: ".").map(String.init)
        let ignored: Set<String> = ["com", "org", "net", "io", "dev", "app", "android", "github", "me", "rip", "de", "eu"]
        let meaningful = parts.filter { !ignored.contains($0.lowercased()) }
        let pick = meaningful.last ?? parts.last ?? package
        let spaced = pick.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    func setRepo(_ input: String, for package: String) {
        var repo = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = repo.range(of: "github.com/") { repo = String(repo[range.upperBound...]) }
        repo = repo.split(separator: "/").prefix(2).joined(separator: "/")
        var repos = userRepos
        repos[package] = repo.isEmpty ? nil : repo
        userRepos = repos
        Task { await check() }
    }

    func check() async {
        guard let serial else { return }
        checking = true
        defer { checking = false }
        let list = (try? await ADB.shared.shell("pm list packages -3 -i", serial: serial, timeout: 20)) ?? ""
        var sideloaded: [String] = []
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let pkgPart = parts.first, pkgPart.hasPrefix("package:") else { continue }
            let package = String(pkgPart.dropFirst("package:".count))
            let installer = parts.first { $0.hasPrefix("installer=") }.map { String($0.dropFirst("installer=".count)) } ?? "null"
            if installer != "com.android.vending" && installer != package && !excludedPackages.contains(package) {
                sideloaded.append(package)
            }
        }
        let versionCommand = sideloaded.map { "echo \"\($0)|$(dumpsys package \($0) | grep -m1 versionName | cut -d= -f2)\"" }.joined(separator: "; ")
        let versions = (try? await ADB.shared.shell(versionCommand, serial: serial, timeout: 30)) ?? ""
        var result: [SideloadedApp] = []
        for line in versions.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let package = parts[0]
            var app = SideloadedApp(package: package, name: Self.knownNames[package] ?? Self.prettyName(package), installedVersion: parts[1].trimmingCharacters(in: .whitespaces),
                                    repo: userRepos[package] ?? Self.knownRepos[package])
            if let repo = app.repo { await fillRelease(&app, repo: repo) }
            result.append(app)
        }
        apps = result.sorted { ($0.updateAvailable ? 0 : 1, $0.repo == nil ? 1 : 0, $0.name.lowercased()) < ($1.updateAvailable ? 0 : 1, $1.repo == nil ? 1 : 0, $1.name.lowercased()) }
    }

    private func fillRelease(_ app: inout SideloadedApp, repo: String) async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BifrostLink", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            app.note = "No release found on GitHub"
            return
        }
        app.latestTag = json["tag_name"] as? String
        let assets = (json["assets"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String ?? "").lowercased().hasSuffix(".apk") }
        func score(_ name: String) -> Int {
            let n = name.lowercased()
            var s = 0
            if n.contains("a13") || n.contains("sdk33") { s += 6 }
            if n.contains("arm64") || n.contains("v8a") || n.contains("armv8") { s += 3 }
            if n.contains("x86") || n.contains("armeabi-v7a") { s -= 10 }
            if n.contains("legacy") || n.contains("debug") { s -= 4 }
            return s
        }
        if let best = assets.max(by: { score($0["name"] as? String ?? "") < score($1["name"] as? String ?? "") }) {
            app.assetName = best["name"] as? String
            app.assetURL = (best["browser_download_url"] as? String).flatMap(URL.init(string:))
            app.assetSize = Int64(best["size"] as? Int ?? 0)
        } else {
            app.note = "The latest release has no APK"
        }
    }

    func update(_ app: SideloadedApp) async {
        guard let serial, let url = app.assetURL else { return }
        guard let aapt = Self.aapt else {
            toast?("exclamationmark.triangle", "Can’t verify APKs on this Mac")
            return
        }
        installing = app.package
        defer { installing = nil }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-update-\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: local) }
        guard let (downloaded, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (try? FileManager.default.moveItem(at: downloaded, to: local)) != nil else {
            toast?("exclamationmark.triangle", "Download of \(app.name) failed")
            return
        }
        let badging = await Self.run(aapt, ["dump", "badging", local.path])
        let package = badging.range(of: #"package: name='([^']+)'"#, options: .regularExpression).map { String(badging[$0]).replacingOccurrences(of: "package: name='", with: "").replacingOccurrences(of: "'", with: "") }
        guard package == app.package else {
            Log.write("update refused: \(app.assetName ?? "?") is \(package ?? "unknown"), expected \(app.package)")
            toast?("hand.raised", "That download isn’t \(app.name), nothing was installed")
            return
        }
        let result = try? await ADB.shared.run(["install", "-r", local.path], serial: serial, timeout: 600)
        if result?.ok == true {
            Log.write("updated \(app.package) to \(app.latestTag ?? "?")")
            toast?("arrow.down.app", "\(app.name) is now \(app.latestTag ?? "up to date")")
            await check()
        } else {
            let reason = (result?.stdout ?? "").split(separator: "\n").last.map(String.init) ?? "unknown error"
            toast?("exclamationmark.triangle", "\(app.name) update failed: \(reason)")
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                continuation.resume(returning: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}
