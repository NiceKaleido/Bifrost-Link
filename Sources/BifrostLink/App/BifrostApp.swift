import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.installCrashHandlers()
        Log.write("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in DeviceManager.shared.boot() }
        if AudioStream.debug {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("eu.nicekaleido.bifrostlink.command"), object: nil, queue: .main) { note in
                let command = note.object as? String ?? ""
                Log.write("debug command: \(command)")
                Task { @MainActor in
                    let manager = DeviceManager.shared
                    switch command {
                    case "saveReplay": manager.saveReplay()
                    case "toggleRecording": manager.toggleRecording()
                    case "recordLayout": LinkSettings.shared.recordLayout = true
                    case "recordSeparate": LinkSettings.shared.recordLayout = false
                    case "layoutSideBySide": LinkSettings.shared.layout = .sideBySide
                    case "layoutStacked": LinkSettings.shared.layout = .stacked
                    case "screenshot": manager.screenshot()
                    case "libraryScan": Task { await manager.emulation.scan(); Log.write("library: \(manager.emulation.space.count) systems, \(manager.emulation.unsorted.count) unsorted, \(manager.emulation.orphanMedia.count) orphan media (\(manager.emulation.orphanMedia.reduce(0) { $0 + $1.size } / 1_048_576) MB), \(manager.emulation.orphanEntries.count) orphan entries, \(manager.emulation.bios.count) bios rows, \(manager.emulation.shrinkCandidates.count) shrink") }
                    case "cleanupScan": Task { await manager.cleanup.scan(); Log.write("cleanup: " + manager.cleanup.usage.map { "\($0.profile.name) \($0.byCategory.map { "\($0.key.rawValue)=\($0.value / 1_048_576)MB" }.sorted().joined(separator: " "))" }.joined(separator: " | ")) }
                    case _ where command.hasPrefix("import:"):
                        let url = URL(fileURLWithPath: String(command.dropFirst("import:".count)))
                        manager.emulation.prepareImport([url])
                        Log.write("import test: " + manager.emulation.importItems.map { "\($0.url.lastPathComponent) -> \($0.system) at \(manager.emulation.targetFolder(for: $0.system))" }.joined(separator: ", "))
                        Task { await manager.emulation.performImport() }
                    case "orphans":
                        for (system, list) in Dictionary(grouping: manager.emulation.orphanMedia, by: \.system) {
                            Log.write("orphans \(system): \(list.count) e.g. " + list.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: " ; "))
                        }
                    case "updates":
                        Task {
                            await manager.updater.check()
                            Log.write("updates: " + manager.updater.apps.map { "\($0.name) \($0.installedVersion) repo=\($0.repo ?? "-") latest=\($0.latestTag ?? "-") asset=\($0.assetName ?? "-") update=\($0.updateAvailable)" }.joined(separator: " | "))
                        }
                    case "cleanupTest":
                        Task {
                            let serial = manager.serial ?? ""
                            _ = try? await ADB.shared.shell("mkdir -p /data/local/tmp/bifrost-cleanup-test && echo x > /data/local/tmp/bifrost-cleanup-test/a.log", serial: serial)
                            let item = CleanupItem(emulator: "Test", package: "com.example.none", category: .junk, path: "/data/local/tmp/bifrost-cleanup-test", title: "test", bytes: 4096, modified: nil)
                            _ = await manager.cleanup.clean([item])
                            let left = (try? await ADB.shared.shell("ls -A /data/local/tmp/bifrost-cleanup-test | wc -l; rmdir /data/local/tmp/bifrost-cleanup-test", serial: serial)) ?? "?"
                            Log.write("cleanup test: entries left \(left.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    case "backup": Task { let url = await manager.backups.backup(label: "Test"); Log.write("backup: \(url?.lastPathComponent ?? "failed")") }
                    default: break
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await DeviceManager.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct BifrostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var manager = DeviceManager.shared
    @StateObject private var settings = LinkSettings.shared

    var body: some Scene {
        Window("Bifrost Link", id: "main") {
            ContentView(manager: manager, settings: settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1100, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("View Layout") {
                ForEach(ScreenLayout.allCases) { layout in
                    Button(layout.title) { settings.layout = layout }
                        .keyboardShortcut(KeyEquivalent(layout.shortcut), modifiers: .command)
                }
                Divider()
                Button("Swap Screens") { settings.swapped.toggle() }
                    .keyboardShortcut("0", modifiers: .command)
                Toggle("Cinema Mode", isOn: $settings.cinemaMode)
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Toggle("MetalFX Upscaling", isOn: $settings.upscaling)
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Toggle("Stats Overlay", isOn: $settings.statsOverlay)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Fit Window to Screens") { NotificationCenter.default.post(name: .bifrostFitWindow, object: nil) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("Bigger Overlay") { settings.overlayScale = min(0.6, settings.overlayScale + 0.05) }
                    .keyboardShortcut("+", modifiers: [.command, .option])
                Button("Smaller Overlay") { settings.overlayScale = max(0.15, settings.overlayScale - 0.05) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                Menu("Overlay Opacity") {
                    ForEach([1.0, 0.85, 0.7, 0.5], id: \.self) { value in
                        Button("\(Int(value * 100))%") { settings.overlayOpacity = value }
                    }
                }
            }
            CommandMenu("Device") {
                Button("Back") { manager.press(AndroidKey.back) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Home") { manager.press(AndroidKey.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Recent Apps") { manager.press(AndroidKey.appSwitch) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Notifications") { manager.expandNotifications() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Rotate") { manager.rotate() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Volume Up") { manager.press(AndroidKey.volumeUp) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Volume Down") { manager.press(AndroidKey.volumeDown) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Play / Pause") { manager.press(AndroidKey.mediaPlayPause) }
                Divider()
                Button("Close App in Front") { manager.closeForegroundApp() }
                    .keyboardShortcut("w", modifiers: [.command, .control])
                Button(settings.muted ? "Unmute" : "Mute") { manager.toggleMute() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Toggle Thor Screens") { manager.togglePanels() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(manager.mirroringPaused ? "Resume Mirroring" : "Pause Mirroring") { manager.toggleMirroring() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
                Button("Screenshot") { manager.screenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(manager.recording ? "Stop Recording" : "Start Recording") { manager.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Toggle("Record Window Layout", isOn: $settings.recordLayout)
                    .disabled(manager.recording)
                Button("Save Replay") { manager.saveReplay() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!settings.replayEnabled)
                Button("Files") { NotificationCenter.default.post(name: .bifrostToggleFiles, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Relink") {
                    Task {
                        await manager.unlink(reason: nil)
                        manager.retry()
                    }
                }
                Button("Unlink") { manager.disconnect() }
                    .disabled(manager.state != .linked)
            }
        }

        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(.dark)
        }
    }
}
