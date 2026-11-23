import AppKit
import CoreMedia

@MainActor
protocol ScreenInputDelegate: AnyObject {
    var control: ControlChannel? { get }
    var videoSize: CGSize { get }
    func screenViewDidBecomeFocused(_ view: ScreenView)
    func screenView(_ view: ScreenView, didReceiveDroppedFiles urls: [URL])
    func screenViewPaste(_ view: ScreenView)
    func screenViewCopy(_ view: ScreenView, cut: Bool)
}

@MainActor
protocol PadRouter: AnyObject {
    var padActive: Bool { get }
    var padUsesMouse: Bool { get }
    var pointerCaptured: Bool { get }
    func padKey(_ keyCode: UInt16, down: Bool) -> Bool
    func padCapturePointer()
    func padReleasePointer()
    func padMouse(dx: CGFloat, dy: CGFloat)
    func padClick(right: Bool, down: Bool)
}

final class ScreenView: NSView {
    static weak var padRouter: PadRouter?

    enum OverlayGesture {
        case began(corner: CGPoint?)
        case changed(dx: CGFloat, dy: CGFloat)
        case ended
    }

    let renderer = MetalRenderer()
    var isFloating = false
    var onOverlayGesture: ((OverlayGesture) -> Void)?
    private var overlayDragStart: CGPoint?
    weak var inputDelegate: ScreenInputDelegate?
    var hoverEnabled = true
    private var tracking: NSTrackingArea?
    private var pinchDistance: CGFloat = 0
    private var pinchCenter: CGPoint = .zero
    private var pinching = false
    private var dragging = false
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(renderer.layer)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = bounds
        CATransaction.commit()
        renderer.resize(bounds.size, scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.resize(bounds.size, scale: window?.backingScaleFactor ?? 2)
        updateRefreshInterval()
    }

    private var screenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        screenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        screenObservers = []
        updateRefreshInterval()
        guard let window else { return }
        // Moving to another display, or changing its refresh rate in System Settings.
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRefreshInterval() }
        }
        screenObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: update),
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: update),
        ]
    }

    private func updateRefreshInterval() {
        renderer.refreshInterval = window?.screen?.minimumRefreshInterval ?? 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func becomeFirstResponder() -> Bool {
        inputDelegate?.screenViewDidBecomeFocused(self)
        return true
    }


    func clear() {
        renderer.clear()
    }

    private var contentRect: CGRect {
        guard let size = inputDelegate?.videoSize, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func devicePoint(_ event: NSEvent, clamp: Bool) -> (Int32, Int32)? {
        let p = convert(event.locationInWindow, from: nil)
        return devicePoint(p, clamp: clamp)
    }

    private func devicePoint(_ p: CGPoint, clamp: Bool) -> (Int32, Int32)? {
        guard let size = inputDelegate?.videoSize, size.width > 0 else { return nil }
        let rect = contentRect
        var nx = (p.x - rect.minX) / rect.width
        var ny = (p.y - rect.minY) / rect.height
        if clamp {
            nx = max(0, min(0.9999, nx))
            ny = max(0, min(0.9999, ny))
        } else if nx < 0 || ny < 0 || nx >= 1 || ny >= 1 {
            return nil
        }
        return (Int32(nx * size.width), Int32(ny * size.height))
    }

    private func touch(_ action: AndroidAction, _ point: (Int32, Int32), pointer: UInt64 = PointerID.finger) {
        guard let size = inputDelegate?.videoSize, let control = inputDelegate?.control else { return }
        control.injectTouch(action: action, pointerId: pointer, x: point.0, y: point.1, width: UInt16(size.width), height: UInt16(size.height), pressure: action == .up ? 0 : 1)
    }

    private func overlayCorner(at point: CGPoint) -> CGPoint? {
        let grip: CGFloat = 26
        let nearX: CGFloat? = point.x < grip ? -1 : (point.x > bounds.width - grip ? 1 : nil)
        let nearY: CGFloat? = point.y < grip ? -1 : (point.y > bounds.height - grip ? 1 : nil)
        guard let x = nearX, let y = nearY else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func isOverlayGesture(_ event: NSEvent) -> Bool {
        isFloating && onOverlayGesture != nil && event.modifierFlags.contains(.command)
    }

    private var router: PadRouter? {
        guard let router = Self.padRouter, router.padActive else { return nil }
        return router
    }

    private func padMouseDown(right: Bool) -> Bool {
        guard let router, router.padUsesMouse else { return false }
        window?.makeFirstResponder(self)
        if router.pointerCaptured {
            router.padClick(right: right, down: true)
        } else if !right {
            router.padCapturePointer()
        }
        return true
    }

    private func padMouseUp(right: Bool) -> Bool {
        guard let router, router.padUsesMouse else { return false }
        if router.pointerCaptured { router.padClick(right: right, down: false) }
        return true
    }

    private func padMouseMove(_ event: NSEvent) -> Bool {
        guard let router, router.pointerCaptured else { return false }
        router.padMouse(dx: event.deltaX, dy: event.deltaY)
        return true
    }

    override func rightMouseDragged(with event: NSEvent) {
        _ = padMouseMove(event)
    }

    override func mouseDown(with event: NSEvent) {
        if padMouseDown(right: false) { return }
        if isOverlayGesture(event) {
            overlayDragStart = event.locationInWindow
            let local = convert(event.locationInWindow, from: nil)
            let corner = overlayCorner(at: local)
            (corner == nil ? NSCursor.closedHand : NSCursor.crosshair).set()
            onOverlayGesture?(.began(corner: corner))
            return
        }
        window?.makeFirstResponder(self)
        guard let p = devicePoint(event, clamp: false) else { return }
        dragging = true
        touch(.down, p)
    }

    override func mouseDragged(with event: NSEvent) {
        if padMouseMove(event) { return }
        if let start = overlayDragStart {
            let now = event.locationInWindow
            onOverlayGesture?(.changed(dx: now.x - start.x, dy: start.y - now.y))
            return
        }
        guard dragging, let p = devicePoint(event, clamp: true) else { return }
        touch(.move, p)
    }

    override func mouseUp(with event: NSEvent) {
        if padMouseUp(right: false) { return }
        if overlayDragStart != nil {
            overlayDragStart = nil
            onOverlayGesture?(.ended)
            NSCursor.arrow.set()
            return
        }
        guard dragging, let p = devicePoint(event, clamp: true) else { return }
        dragging = false
        touch(.up, p)
    }

    override func mouseMoved(with event: NSEvent) {
        if padMouseMove(event) { return }
        if isFloating && onOverlayGesture != nil {
            if event.modifierFlags.contains(.command) {
                (overlayCorner(at: convert(event.locationInWindow, from: nil)) == nil ? NSCursor.openHand : NSCursor.crosshair).set()
                return
            }
            NSCursor.arrow.set()
        }
        guard hoverEnabled, !dragging, let p = devicePoint(event, clamp: false) else { return }
        touch(.hoverMove, p, pointer: PointerID.mouse)
    }

    override func rightMouseDown(with event: NSEvent) {
        if padMouseDown(right: true) { return }
        window?.makeFirstResponder(self)
        inputDelegate?.control?.backOrScreenOn(.down)
    }

    override func rightMouseUp(with event: NSEvent) {
        if padMouseUp(right: true) { return }
        inputDelegate?.control?.backOrScreenOn(.up)
    }

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 2: inputDelegate?.control?.injectKeycode(action: .down, keycode: AndroidKey.home)
        case 3: inputDelegate?.control?.injectKeycode(action: .down, keycode: AndroidKey.back)
        case 4: inputDelegate?.control?.injectKeycode(action: .down, keycode: AndroidKey.appSwitch)
        default: break
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        switch event.buttonNumber {
        case 2: inputDelegate?.control?.injectKeycode(action: .up, keycode: AndroidKey.home)
        case 3: inputDelegate?.control?.injectKeycode(action: .up, keycode: AndroidKey.back)
        case 4: inputDelegate?.control?.injectKeycode(action: .up, keycode: AndroidKey.appSwitch)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let size = inputDelegate?.videoSize, let control = inputDelegate?.control,
              let p = devicePoint(event, clamp: true) else { return }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollAccumX += dx / 24
            scrollAccumY += dy / 24
            dx = scrollAccumX
            dy = scrollAccumY
            if abs(dx) < 0.05 && abs(dy) < 0.05 { return }
            scrollAccumX = 0
            scrollAccumY = 0
        }
        control.injectScroll(x: p.0, y: p.1, width: UInt16(size.width), height: UInt16(size.height), hScroll: Float(-dx), vScroll: Float(dy))
    }

    override func magnify(with event: NSEvent) {
        guard let size = inputDelegate?.videoSize, let control = inputDelegate?.control else { return }
        let local = convert(event.locationInWindow, from: nil)
        func send(_ action: AndroidAction) {
            let half = pinchDistance / 2
            let a = devicePoint(CGPoint(x: pinchCenter.x - half, y: pinchCenter.y), clamp: true)
            let b = devicePoint(CGPoint(x: pinchCenter.x + half, y: pinchCenter.y), clamp: true)
            guard let a, let b else { return }
            control.injectTouch(action: action, pointerId: 100, x: a.0, y: a.1, width: UInt16(size.width), height: UInt16(size.height), pressure: action == .up ? 0 : 1)
            control.injectTouch(action: action, pointerId: 101, x: b.0, y: b.1, width: UInt16(size.width), height: UInt16(size.height), pressure: action == .up ? 0 : 1)
        }
        switch event.phase {
        case .began:
            pinchCenter = local
            pinchDistance = min(bounds.width, bounds.height) * 0.2
            pinching = true
            send(.down)
        case .changed:
            guard pinching else { return }
            pinchDistance = max(10, min(min(bounds.width, bounds.height) * 0.95, pinchDistance * (1 + event.magnification)))
            send(.move)
        case .ended, .cancelled:
            guard pinching else { return }
            pinching = false
            send(.up)
        default:
            break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "v": inputDelegate?.screenViewPaste(self); return true
            case "c": inputDelegate?.screenViewCopy(self, cut: false); return true
            case "x": inputDelegate?.screenViewCopy(self, cut: true); return true
            case "a":
                inputDelegate?.control?.pressKey(29, metaState: 0x3000)
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let control = inputDelegate?.control else { return }
        if event.modifierFlags.contains(.command) { return }
        if let router {
            if event.keyCode == 53 && router.pointerCaptured {
                router.padReleasePointer()
                return
            }
            if router.padKey(event.keyCode, down: true) { return }
        }
        switch KeyMap.translate(event) {
        case .key(let code, let meta):
            control.injectKeycode(action: .down, keycode: code, repeatCount: event.isARepeat ? 1 : 0, metaState: meta)
        case .text(let text):
            control.injectText(text)
        case .none:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let control = inputDelegate?.control else { return }
        if let router, router.padKey(event.keyCode, down: false) { return }
        if case .key(let code, let meta) = KeyMap.translate(event) {
            control.injectKeycode(action: .up, keycode: code, metaState: meta)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let control = inputDelegate?.control, KeyMap.modifierKeyCodes.contains(event.keyCode),
              let code = KeyMap.special[event.keyCode] else { return }
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 0x38, 0x3C: flag = .shift
        case 0x3B, 0x3E: flag = .control
        case 0x3A, 0x3D: flag = .option
        default: flag = .capsLock
        }
        let down = event.modifierFlags.contains(flag)
        if let router, router.padKey(event.keyCode, down: down) { return }
        if flag == .capsLock {
            control.pressKey(code)
        } else {
            control.injectKeycode(action: down ? .down : .up, keycode: code, metaState: KeyMap.metaState(event.modifierFlags))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        inputDelegate?.screenView(self, didReceiveDroppedFiles: urls)
        return true
    }
}
