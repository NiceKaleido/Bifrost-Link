import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @State private var showFiles = false
    @State private var showAudio = false
    @State private var isFullScreen = false
    @AppStorage("sidePanelWidth") private var panelWidth: Double = 380

    var body: some View {
        ZStack {
            if (isFullScreen || settings.cinemaMode) && (linked || !manager.screens.isEmpty) {
                Color.black.ignoresSafeArea()
            } else {
                AuroraBackground(intensity: manager.state == .linked ? 0.55 : 1, animated: manager.state != .linked)
            }
            if manager.state == .linked || !manager.screens.isEmpty {
                StageView(manager: manager, settings: settings, padding: isFullScreen ? 0 : 20, gap: isFullScreen ? 0 : 14, chrome: !isFullScreen)
                    .ignoresSafeArea(.container, edges: isFullScreen ? (showFiles ? [.top, .bottom, .leading] : .all) : [])
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                WelcomeView(manager: manager)
                    .transition(.opacity)
            }
            if manager.flash {
                Color.white.opacity(0.35).ignoresSafeArea().allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: manager.state)
        .animation(.easeOut(duration: 0.18), value: manager.flash)
        .overlay(alignment: .bottom) { toastView }
        .overlay(alignment: .topTrailing) { recordingBadge }
        .overlay(alignment: .top) {
            if isFullScreen && linked && settings.fullscreenControls {
                FullscreenBar(manager: manager, settings: settings, showAudio: $showAudio, showInspector: $showFiles)
            }
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if showFiles {
                SidePanel(width: $panelWidth) {
                    InspectorView(manager: manager, settings: settings)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showFiles)
        .background(WindowObserver(isFullScreen: $isFullScreen,
                                   fitAspect: linked && !showFiles ? StageView.contentSize(manager: manager, settings: settings) : nil))
        .modifier(ImportSheetPresenter(hub: manager.emulation))
        .toolbar { toolbar }
        .modifier(ToolbarVisibility(hidden: isFullScreen))
        .navigationTitle(manager.cocoon.nowPlaying?.title ?? "Bifrost Link")
        .frame(minWidth: 480, minHeight: 320)
        .onReceive(NotificationCenter.default.publisher(for: .bifrostToggleFiles)) { _ in showFiles.toggle() }
        .onChange(of: isFullScreen) { _, full in
            if full && !settings.quietFullscreen { manager.showToast("arrow.down.right.and.arrow.up.left", settings.fullscreenControls ? "Move to the top edge for controls · ⌘F to leave" : "Press ⌘F to leave full screen") }
        }
        .onChange(of: manager.state) { _, state in
            if state != .linked { showFiles = false }
        }
    }

    private var linked: Bool { manager.state == .linked }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .automatic) {
            DevicePill(manager: manager, cocoon: manager.cocoon)
        }
        if linked {
            ToolbarItem(placement: .automatic) {
                LayoutControls(manager: manager, settings: settings, cocoon: manager.cocoon)
            }
            ToolbarItemGroup(placement: .automatic) {
                DeviceControls(manager: manager, settings: settings, showAudio: $showAudio, showInspector: $showFiles, compact: false)
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = manager.toast, !(isFullScreen && settings.quietFullscreen) {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol).foregroundStyle(Theme.bifrost)
                Text(toast.message).font(.callout.weight(.medium))
                if let url = toast.url {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassCapsule()
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .padding(.bottom, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }

    @ViewBuilder
    private var recordingBadge: some View {
        if manager.recording, let start = manager.recordingStarted {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                let elapsed = Int(ctx.date.timeIntervalSince(start))
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60)).font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassCapsule()
            }
            .padding(14)
            .onTapGesture { manager.toggleRecording() }
        }
    }
}

struct ToolbarVisibility: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(hidden ? .hidden : .visible, for: .windowToolbar)
        } else {
            content
        }
    }
}

struct DevicePill: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var cocoon: CocoonBridge
    @State private var shimmer: CGFloat = -1

    var body: some View {
        HStack(spacing: 8) {
            if let playing = cocoon.nowPlaying, manager.state == .linked {
                Group {
                    if let icon = playing.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.bifrost)
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.6), radius: 5)
                VStack(alignment: .leading, spacing: 0) {
                    Text(playing.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(Systems.name(for: playing.system)) · \(playing.player)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 220, alignment: .leading)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: dotColor.opacity(0.8), radius: 4)
                Text(manager.state == .linked ? manager.deviceName : "Bifrost Link")
                    .font(.callout.weight(.semibold))
            }
            if manager.state == .linked {
                if let battery = manager.battery {
                    HStack(spacing: 3) {
                        Image(systemName: batterySymbol(battery))
                        Text("\(battery)%").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(manager.charging ? "Charging" : "Battery")
                }
                if manager.lidClosed {
                    Image(systemName: "laptopcomputer.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Lid closed. Bifrost keeps the Thor awake")
                        .accessibilityLabel("Lid closed")
                }
                if !manager.gamepads.isEmpty {
                    Image(systemName: "gamecontroller")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Forwarding: " + manager.gamepads.joined(separator: ", "))
                        .accessibilityLabel("Controller connected")
                }
            }
        }
        .padding(.horizontal, 10)
        .overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Theme.cyan.opacity(0.35), Theme.violet.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: shimmer * geo.size.width)
                    .allowsHitTesting(false)
            }
            .clipShape(Capsule())
            .opacity(shimmer > -1 && shimmer < 1.2 ? 1 : 0)
        }
        .fixedSize()
        .onChange(of: manager.state) { _, state in
            guard state == .linked, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            shimmer = -0.6
            withAnimation(.easeInOut(duration: 1.1)) { shimmer = 1.3 }
        }
    }

    private var dotColor: Color {
        switch manager.state {
        case .linked: return .green
        case .linking, .searching: return .orange
        case .unauthorized: return .yellow
        default: return .red
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        if manager.charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct LayoutControls: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @ObservedObject var cocoon: CocoonBridge

    var body: some View {
        Menu {
            Picker("Layout", selection: $settings.layout) {
                ForEach(ScreenLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.symbol).tag(layout)
                }
            }
            .pickerStyle(.inline)
            Toggle("Swap Screens", isOn: $settings.swapped)
            if let playing = cocoon.nowPlaying {
                let noun = playing.isApp ? "App" : "Game"
                Section("\(playing.title)") {
                    Button(manager.hasProfile(.game) ? "Update Layout for This \(noun)" : "Remember Layout for This \(noun)") { manager.rememberLayout(.game) }
                    if manager.hasProfile(.game) { Button("Forget This \(noun)’s Layout") { manager.forgetLayout(.game) } }
                    if !playing.isApp {
                        Button(manager.hasProfile(.system) ? "Update Layout for All \(Systems.name(for: playing.system)) Games" : "Remember Layout for All \(Systems.name(for: playing.system)) Games") { manager.rememberLayout(.system) }
                        if manager.hasProfile(.system) { Button("Forget \(Systems.name(for: playing.system)) Layout") { manager.forgetLayout(.system) } }
                        if let suggestion = LayoutProfiles.suggestion(for: playing.system), suggestion != settings.layout {
                            Button("Try Suggested: \(suggestion.title)") { settings.layout = suggestion }
                        }
                    }
                }
            }
        } label: {
            Label("Layout: \(settings.layout.title)", systemImage: settings.layout.symbol)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Screen layout: \(settings.layout.title) (⌘1 – ⌘5, ⌘0 swaps)")
        .disabled(manager.screens.count < 2)
    }
}

struct DeviceControls: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @Binding var showAudio: Bool
    @Binding var showInspector: Bool
    var compact: Bool

    private func replay() {
        if settings.replayEnabled {
            manager.saveReplay()
        } else {
            settings.replayEnabled = true
            manager.showToast("clock.arrow.circlepath", "Instant replay is on. From now on Bifrost keeps the last \(settings.replaySeconds) seconds")
        }
    }

    var body: some View {
        Cluster(compact: compact) {
            Button { manager.press(AndroidKey.back) } label: { Label("Back", systemImage: "chevron.backward") }.help("Back (right click)")
            Button { manager.press(AndroidKey.home) } label: { Label("Home", systemImage: "circle") }.help("Home (middle click)")
            Button { manager.press(AndroidKey.appSwitch) } label: { Label("Recents", systemImage: "square.on.square") }.help("Recent apps")
            Button { manager.closeForegroundApp() } label: { Label("Close App", systemImage: "xmark.app") }.help("Close the app in front (⌃⌘W)")
        }

        Cluster(compact: compact) {
            Button { manager.toggleMute() } label: {
                Label(settings.muted ? "Unmute" : "Mute", systemImage: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .foregroundStyle(settings.muted ? Color.red : Color.primary)
            .help(settings.muted ? "Unmute (⇧⌘M)" : "Mute (⇧⌘M)")
            Button { showAudio.toggle() } label: { Label("Volume", systemImage: "slider.horizontal.3") }
                .help("Volume per screen")
                .popover(isPresented: $showAudio, arrowEdge: .bottom) {
                    AudioPanel(manager: manager, settings: settings)
                }
        }

        Cluster(compact: compact) {
            Button { manager.screenshot() } label: { Label("Screenshot", systemImage: "camera") }
                .help("Screenshot (⇧⌘S)")
            Button { replay() } label: { Label("Save Replay", systemImage: "clock.arrow.circlepath") }
                .help(settings.replayEnabled ? "Save the last \(settings.replaySeconds) seconds (⌥⌘S)" : "Instant replay is off. Click to start keeping the last \(settings.replaySeconds) seconds")
            Button { manager.toggleRecording() } label: {
                Label(manager.recording ? "Stop Recording" : "Record", systemImage: manager.recording ? "stop.circle.fill" : "record.circle")
            }
            .foregroundStyle(manager.recording ? Color.red : Color.primary)
            .help(manager.recording ? "Stop recording (⇧⌘R)" : "Record \(settings.recordLayout ? "the window layout" : "each screen") (⇧⌘R)")
        }

        Menu {
            Section("Picture") {
                Toggle("Cinema Mode", isOn: $settings.cinemaMode)
                Toggle("MetalFX Upscaling", isOn: $settings.upscaling)
                Toggle("Stats Overlay", isOn: $settings.statsOverlay)
            }
            Section("Recording") {
                Picker("Record", selection: $settings.recordLayout) {
                    Text("Each Screen Separately").tag(false)
                    Text("The Window Layout").tag(true)
                }
                .pickerStyle(.inline)
                .disabled(manager.recording)
                Toggle("Instant Replay", isOn: $settings.replayEnabled)
            }
            Section("Thor") {
                Button(manager.mirroringPaused ? "Resume Mirroring" : "Pause Mirroring") { manager.toggleMirroring() }
                Button(manager.panelsOn ? "Turn Thor Screens Off" : "Turn Thor Screens On") { manager.togglePanels() }
                Button("Rotate") { manager.rotate() }
                Button("Show Notifications") { manager.expandNotifications() }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Picture, recording and Thor options")

        Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
            Label(compact ? "Leave Full Screen" : "Full Screen", systemImage: compact ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .help(compact ? "Leave full screen (⌘F)" : "Full screen (⌘F)")

        Button { showInspector.toggle() } label: { Label("Files & Library", systemImage: "sidebar.right") }
            .help("Files, library, saves and cleanup (⇧⌘F)")
    }
}

final class TopEdgeWatcher: ObservableObject {
    @Published var visible = false
    private var monitor: Any?
    private var hideWork: DispatchWorkItem?
    var hovering = false { didSet { if hovering { show() } else { scheduleHide() } } }

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            if let window = event.window, let self {
                let y = event.locationInWindow.y
                if y > window.frame.height - 6 { self.show() } else if !self.hovering && y < window.frame.height - 110 { self.scheduleHide() }
            }
            return event
        }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        visible = false
    }

    private func show() {
        hideWork?.cancel()
        if !visible { withAnimation(.easeOut(duration: 0.18)) { visible = true } }
    }

    private func scheduleHide() {
        guard visible, hideWork == nil || hideWork!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.visible = false }
            self.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

struct FullscreenBar: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    @Binding var showAudio: Bool
    @Binding var showInspector: Bool
    @StateObject private var watcher = TopEdgeWatcher()

    var body: some View {
        ZStack(alignment: .top) {
            if watcher.visible {
                HStack(spacing: 12) {
                    DevicePill(manager: manager, cocoon: manager.cocoon)
                    Divider().frame(height: 20)
                    LayoutControls(manager: manager, settings: settings, cocoon: manager.cocoon)
                    Divider().frame(height: 20)
                    DeviceControls(manager: manager, settings: settings, showAudio: $showAudio, showInspector: $showInspector, compact: true)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .padding(.top, 10)
                .onHover { watcher.hovering = $0 }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { watcher.start() }
        .onDisappear { watcher.stop() }
    }
}

extension Notification.Name {
    static let bifrostToggleFiles = Notification.Name("bifrostToggleFiles")
    static let bifrostFitWindow = Notification.Name("bifrostFitWindow")
}

struct Cluster<Content: View>: View {
    var compact: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if compact {
            HStack(spacing: 4) { content }
        } else {
            ControlGroup { content }
                .controlGroupStyle(.navigation)
        }
    }
}

struct SidePanel<Content: View>: View {
    @Binding var width: Double
    @ViewBuilder var content: Content
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .overlay {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStart == nil { dragStart = width }
                                width = min(640, max(320, (dragStart ?? width) - value.translation.width))
                            }
                            .onEnded { _ in dragStart = nil })
                }
            content
                .frame(width: width)
                .frame(maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }
}
