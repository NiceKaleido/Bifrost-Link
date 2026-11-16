import SwiftUI
import AppKit

struct WindowObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool
    var fitAspect: CGSize?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.window == nil {
            DispatchQueue.main.async { coordinator.attach(to: nsView.window) }
        }
        coordinator.aspect = fitAspect
    }

    final class Coordinator {
        var parent: WindowObserver
        weak var window: NSWindow?
        var aspect: CGSize?
        private var tokens: [NSObjectProtocol] = []

        init(_ parent: WindowObserver) {
            self.parent = parent
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.backgroundColor = .black
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                window.toolbar?.isVisible = false
                self?.parent.isFullScreen = true
            })
            tokens.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                window.toolbar?.isVisible = true
                self?.parent.isFullScreen = false
            })
            tokens.append(center.addObserver(forName: .bifrostFitWindow, object: nil, queue: .main) { [weak self] _ in
                self?.fit(animate: true)
            })
        }

        func fit(animate: Bool) {
            guard let window, let aspect, aspect.width > 0, aspect.height > 0,
                  !window.styleMask.contains(.fullScreen), !window.inLiveResize,
                  let screen = window.screen ?? NSScreen.main else { return }
            let frame = window.frame
            let content = window.contentLayoutRect
            let chromeH = frame.height - content.height
            let chromeW = frame.width - content.width
            let visible = screen.visibleFrame
            let ratio = aspect.width / aspect.height

            var contentW = content.width
            var contentH = contentW / ratio
            let currentArea = content.width * content.height
            if contentH > content.height {
                contentH = sqrt(currentArea / ratio)
                contentW = contentH * ratio
            }
            if contentH + chromeH > visible.height {
                contentH = visible.height - chromeH
                contentW = contentH * ratio
            }
            if contentW + chromeW > visible.width {
                contentW = visible.width - chromeW
                contentH = contentW / ratio
            }
            let minSize = window.minSize
            if contentW + chromeW < minSize.width || contentH + chromeH < minSize.height { return }

            var target = NSRect(x: 0, y: 0, width: (contentW + chromeW).rounded(), height: (contentH + chromeH).rounded())
            target.origin.x = frame.midX - target.width / 2
            target.origin.y = frame.maxY - target.height
            target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height)
            if abs(target.width - frame.width) < 2 && abs(target.height - frame.height) < 2 { return }
            window.setFrame(target, display: true, animate: animate)
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
