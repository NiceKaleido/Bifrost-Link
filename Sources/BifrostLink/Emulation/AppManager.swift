import Foundation
import AppKit

struct ThorApp: Identifiable, Hashable {
    let package: String
    var name: String
    var version: String
    var apkPath: String
    var appSize: Int64
    var dataSize: Int64
    var cacheSize: Int64
    var kind: String?
    var id: String { package }
    var total: Int64 { appSize + dataSize }
}

struct ApkBackup: Identifiable, Hashable {
    let package: String
    let version: String
    let folder: URL
    var id: URL { folder }
}

@MainActor
final class AppManager: ObservableObject {
    @Published private(set) var apps: [ThorApp] = []
    @Published private(set) var loading = false
    @Published private(set) var working: String?
    @Published private(set) var backups: [ApkBackup] = []
    @Published private(set) var serial: String?
    var names: ((String) -> String?)?
    var kinds: ((String) -> String?)?
    var toast: ((String, String) -> Void)?

    let backupRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bifrost Link/APKs")

    func reset(serial: String?) {
        if serial != self.serial { apps = [] }
        self.serial = serial
        loadBackups()
    }

    func refresh() async {
        guard let serial, !loading else { return }
        loading = true
        defer { loading = false }
        let list = (try? await ADB.shared.shell("pm list packages -3 -f", serial: serial, timeout: 20)) ?? ""
        var entries: [(String, String)] = []
        for line in list.split(separator: "\n") {
            var text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("package:") else { continue }
            text.removeFirst("package:".count)
            guard let eq = text.range(of: ".apk=", options: .backwards) else { continue }
            let path = String(text[..<eq.lowerBound]) + ".apk"
            let package = String(text[eq.upperBound...])
            entries.append((package, path))
        }
        let stats = (try? await ADB.shared.shell("dumpsys diskstats", serial: serial, timeout: 30)) ?? ""
        let sizes = Self.parseDiskstats(stats)
        let script = entries.map { "echo \"\($0.0)|$(dumpsys package \($0.0) | grep -m1 versionName | cut -d= -f2)\"" }.joined(separator: "; ")
        let versionOut = script.isEmpty ? "" : ((try? await ADB.shared.shell(script, serial: serial, timeout: 60)) ?? "")
        var versions: [String: String] = [:]
        for line in versionOut.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { versions[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        apps = entries.map { package, path in
            let size = sizes[package]
            return ThorApp(package: package, name: names?(package) ?? EmulatorUpdater.knownNames[package] ?? EmulatorUpdater.prettyName(package),
                           version: versions[package] ?? "", apkPath: path,
                           appSize: size?.0 ?? 0, dataSize: size?.1 ?? 0, cacheSize: size?.2 ?? 0, kind: kinds?(package))
        }.sorted { $0.total > $1.total }
    }

    static func parseDiskstats(_ text: String) -> [String: (Int64, Int64, Int64)] {
        func array(_ key: String) -> [String] {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(key + ":") }),
                  let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else { return [] }
            return line[line.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        }
        let names = array("Package Names")
        let app = array("App Sizes").map { Int64($0) ?? 0 }
        let data = array("App Data Sizes").map { Int64($0) ?? 0 }
        let cache = array("Cache Sizes").map { Int64($0) ?? 0 }
        var result: [String: (Int64, Int64, Int64)] = [:]
        for (i, name) in names.enumerated() {
            result[name] = (i < app.count ? app[i] : 0, i < data.count ? data[i] : 0, i < cache.count ? cache[i] : 0)
        }
        return result
    }

    private func run(_ title: String, _ command: String, timeout: TimeInterval = 60) async -> String {
        guard let serial else { return "" }
        working = title
        defer { working = nil }
        return (try? await ADB.shared.shell(command, serial: serial, timeout: timeout)) ?? ""
    }

    func open(_ app: ThorApp) async {
        let activity = (await run("Opening \(app.name)…", "cmd package resolve-activity --brief \(ADB.quote(app.package)) | tail -1")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard activity.contains("/") else {
            toast?("exclamationmark.triangle", "\(app.name) has nothing to open")
            return
        }
        _ = await run("Opening \(app.name)…", "am start -n \(ADB.quote(activity))")
    }

    func close(_ app: ThorApp) async {
        _ = await run("Closing \(app.name)…", "am force-stop \(ADB.quote(app.package))")
        toast?("xmark.app", "Closed \(app.name)")
    }

    func clearCache(_ app: ThorApp) async {
        let out = await run("Clearing \(app.name)’s cache…", "pm clear --cache-only \(ADB.quote(app.package)) 2>&1")
        toast?(out.contains("Success") ? "sparkles" : "exclamationmark.triangle", out.contains("Success") ? "Cleared \(app.cacheSize.bytesText) of cache from \(app.name)" : "Couldn’t clear \(app.name)’s cache")
        Log.write("apps: cleared cache of \(app.package): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        await refresh()
    }

    func clearData(_ app: ThorApp) async {
        let out = await run("Resetting \(app.name)…", "pm clear \(ADB.quote(app.package)) 2>&1")
        toast?(out.contains("Success") ? "arrow.counterclockwise" : "exclamationmark.triangle", out.contains("Success") ? "\(app.name) is reset to a fresh start" : "Couldn’t reset \(app.name)")
        Log.write("apps: cleared data of \(app.package): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        await refresh()
    }

    func uninstall(_ app: ThorApp, keepData: Bool) async {
        let out = await run("Removing \(app.name)…", "pm uninstall \(keepData ? "-k " : "")\(ADB.quote(app.package)) 2>&1")
        toast?(out.contains("Success") ? "trash" : "exclamationmark.triangle", out.contains("Success") ? "Removed \(app.name)" : "Couldn’t remove \(app.name)")
        Log.write("apps: uninstalled \(app.package) keepData=\(keepData): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        await refresh()
    }

    func backupAPK(_ app: ThorApp) async {
        guard let serial else { return }
        working = "Backing up \(app.name)…"
        defer { working = nil }
        let paths = ((try? await ADB.shared.shell("pm path \(ADB.quote(app.package))", serial: serial, timeout: 10)) ?? "")
            .split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let version = app.version.isEmpty ? "unknown" : app.version.replacingOccurrences(of: "/", with: "-")
        let folder = backupRoot.appendingPathComponent(app.package).appendingPathComponent(version)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ok = !paths.isEmpty
        for path in paths {
            let result = try? await ADB.shared.run(["pull", path, folder.appendingPathComponent((path as NSString).lastPathComponent).path], serial: serial, timeout: 0)
            if result?.ok != true { ok = false }
        }
        if ok {
            toast?("archivebox", "\(app.name) \(app.version) is backed up on this Mac")
        } else {
            try? FileManager.default.removeItem(at: folder)
            toast?("exclamationmark.triangle", "Couldn’t back up \(app.name)")
        }
        Log.write("apps: apk backup \(app.package) \(version): \(ok)")
        loadBackups()
    }

    func loadBackups() {
        let fm = FileManager.default
        var list: [ApkBackup] = []
        for package in (try? fm.contentsOfDirectory(atPath: backupRoot.path)) ?? [] where !package.hasPrefix(".") {
            let base = backupRoot.appendingPathComponent(package)
            for version in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where !version.hasPrefix(".") {
                list.append(ApkBackup(package: package, version: version, folder: base.appendingPathComponent(version)))
            }
        }
        backups = list.sorted { ($0.package, $0.version) < ($1.package, $1.version) }
    }

    func backups(for package: String) -> [ApkBackup] { backups.filter { $0.package == package } }

    func install(apks: [URL], title: String) async -> Bool {
        guard let serial, !apks.isEmpty else { return false }
        working = "Installing \(title)…"
        defer { working = nil }
        let args = (apks.count == 1 ? ["install", "-r", "-d"] : ["install-multiple", "-r", "-d"]) + apks.map(\.path)
        let result = try? await ADB.shared.run(args, serial: serial, timeout: 900)
        let output = (result?.stdout ?? "") + (result?.stderr ?? "")
        let ok = result?.ok == true && output.contains("Success")
        if ok {
            toast?("arrow.down.app", "\(title) is installed")
        } else {
            let reason = output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("INSTALL_") }.map(String.init) ?? "unknown error"
            toast?("exclamationmark.triangle", "\(title) couldn’t be installed: \(reason)")
        }
        Log.write("apps: install \(title): \(ok)")
        await refresh()
        return ok
    }

    func restore(_ backup: ApkBackup) async {
        let apks = ((try? FileManager.default.contentsOfDirectory(at: backup.folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "apk" }
        _ = await install(apks: apks.sorted { $0.lastPathComponent == "base.apk" && $1.lastPathComponent != "base.apk" }, title: "\(names?(backup.package) ?? backup.package) \(backup.version)")
    }

    func installDropped(_ urls: [URL]) async {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "apk" {
                _ = await install(apks: [url], title: url.deletingPathExtension().lastPathComponent)
            } else if ext == "apks" || ext == "xapk" || ext == "apkm" {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bifrost-apks-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Bundles can be hundreds of MB; unzip off the main thread so the app stays responsive.
                await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = ["-q", "-o", url.path, "*.apk", "-d", folder.path]
                    try? process.run()
                    process.waitUntilExit()
                }.value
                let apks = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "apk" }
                _ = await install(apks: apks, title: url.deletingPathExtension().lastPathComponent)
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
