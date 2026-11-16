import Foundation

enum AndroidAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case hoverMove = 7
}

enum PointerID {
    static let mouse: UInt64 = UInt64(bitPattern: -1)
    static let finger: UInt64 = UInt64(bitPattern: -2)
}

enum DeviceEvent {
    case clipboard(String)
    case ackClipboard(UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

final class ControlChannel: @unchecked Sendable {
    private let socket: TCPSocket
    private let queue = DispatchQueue(label: "bifrost.control", qos: .userInteractive)
    var onEvent: (@Sendable (DeviceEvent) -> Void)?
    var onClose: (@Sendable () -> Void)?
    private var sequence: UInt64 = 1
    private let stateLock = NSLock()
    private var closed = false
    private var closeNotified = false

    init(socket: TCPSocket) {
        self.socket = socket
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    private func notifyClose() {
        stateLock.lock()
        let first = !closeNotified
        closeNotified = true
        stateLock.unlock()
        if first { onClose?() }
    }

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    private func readLoop() {
        while true {
            guard let type = socket.readByte() else { break }
            switch type {
            case 0:
                guard let lenData = socket.readExactly(4) else { notifyClose(); return }
                let len = Int(lenData.readUInt32BE(at: 0))
                guard let text = socket.readExactly(len) else { notifyClose(); return }
                onEvent?(.clipboard(String(decoding: text, as: UTF8.self)))
            case 1:
                guard let seq = socket.readExactly(8) else { notifyClose(); return }
                onEvent?(.ackClipboard(seq.readUInt64BE(at: 0)))
            case 2:
                guard let head = socket.readExactly(4) else { notifyClose(); return }
                let id = head.readUInt16BE(at: 0)
                let len = Int(head.readUInt16BE(at: 2))
                guard let data = socket.readExactly(len) else { notifyClose(); return }
                onEvent?(.uhidOutput(id: id, data: data))
            default:
                NSLog("Unknown device message type %d", type)
                notifyClose()
                return
            }
        }
        notifyClose()
    }

    private func send(_ data: Data) {
        guard !isClosed else { return }
        queue.async { [socket] in
            if socket.isOpen { socket.write(data) }
        }
    }

    func injectKeycode(action: AndroidAction, keycode: Int32, repeatCount: Int32 = 0, metaState: Int32 = 0) {
        var d = Data([0, action.rawValue])
        d.appendBE(keycode)
        d.appendBE(repeatCount)
        d.appendBE(metaState)
        send(d)
    }

    func pressKey(_ keycode: Int32, metaState: Int32 = 0) {
        injectKeycode(action: .down, keycode: keycode, metaState: metaState)
        injectKeycode(action: .up, keycode: keycode, metaState: metaState)
    }

    func injectText(_ text: String) {
        var bytes = Array(text.utf8)
        if bytes.count > 300 { bytes = Array(bytes.prefix(300)) }
        var d = Data([1])
        d.appendBE(UInt32(bytes.count))
        d.append(contentsOf: bytes)
        send(d)
    }

    func injectTouch(action: AndroidAction, pointerId: UInt64, x: Int32, y: Int32, width: UInt16, height: UInt16, pressure: Float = 1, actionButton: Int32 = 0, buttons: Int32 = 0) {
        var d = Data([2, action.rawValue])
        d.appendBE(pointerId)
        d.appendBE(x)
        d.appendBE(y)
        d.appendBE(width)
        d.appendBE(height)
        let p = pressure >= 1 ? UInt16.max : UInt16(max(0, pressure) * 65536)
        d.appendBE(p)
        d.appendBE(actionButton)
        d.appendBE(buttons)
        send(d)
    }

    func injectScroll(x: Int32, y: Int32, width: UInt16, height: UInt16, hScroll: Float, vScroll: Float) {
        func fixed(_ v: Float) -> Int16 {
            let n = max(-1, min(1, v / 16))
            return n >= 1 ? Int16.max : Int16(n * 32768)
        }
        var d = Data([3])
        d.appendBE(x)
        d.appendBE(y)
        d.appendBE(width)
        d.appendBE(height)
        d.appendBE(fixed(hScroll))
        d.appendBE(fixed(vScroll))
        d.appendBE(Int32(0))
        send(d)
    }

    func backOrScreenOn(_ action: AndroidAction) {
        send(Data([4, action.rawValue]))
    }

    func expandNotifications() { send(Data([5])) }

    func getClipboard(copyKey: UInt8 = 1) {
        send(Data([8, copyKey]))
    }

    func setClipboard(_ text: String, paste: Bool) {
        var d = Data([9])
        d.appendBE(sequence)
        sequence += 1
        d.append(paste ? 1 : 0)
        let bytes = Array(text.utf8.prefix(200_000))
        d.appendBE(UInt32(bytes.count))
        d.append(contentsOf: bytes)
        send(d)
    }

    func setDisplayPower(_ on: Bool) {
        send(Data([10, on ? 1 : 0]))
    }

    func rotate() { send(Data([11])) }

    func uhidCreate(id: UInt16, vendorId: UInt16, productId: UInt16, name: String, descriptor: [UInt8]) {
        var d = Data([12])
        d.appendBE(id)
        d.appendBE(vendorId)
        d.appendBE(productId)
        let nameBytes = Array(name.utf8.prefix(127))
        d.append(UInt8(nameBytes.count))
        d.append(contentsOf: nameBytes)
        d.appendBE(UInt16(descriptor.count))
        d.append(contentsOf: descriptor)
        send(d)
    }

    func uhidInput(id: UInt16, report: Data) {
        var d = Data([13])
        d.appendBE(id)
        d.appendBE(UInt16(report.count))
        d.append(report)
        send(d)
    }

    func uhidDestroy(id: UInt16) {
        var d = Data([14])
        d.appendBE(id)
        send(d)
    }

    func resetVideo() { send(Data([17])) }

    func scanFile(_ path: String) {
        let bytes = Array(path.utf8)
        var d = Data([22])
        d.appendBE(UInt32(bytes.count))
        d.append(contentsOf: bytes)
        send(d)
    }

    func close() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        socket.close()
    }
}
