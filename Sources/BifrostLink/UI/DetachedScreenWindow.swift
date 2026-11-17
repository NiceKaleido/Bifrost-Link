import SwiftUI
import AppKit

@MainActor
final class DetachedScreenWindow: NSObject, NSWindowDelegate {
    static let shared = DetachedScreenWindow()
    private var window: NSWindow?
    private var role: ScreenRole?
    private var closingFromCode = false

    func sync(manager: DeviceManager, settings: LinkSettings) {
        let wanted = manager.state == .linked ? settings.detachedRole : nil
        guard wanted != role || (wanted != nil && window == nil) else {
            updateAspect(manager: manager)
            return
        }
        close()
        guard let wanted else { return }
        role = wanted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bifrost Link · \(wanted.title)"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = NSHostingView(rootView: DetachedScreenContent(manager: manager, role: wanted).preferredColorScheme(.dark))
        let autosave = "BifrostDetached-\(wanted.rawValue)-\(NSScreen.screens.count)"
        if !window.setFrameUsingName(autosave) { window.center() }
        window.setFrameAutosaveName(autosave)
        self.window = window
        updateAspect(manager: manager)
        window.orderFront(nil)
        Log.write("detached \(wanted.rawValue) screen into its own window")
    }

    private func updateAspect(manager: DeviceManager) {
        guard let role, let size = manager.screen(role)?.size else { return }
        setAspect(size)
    }

    func setAspect(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0, window.contentAspectRatio != size else { return }
        window.contentAspectRatio = size
        var frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let height = content.width * size.height / size.width
        frame.origin.y += content.height - height
        frame.size.height += height - content.height
        if !window.styleMask.contains(.fullScreen) { window.setFrame(frame, display: true, animate: false) }
    }

    func close() {
        guard let window else { return }
        closingFromCode = true
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.close()
        closingFromCode = false
        self.window = nil
        role = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingFromCode else { return }
        window = nil
        role = nil
        LinkSettings.shared.detachedScreen = ""
    }

    func move(to screen: NSScreen, fullScreen: Bool) {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        if fullScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.toggleFullScreen(nil) }
        }
    }

    var isOpen: Bool { window != nil }
}

struct DetachedScreenContent: View {
    @ObservedObject var manager: DeviceManager
    let role: ScreenRole

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let screen = manager.screen(role) {
                DetachedTile(controller: screen)
            } else {
                Text("Waiting for the \(role.title.lowercased())…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }
}

struct DetachedTile: View {
    @ObservedObject var controller: ScreenController

    var body: some View {
        ScreenTile(controller: controller, chrome: false)
            .aspectRatio(controller.size.width > 0 ? controller.size : CGSize(width: 16, height: 9), contentMode: .fit)
            .onChange(of: controller.size) { _, size in DetachedScreenWindow.shared.setAspect(size) }
    }
}
