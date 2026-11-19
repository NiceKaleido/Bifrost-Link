import Foundation
import AppKit
import CryptoKit
import SwiftUI

struct BifrostRelease: Equatable {
    let version: String
    let dmg: URL
    let size: Int64
    let digest: String?
    let notes: String
}

@MainActor
final class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()
    static let repo = "NiceKaleido/Bifrost-Link"

    @Published private(set) var latest: BifrostRelease?
    @Published private(set) var checking = false
    @Published private(set) var installing: String?

    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    var isReleaseBuild: Bool { current.split(separator: ".").count >= 3 }

    static func compare(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    func checkOnLaunch() {
        guard isReleaseBuild, LinkSettings.shared.autoUpdateCheck else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BifrostLink", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            if manual { alert("Couldn’t check for updates", "GitHub didn’t answer. Check your internet connection and try again.") }
            return
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String ?? "").lowercased().hasSuffix(".dmg") }),
              let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            if manual { alert("No update", "The latest release has no disk image.") }
            return
        }
        let digest = (asset["digest"] as? String).map { $0.replacingOccurrences(of: "sha256:", with: "") }
        let release = BifrostRelease(version: version, dmg: link, size: Int64(asset["size"] as? Int ?? 0), digest: digest, notes: json["body"] as? String ?? "")
        latest = release
        Log.write("update check: current \(current), latest \(version)")
        guard isReleaseBuild || manual else { return }
        if Self.compare(current, version) {
            offer(release)
        } else if manual {
            alert("You’re up to date", isReleaseBuild ? "Bifrost Link \(current) is the latest version." : "This is a build made on this Mac (\(current)). The latest release is \(version).")
        }
    }

    private func offer(_ release: BifrostRelease) {
        let alert = NSAlert()
        alert.messageText = "Bifrost Link \(release.version) is available"
        let notes = release.notes.split(separator: "\n").filter { $0.hasPrefix("- ") }.prefix(8).joined(separator: "\n")
        alert.informativeText = "You have \(current).\n\n\(notes.isEmpty ? "" : notes + "\n\n")Bifrost installs it and restarts by itself; your settings stay."
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await install(release) }
        }
    }

    private func alert(_ title: String, _ text: String) {
        hideProgressPanel()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @Published private(set) var progress: Double?
    private var downloadTask: URLSessionDownloadTask?
    private var cancelled = false
    private var progressPanel: NSPanel?

    func cancelInstall() {
        cancelled = true
        downloadTask?.cancel()
    }

    private func showProgressPanel() {
        guard progressPanel == nil else { progressPanel?.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Updating Bifrost Link"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: UpdateProgressView(updater: self).preferredColorScheme(.dark))
        panel.center()
        panel.orderFrontRegardless()
        progressPanel = panel
    }

    private func hideProgressPanel() {
        progressPanel?.close()
        progressPanel = nil
    }

    private func download(_ url: URL, to destination: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { temp, response, _ in
                observation?.invalidate()
                guard let temp, (response as? HTTPURLResponse)?.statusCode == 200,
                      (try? FileManager.default.moveItem(at: temp, to: destination)) != nil else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in if self.downloadTask != nil { self.progress = fraction } }
            }
            downloadTask = task
            task.resume()
        }
    }

    func install(_ release: BifrostRelease) async {
        guard installing == nil else { return }
        installing = "Downloading \(release.version)…"
        progress = 0
        cancelled = false
        showProgressPanel()
        var handedOff = false
        defer {
            downloadTask = nil
            if !handedOff {
                installing = nil
                progress = nil
                hideProgressPanel()
            }
        }
        let work = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/BifrostLink/update")
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Bifrost-Link.dmg")
        guard await download(release.dmg, to: dmg) else {
            if cancelled {
                Log.write("update: download cancelled")
                return
            }
            hideProgressPanel()
            alert("Update failed", "The download didn’t complete.")
            return
        }
        downloadTask = nil
        installing = "Checking \(release.version)…"
        progress = nil
        if let expected = release.digest?.lowercased(), await PortCatalog.sha256(dmg) != expected {
            alert("Update stopped", "The download doesn’t match the release’s checksum, so nothing was changed.")
            return
        }
        installing = "Preparing \(release.version)…"
        progress = nil
        let mount = work.appendingPathComponent("mount")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard await Self.runDetached("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount.path, dmg.path]) == 0 else {
            alert("Update failed", "The disk image couldn’t be opened.")
            return
        }
        let staged = work.appendingPathComponent("Bifrost Link.app")
        let copied = await Self.runDetached("/usr/bin/ditto", [mount.appendingPathComponent("Bifrost Link.app").path, staged.path]) == 0
        _ = await Self.runDetached("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        guard copied else {
            alert("Update failed", "The new app couldn’t be copied out of the disk image.")
            return
        }
        let target = Bundle.main.bundleURL.path
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target).old"
        mv "\(target)" "\(target).old" && /usr/bin/ditto "\(staged.path)" "\(target)" && rm -rf "\(target).old"
        [ -d "\(target)" ] || mv "\(target).old" "\(target)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        /usr/bin/open "\(target)"
        rm -rf "\(work.path)"
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        Log.write("update: installing \(release.version) over \(current)")
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "nohup /bin/sh \"\(script.path)\" >/dev/null 2>&1 &"]
        try? launcher.run()
        launcher.waitUntilExit()
        installing = "Restarting…"
        handedOff = true
        // Terminate from a fresh run-loop turn, not from inside this main-actor task:
        // applicationShouldTerminate replies via another main-actor task, which can't
        // run while this one is still on the stack, so calling terminate here deadlocks.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    nonisolated private static func runDetached(_ path: String, _ args: [String]) async -> Int32 {
        await Task.detached(priority: .userInitiated) { run(path, args) }.value
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private struct UpdateProgressView: View {
    @ObservedObject var updater: SelfUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(updater.installing ?? "Updating…").font(.callout.weight(.medium))
            if let progress = updater.progress {
                ProgressView(value: progress)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(updater.progress.map { "\(Int($0 * 100))%" } ?? "Bifrost restarts by itself when it’s done.")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if updater.progress != nil {
                    Button("Cancel") { updater.cancelInstall() }.controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
