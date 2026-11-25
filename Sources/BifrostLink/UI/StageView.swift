import SwiftUI
import AppKit

final class ScreenContainer: NSView {
    var screenView: ScreenView? {
        didSet { adopt() }
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adopt()
    }

    func adopt() {
        guard let screenView, window != nil, screenView.superview !== self else { return }
        screenView.removeFromSuperview()
        addSubview(screenView)
        screenView.frame = bounds
    }

    override func layout() {
        super.layout()
        if screenView?.superview === self { screenView?.frame = bounds }
    }
}

struct ScreenHost: NSViewRepresentable {
    let controller: ScreenController

    func makeNSView(context: Context) -> ScreenContainer {
        let container = ScreenContainer()
        container.screenView = controller.view
        return container
    }

    func updateNSView(_ nsView: ScreenContainer, context: Context) {
        if nsView.screenView !== controller.view { nsView.screenView = controller.view }
        nsView.adopt()
    }
}

struct StatsHUD: View {
    let stats: ScreenStats.Snapshot
    var audioLatency: Double?
    var monitor: DeviceMonitor?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let monitor { DeviceHUDLine(monitor: monitor) }
            Text("\(Int(stats.fps.rounded())) fps · \(String(format: "%.1f", stats.mbps)) Mbit/s")
            Text("\(Int(stats.latencyMs.rounded())) ms decode→display\(stats.dropped > 0 ? " · \(stats.dropped) dropped" : "")")
            Text("\(stats.codec) \(stats.resolution)")
            if let audioLatency {
                Text("audio buffer \(Int(audioLatency.rounded())) ms")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The device's own numbers, on top of the stream stats in the same overlay.
struct DeviceHUDLine: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        if let snap = monitor.snapshot {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(snap.fps.map { String(format: "%.1f", $0) } ?? "—").foregroundStyle(PerfStatus.frames(snap).color)
                    Text(" fps on \(DeviceInfo.name)")
                    if let ms = snap.frameTimeMs { Text(String(format: " · %.1f ms", ms)).foregroundStyle(.white.opacity(0.65)) }
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                HStack(spacing: 0) {
                    Text("CPU "); Text("\(Int(snap.cpu.rounded()))%").foregroundStyle(PerfStatus.load(snap.cpu).color)
                    Text(" · GPU "); Text("\(Int(snap.gpu.rounded()))%").foregroundStyle(PerfStatus.load(snap.gpu).color)
                    if let temp = snap.cpuTemp { Text(" · "); Text("\(Int(temp.rounded()))°C").foregroundStyle(PerfStatus.temperature(temp).color) }
                    Text(String(format: " · %.1f GB", snap.memUsedMB / 1024))
                    if let watts = snap.watts { Text(String(format: " · %.1f W", watts)) }
                }
            }
            .padding(.bottom, 3)
        }
    }
}

struct ScreenTile: View {
    @ObservedObject var controller: ScreenController
    var chrome = true
    var audioLatency: Double?
    var monitor: DeviceMonitor?

    var body: some View {
        ZStack {
            ScreenHost(controller: controller)
            if !controller.hasFrame {
                placeholder.allowsHitTesting(false)
            }
        }
        .overlay {
            Rectangle()
                .strokeBorder(chrome ? Theme.hairline : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if let stats = controller.statsSnapshot {
                StatsHUD(stats: stats, audioLatency: audioLatency, monitor: monitor)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(chrome ? 0.5 : 0), radius: 18, y: 6)
    }

    private var placeholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                if case .failed(let message) = controller.state {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the \(controller.role.title.lowercased())…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

final class AmbientCanvas: NSView {
    weak var wash: CALayer?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let wash else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let reach = max(bounds.width, bounds.height) * 0.45
        wash.frame = bounds.insetBy(dx: -reach, dy: -reach)
        CATransaction.commit()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct AmbientView: NSViewRepresentable {
    let screens: [ScreenController]
    let rects: [ScreenRole: CGRect]
    let wash: CALayer

    func makeNSView(context: Context) -> AmbientCanvas {
        AmbientCanvas()
    }

    func updateNSView(_ view: AmbientCanvas, context: Context) {
        guard let root = view.layer else { return }
        let wanted = Set(screens.map { ObjectIdentifier($0.ambientLayer) } + [ObjectIdentifier(wash)])
        for sub in root.sublayers ?? [] where !wanted.contains(ObjectIdentifier(sub)) {
            sub.removeFromSuperlayer()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        if wash.superlayer !== root {
            root.insertSublayer(wash, at: 0)
            wash.filters = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 120]).map { [$0] }
        }
        view.wash = wash
        view.needsLayout = true
        for screen in screens {
            let layer = screen.ambientLayer
            if layer.superlayer !== root {
                root.addSublayer(layer)
                layer.filters = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 48]).map { [$0] }
            }
            if let rect = rects[screen.role] {
                layer.frame = rect.insetBy(dx: -rect.width * 0.35, dy: -rect.height * 0.45)
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }
        CATransaction.commit()
    }
}

final class OverlayGeometry {
    var main: CGRect = .zero
    var overlay: CGRect = .zero
    var startRect: CGRect = .zero
    var startCenter: CGPoint?
    var startScale: Double = 0
    var corner: CGPoint?
}

struct StageView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: LinkSettings
    var padding: CGFloat = 20
    var gap: CGFloat = 14
    var chrome = true
    @State private var overlayGeometry = OverlayGeometry()

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let placements = layout(in: geo.size)
            ZStack(alignment: .topLeading) {
                if settings.cinemaMode {
                    AmbientView(screens: manager.screens,
                                rects: placements.filter { $0.value.visible && !$0.value.floating }.mapValues(\.rect),
                                wash: manager.ambientWash)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }
                ForEach(manager.screens.filter { $0.role != settings.detachedRole }, id: \.role) { screen in
                    let p = placements[screen.role] ?? TilePlacement(rect: CGRect(x: geo.size.width / 2, y: geo.size.height / 2, width: 1, height: 1), visible: false)
                    ScreenTile(controller: screen, chrome: chrome || p.floating,
                               audioLatency: screen.role == .top ? manager.audioLatencyMs : nil,
                               monitor: screen.role == .top ? manager.monitor : nil)
                        .onAppear { bindOverlay(screen, floating: p.floating) }
                        .onChange(of: p.floating) { _, floating in bindOverlay(screen, floating: floating) }
                        .opacity(p.visible ? (p.floating ? settings.overlayOpacity : 1) : 0)
                        .frame(width: p.rect.width, height: p.rect.height)
                        .offset(x: p.rect.minX, y: p.rect.minY)
                        .allowsHitTesting(p.visible)
                        .zIndex(p.floating ? 2 : 1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .blur(radius: manager.mirroringPaused ? 18 : 0)
            .allowsHitTesting(!manager.mirroringPaused)
            .overlay {
                if manager.mirroringPaused {
                    VStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.bifrost)
                        Text("Mirroring paused").font(.title3.weight(.semibold))
                        Text("The \(DeviceInfo.name) isn’t streaming. Its screens and sound are back on the device, files and the library still work.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                        Button("Resume Mirroring") { manager.toggleMirroring() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: manager.mirroringPaused)
            .animation(spring, value: settings.layout)
            .animation(spring, value: settings.swapped)

        }
        .padding(padding)
    }

    static func contentSize(manager: DeviceManager, settings: LinkSettings) -> CGSize? {
        StageLayout.contentSize(spec: LayoutSpec(settings: settings, top: manager.screen(.top)?.size, bottom: manager.screen(.bottom)?.size))
    }

    private func handleOverlay(_ gesture: ScreenView.OverlayGesture) {
        let geo = overlayGeometry
        switch gesture {
        case .began(let corner):
            geo.startCenter = CGPoint(x: settings.overlayX, y: settings.overlayY)
            geo.startScale = settings.overlayScale
            geo.startRect = geo.overlay
            geo.corner = corner
        case .changed(let dx, let dy):
            guard geo.main.width > 0, let start = geo.startCenter else { return }
            if let corner = geo.corner {
                let grow = (corner.x * dx + corner.y * dy * geo.startRect.width / max(geo.startRect.height, 1)) / 2
                let width = max(geo.main.width * 0.15, min(geo.main.width * 0.7, geo.startRect.width + grow))
                let delta = width - geo.startRect.width
                let height = geo.startRect.height * width / max(geo.startRect.width, 1)
                let dh = height - geo.startRect.height
                settings.overlayScale = width / geo.main.width
                settings.overlayX = start.x + Double(corner.x * delta / 2 / geo.main.width)
                settings.overlayY = start.y + Double(corner.y * dh / 2 / geo.main.height)
            } else {
                let halfW = geo.overlay.width / 2 / geo.main.width
                let halfH = geo.overlay.height / 2 / geo.main.height
                settings.overlayX = min(max(start.x + Double(dx / geo.main.width), halfW), 1 - halfW)
                settings.overlayY = min(max(start.y + Double(dy / geo.main.height), halfH), 1 - halfH)
            }
        case .ended:
            geo.startCenter = nil
            geo.corner = nil
        }
    }

    private var spec: LayoutSpec {
        LayoutSpec(settings: settings, top: manager.screen(.top)?.size, bottom: manager.screen(.bottom)?.size)
    }

    private func layout(in size: CGSize) -> [ScreenRole: TilePlacement] {
        let placements = StageLayout.placements(in: size, gap: gap, spec: spec)
        if let floating = placements.values.first(where: { $0.floating }),
           let main = placements.values.first(where: { $0.visible && !$0.floating }) {
            overlayGeometry.overlay = floating.rect
            overlayGeometry.main = main.rect
        }
        return placements
    }

    private func bindOverlay(_ screen: ScreenController, floating: Bool) {
        screen.view.isFloating = floating
        screen.view.onOverlayGesture = floating ? { handleOverlay($0) } : nil
    }

}
