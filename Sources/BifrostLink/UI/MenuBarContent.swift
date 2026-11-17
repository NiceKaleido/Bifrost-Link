import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @ObservedObject var cocoon: CocoonBridge

    private var linked: Bool { manager.state == .linked }

    var body: some View {
        if linked {
            Text("\(manager.deviceName)\(manager.battery.map { " · \($0)%\(manager.charging ? " charging" : "")" } ?? "")")
            if let playing = cocoon.nowPlaying { Text("Playing \(playing.title)") }
        } else {
            Text("Waiting for your \(DeviceInfo.name)")
        }
        Divider()
        Button("Show Bifrost Link") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
        Divider()
        Button("Screenshot") { manager.screenshot() }.disabled(!linked)
        Button("Save Replay") { manager.saveReplay() }.disabled(!linked || !settings.replayEnabled)
        Button("Quick Save") { manager.quickState(.save) }.disabled(!linked)
        Button("Quick Load") { manager.quickState(.load) }.disabled(!linked)
        Button(settings.muted ? "Unmute" : "Mute") { manager.toggleMute() }.disabled(!linked)
        Button(manager.mirroringPaused ? "Resume Mirroring" : "Pause Mirroring") { manager.toggleMirroring() }.disabled(!linked)
        Divider()
        Button("Unlink") { manager.disconnect() }.disabled(!linked)
        Button("Quit Bifrost Link") { NSApp.terminate(nil) }
    }
}
