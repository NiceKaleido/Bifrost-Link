import SwiftUI
import AppKit

@MainActor
enum ControlsEditorWindow {
    private static var window: NSWindow?

    static func open(manager: DeviceManager) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Controls"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ControlsEditor(manager: manager, cocoon: manager.cocoon).preferredColorScheme(.dark).tint(Theme.accent))
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                manager.gamepad.onInputs = nil
                self.window = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

struct ControlsEditor: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var cocoon: CocoonBridge
    @State private var scope = ControllerProfiles.everyone
    @State private var profile = ControllerProfile.standard
    @State private var hasOwn = false
    @State private var live: Set<PadInput> = []
    @State private var listening: PadInput?
    @State private var monitor: Any?
    @State private var shortcutsVersion = 0

    private var scopes: [(id: String, title: String)] {
        var list: [(String, String)] = []
        if let playing = cocoon.nowPlaying {
            list.append((LayoutProfiles.gameKey(playing), "Only \(playing.title)"))
            if !playing.isApp { list.append((LayoutProfiles.systemKey(playing.system), "All \(Systems.name(for: playing.system)) games")) }
        }
        list.append((ControllerProfiles.everyone, "Every game and app"))
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Form {
                shortcutsSection
                buttonsSection
                sticksSection
                keyboardSection
                mouseSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 600)
        .onAppear {
            scope = manager.controllerScope
            load()
            manager.gamepad.onInputs = { inputs in DispatchQueue.main.async { live = inputs } }
        }
        .onDisappear { stopListening() }
        .onChange(of: scope) { _, _ in load() }
        .onChange(of: profile) { _, _ in save() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Settings for", selection: $scope) {
                    ForEach(scopes, id: \.id) { Text($0.title).tag($0.id) }
                }
                .frame(maxWidth: 380)
                Spacer()
                Button("Reset") { profile = .standard }
                if hasOwn && scope != ControllerProfiles.everyone {
                    Button("Remove") {
                        ControllerProfiles.set(nil, for: scope)
                        manager.applyControllerProfile()
                        load()
                    }
                    .help("Use the broader settings again")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: manager.keyboardPad ? "keyboard.fill" : "keyboard").foregroundStyle(manager.keyboardPad ? Theme.accent : .secondary)
                Text(manager.keyboardPad ? "Keyboard plays as controller right now." : "Keyboard and mouse play as a controller after ⌃⌘K (Device ▸ Keyboard Plays as Controller).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(manager.keyboardPad ? "Type Again" : "Turn On") { manager.toggleKeyboardPad() }
                    .controlSize(.small)
                    .disabled(manager.state != .linked)
            }
            Text(hasOwn ? "Changes are saved right away." : "These are inherited. Changing anything saves them for this choice.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    private var shortcutsSection: some View {
        Section {
            Picker("Hold", selection: Binding(
                get: { _ = shortcutsVersion; return ShortcutStore.modifier?.rawValue ?? "off" },
                set: { ShortcutStore.modifier = PadInput(rawValue: $0); shortcutsVersion += 1 })) {
                Text("Home / Guide").tag(PadInput.home.rawValue)
                Text("Select / View").tag(PadInput.select.rawValue)
                Text("Off").tag("off")
            }
            if ShortcutStore.modifier != nil || shortcutsVersion < 0 {
                ForEach(ShortcutAction.allCases) { action in
                    Picker(action.title, selection: Binding(
                        get: { _ = shortcutsVersion; return ShortcutStore.button(for: action)?.rawValue ?? "off" },
                        set: { ShortcutStore.set(PadInput(rawValue: $0), for: action); shortcutsVersion += 1 })) {
                        Text("Off").tag("off")
                        ForEach(PadInput.buttons.filter { $0 != ShortcutStore.modifier }) { Text("+ \($0.title)").tag($0.rawValue) }
                    }
                }
                Button("Reset Shortcuts") { ShortcutStore.reset(); shortcutsVersion += 1 }
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Hold the button above and press another one. These work for every game with any controller connected to the Mac. Tapping Home on its own still goes Home. Quick save and load use the emulator’s own save-state keys: RetroArch and PPSSPP work out of the box; Dolphin, DuckStation, ARMSX2 and Azahar on Android don’t offer such keys.").font(.caption)
        }
    }

    private var buttonsSection: some View {
        Section {
            ForEach(PadInput.buttons) { input in
                HStack {
                    Circle().fill(live.contains(input) ? Theme.accent : Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                    Text(input.title).frame(width: 140, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    Picker(input.title, selection: Binding(
                        get: { profile.remap[input.rawValue] ?? input.rawValue },
                        set: { value in
                            if value == input.rawValue { profile.remap[input.rawValue] = nil } else { profile.remap[input.rawValue] = value }
                        })) {
                        Text("Same").tag(input.rawValue)
                        ForEach(PadInput.buttons.filter { $0 != input }) { Text($0.title).tag($0.rawValue) }
                        Text("Nothing").tag("none")
                    }
                    .labelsHidden()
                }
            }
        } header: {
            Text("Buttons")
        } footer: {
            Text("What each button of your controller (and each key below) does on the \(DeviceInfo.name). The dot lights up while you press it.").font(.caption)
        }
    }

    private var sticksSection: some View {
        Section("Sticks") {
            Toggle("Swap left and right stick", isOn: $profile.swapSticks)
            Toggle("Invert left stick up/down", isOn: $profile.invertLeftY)
            Toggle("Invert right stick up/down", isOn: $profile.invertRightY)
            LabeledContent("Dead zone") {
                Slider(value: $profile.deadzone, in: 0...0.4)
                Text("\(Int(profile.deadzone * 100))%").monospacedDigit().frame(width: 40)
            }
        }
    }

    private var keyboardSection: some View {
        Section {
            ForEach(PadInput.allCases) { input in
                HStack {
                    Text(input.title).frame(width: 160, alignment: .leading)
                    Spacer()
                    if listening == input {
                        Text("Press a key…").foregroundStyle(Theme.accent)
                        Button("Cancel") { stopListening() }.controlSize(.small)
                    } else {
                        Text(profile.keyCode(for: input).map { profile.label(for: $0) } ?? "–")
                            .font(.callout.monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                        Button("Change") { listen(for: input) }.controlSize(.small)
                        if profile.keyCode(for: input) != nil {
                            Button { clearKey(input) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Used while the keyboard plays as controller. Keys that aren’t assigned still type. ⌘ shortcuts always reach the Mac.").font(.caption)
        }
    }

    private var mouseSection: some View {
        Section {
            Picker("Mouse moves", selection: $profile.mouse) {
                ForEach(ControllerProfile.MouseMode.allCases) { Text($0.title).tag($0) }
            }
            if profile.mouse != .off {
                LabeledContent("Sensitivity") {
                    Slider(value: $profile.mouseSensitivity, in: 0.2...3)
                    Text(String(format: "%.1f×", profile.mouseSensitivity)).monospacedDigit().frame(width: 40)
                }
                clickPicker("Left click", value: $profile.leftClick)
                clickPicker("Right click", value: $profile.rightClick)
            }
        } header: {
            Text("Mouse")
        } footer: {
            Text("Click the screen to hand the mouse to the game; the pointer disappears. Esc, switching apps or ⌃⌘K gives it back.").font(.caption)
        }
    }

    private func clickPicker(_ title: String, value: Binding<String?>) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue ?? "none" }, set: { value.wrappedValue = $0 == "none" ? nil : $0 })) {
            Text("Nothing").tag("none")
            ForEach(PadInput.buttons) { Text($0.title).tag($0.rawValue) }
        }
    }

    private func load() {
        if let own = ControllerProfiles.get(scope) {
            profile = own
            hasOwn = true
        } else {
            let fallback: ControllerProfile
            if scope == ControllerProfiles.everyone {
                fallback = .standard
            } else if scope.hasPrefix("game:") || scope.hasPrefix("app:"), let playing = cocoon.nowPlaying, !playing.isApp {
                fallback = ControllerProfiles.get(LayoutProfiles.systemKey(playing.system)) ?? ControllerProfiles.get(ControllerProfiles.everyone) ?? .standard
            } else {
                fallback = ControllerProfiles.get(ControllerProfiles.everyone) ?? .standard
            }
            profile = fallback
            hasOwn = false
        }
    }

    private func save() {
        if !hasOwn, ControllerProfiles.get(scope) == nil, profile == loadedFallback() { return }
        ControllerProfiles.set(profile, for: scope)
        hasOwn = true
        manager.applyControllerProfile()
    }

    private func loadedFallback() -> ControllerProfile {
        if scope == ControllerProfiles.everyone { return .standard }
        if let playing = cocoon.nowPlaying, !playing.isApp, scope.hasPrefix("game:") {
            return ControllerProfiles.get(LayoutProfiles.systemKey(playing.system)) ?? ControllerProfiles.get(ControllerProfiles.everyone) ?? .standard
        }
        return ControllerProfiles.get(ControllerProfiles.everyone) ?? .standard
    }

    private func clearKey(_ input: PadInput) {
        for (key, value) in profile.keyboard where value == input.rawValue { profile.keyboard[key] = nil }
    }

    private func listen(for input: PadInput) {
        stopListening()
        listening = input
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let target = listening else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                stopListening()
                return nil
            }
            if event.type == .flagsChanged && !KeyMap.modifierKeyCodes.contains(event.keyCode) { return event }
            let code = String(event.keyCode)
            clearKey(target)
            profile.keyboard[code] = target.rawValue
            if event.type == .keyDown, let typed = event.charactersIgnoringModifiers?.uppercased(), typed.count == 1,
               let scalar = typed.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 {
                profile.keyLabels[code] = typed
            }
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = nil
    }
}
