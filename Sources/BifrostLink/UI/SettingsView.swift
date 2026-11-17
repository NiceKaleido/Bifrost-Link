import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: LinkSettings

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            picture.tabItem { Label("Picture", systemImage: "sparkles.tv") }
            capture.tabItem { Label("Capture", systemImage: "record.circle") }
            docking.tabItem { Label("Docking", systemImage: "laptopcomputer.and.arrow.down") }
            input.tabItem { Label("Input", systemImage: "gamecontroller") }
            emulation.tabItem { Label("Emulation", systemImage: "square.stack.3d.up") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Link automatically when the \(DeviceInfo.name) is plugged in", isOn: $settings.autoConnect)
                Toggle("Go full screen when it links", isOn: $settings.fullscreenOnLink)
                LoginItemToggle()
                Toggle("Show Bifrost in the menu bar", isOn: $settings.showMenuBar)
            } footer: {
                footer("Bifrost waits quietly and links as soon as your \(DeviceInfo.name) shows up over USB. With “Open at login” and the menu bar item, plugging in is all it takes.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $settings.autoUpdateCheck)
                LabeledContent("Version \(SelfUpdater.shared.current)") {
                    Button("Check Now") { Task { await SelfUpdater.shared.check(manual: true) } }
                }
            } footer: {
                footer("Bifrost looks for a new release on GitHub once a day and asks before installing it. Builds made on this Mac don’t update themselves.")
            }
            Section {
                folderRow("File downloads", path: $settings.downloadFolder)
            } footer: {
                footer("Where files from the \(DeviceInfo.name) land when you download them in the Files tab.")
            }
        }
        .formStyle(.grouped)
    }

    private var picture: some View {
        Form {
            Section("Look") {
                Toggle("Sharper picture with MetalFX upscaling", isOn: $settings.upscaling)
                Toggle("Cinema mode", isOn: $settings.cinemaMode)
                Toggle("Show the stats overlay", isOn: $settings.statsOverlay)
            }
            Section {
                Toggle("Show controls at the top edge in full screen", isOn: $settings.fullscreenControls)
                Toggle("Hide pop-up messages in full screen", isOn: $settings.quietFullscreen)
            } footer: {
                footer("Move the pointer to the top of the screen and the controls fade in; they slip away again on their own. With pop-ups hidden, messages like “Screenshot saved” or “Saves tucked away” stay out of your game while in full screen. ⌘F always leaves full screen.")
            }
            Section {
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodecKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: $settings.bitrateMbps) {
                    ForEach([4, 8, 12, 16, 24, 32, 48], id: \.self) { Text("\($0) Mbit/s").tag($0) }
                }
                Picker("Frame rate", selection: $settings.maxFps) {
                    ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Resolution", selection: $settings.maxSize) {
                    Text("Native").tag(0)
                    Text("1600 px").tag(1600)
                    Text("1280 px").tag(1280)
                    Text("1024 px").tag(1024)
                }
            } header: {
                Text("Stream")
            } footer: {
                footer("Stream changes apply the next time Bifrost links. Device ▸ Relink applies them right away.")
            }
        }
        .formStyle(.grouped)
    }

    private var capture: some View {
        Form {
            Section("Save to") {
                folderRow("Screenshots", path: $settings.screenshotFolder)
                folderRow("Recordings & replays", path: $settings.recordingFolder)
            }
            Section {
                Picker("Recording", selection: $settings.recordLayout) {
                    Text("Each screen as its own file").tag(false)
                    Text("The window layout as one video").tag(true)
                }
            } footer: {
                footer("Separate files keep the \(DeviceInfo.name)’s original picture untouched. The window layout records both screens exactly as you see them. While Cocoon is running a game, captures are named after it and filed in its own folder.")
            }
            Section {
                Toggle("Instant replay", isOn: $settings.replayEnabled)
                Picker("Keep the last", selection: $settings.replaySeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                .disabled(!settings.replayEnabled)
            } footer: {
                footer("Bifrost keeps the last moments in memory, so you can save that great play after it happened (⌥⌘S). Takes effect the next time the \(DeviceInfo.name) links.")
            }
        }
        .formStyle(.grouped)
    }

    private var docking: some View {
        Form {
            Section {
                Toggle("Keep the \(DeviceInfo.name) awake when the lid closes or power is pressed", isOn: $settings.keepAwake)
                Toggle("Turn the \(DeviceInfo.name)’s screens off while the lid is closed", isOn: $settings.panelsOffWhenClosed)
                    .disabled(!settings.keepAwake)
                Toggle("Turn the \(DeviceInfo.name)’s screens off as soon as it links", isOn: $settings.panelsOffOnLink)
                Toggle("Put the \(DeviceInfo.name) to sleep when unlinking with the lid closed", isOn: $settings.sleepOnUnlinkIfClosed)
            } footer: {
                footer("Docked like with HDMI: the \(DeviceInfo.name)’s own screens go dark while the mirror keeps running. Its power button switches them back on or off.")
            }
            Section {
                Toggle("Charging separation while linked", isOn: $settings.chargingSeparation)
            } footer: {
                footer("The \(DeviceInfo.name) runs straight from USB power instead of charging its battery, which keeps it cooler. Your own setting comes back when you unlink or unplug.")
            }
            Section {
                Toggle("Pause Sleep Manager while linked", isOn: $settings.pauseSleepManager)
            } footer: {
                footer("Sleep Manager’s closed-lid protection would switch Wi‑Fi off and lock the \(DeviceInfo.name) while it’s docked. Bifrost pauses it, keeps your usual Wi‑Fi and Bluetooth state, and hands everything back to Sleep Manager when you unlink, even if you just pull the cable.")
            }
        }
        .formStyle(.grouped)
    }

    private var input: some View {
        Form {
            Section {
                Toggle("Use controllers connected to the Mac", isOn: $settings.gamepadEnabled)
                Picker("Show up on the \(DeviceInfo.name) as", selection: $settings.controllerIdentity) {
                    ForEach(GamepadBridge.Identity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!settings.gamepadEnabled)
                Toggle("Pass rumble back to the controller", isOn: $settings.rumbleEnabled)
                    .disabled(!settings.gamepadEnabled || settings.controllerIdentity != "xbox")
                Toggle("Show a mouse pointer on the \(DeviceInfo.name)", isOn: $settings.hoverEnabled)
                LabeledContent("Buttons, keyboard & mouse") {
                    Button("Edit Controls…") { ControlsEditorWindow.open(manager: DeviceManager.shared) }
                }
            } footer: {
                footer("As an Odin Controller, apps treat your controller exactly like the \(DeviceInfo.name)’s built-in one, so your existing mappings just work. Rumble needs the Xbox identity, because Android only vibrates Xbox controllers here.")
            }
            Section {
                Toggle("Type with the Mac keyboard", isOn: $settings.macKeyboardTyping)
            } footer: {
                footer("Cocoon’s on-screen keyboard is made for controllers and turns Enter and the arrow keys into keyboard navigation. While linked, Bifrost switches it off so your Mac keyboard types normally, and switches it back on when you unlink. Turn this off if you’d rather type with a controller on Cocoon’s keyboard.")
            }
            Section("Mouse & trackpad") {
                LabeledContent("Click and drag", value: "Touch")
                LabeledContent("Right click", value: "Back")
                LabeledContent("Middle click", value: "Home")
                LabeledContent("Pinch", value: "Two-finger zoom")
                LabeledContent("⌘-drag the small screen", value: "Move or resize it")
                LabeledContent("Drop files on a screen", value: "ROMs are sorted, APKs installed")
            }
            Section("Keyboard") {
                LabeledContent("Typing", value: "Goes to the screen you clicked")
                LabeledContent("⌘C / ⌘V", value: "Copy from / paste to the \(DeviceInfo.name)")
            }
        }
        .formStyle(.grouped)
    }

    private var emulation: some View {
        Form {
            Section {
                folderRow("Save backups", path: $settings.saveBackupFolder)
                Toggle("Back up saves once a day when the \(DeviceInfo.name) links", isOn: $settings.autoSaveBackup)
                Picker("Keep", selection: $settings.saveBackupKeep) {
                    ForEach([3, 5, 10, 20, 50], id: \.self) { Text("The last \($0) backups").tag($0) }
                    Text("Every backup").tag(0)
                }
            } header: {
                Text("Save backups")
            } footer: {
                footer("Saves and states from your emulators are copied to the Mac. Once there are more backups than you keep, the oldest are replaced. Pinned backups are never replaced. Choose what gets backed up, and add your own folders, in the Saves tab.")
            }
            Section {
                Toggle("Check for port updates when the \(DeviceInfo.name) links", isOn: $settings.checkPortUpdates)
                Toggle("Show ports rated for the \(DeviceInfo.name) first", isOn: $settings.thorRatedFirst)
            } header: {
                Text("Native ports")
            } footer: {
                footer("Window ▸ Ports lists native ports of games for Android from the Recompa catalog (recompa.app), with ratings from other \(DeviceInfo.name) owners. Downloads come straight from each port’s GitHub page and are checked against the catalog before anything is installed.")
            }
            Section {
                LabeledContent("Disc image shrinking", value: EmulationHub.tools["chdman"].flatMap { $0 } != nil ? "Built in (chdman)" : "Unavailable")
            } footer: {
                footer("PlayStation, PlayStation 2, PSP, Dreamcast and Saturn images can be shrunk to CHD right from the Library tab, several at once.")
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.wrappedValue.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
                Button {
                    try? FileManager.default.createDirectory(atPath: path.wrappedValue, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path.wrappedValue))
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open in Finder")
                .accessibilityLabel("Open \(title) in Finder")
                if path.wrappedValue != LinkSettings.defaultFolder(for: title) {
                    Button("Reset") { path.wrappedValue = LinkSettings.defaultFolder(for: title) }
                }
            }
        }
    }
}

struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Open at login", isOn: Binding(get: { enabled }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    problem = nil
                } catch {
                    problem = "macOS didn’t allow it: \(error.localizedDescription)"
                }
                enabled = SMAppService.mainApp.status == .enabled
            }))
            if let problem { Text(problem).font(.caption2).foregroundStyle(.orange) }
        }
    }
}
