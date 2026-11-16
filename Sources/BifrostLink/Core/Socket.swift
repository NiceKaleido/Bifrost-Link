import Foundation
import Darwin

final class TCPSocket: @unchecked Sendable {
    private var fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()

    private var currentFD: Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return fd
    }

    var isOpen: Bool { currentFD >= 0 }

    private init(fd: Int32) {
        self.fd = fd
    }

    static func connect(port: UInt16) -> TCPSocket? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return TCPSocket(fd: fd)
    }

    static func freePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }

    func readExactly(_ count: Int) -> Data? {
        if count == 0 { return Data() }
        let fd = currentFD
        guard fd >= 0 else { return nil }
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }

    func readByte() -> UInt8? {
        readExactly(1)?.first
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        let fd = currentFD
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    func close() {
        stateLock.lock()
        let old = fd
        fd = -1
        stateLock.unlock()
        guard old >= 0 else { return }
        shutdown(old, SHUT_RDWR)
        writeLock.lock()
        Darwin.close(old)
        writeLock.unlock()
    }

    deinit {
        close()
    }
}

extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(self[self.startIndex + offset + i]) }
        return value
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(self[self.startIndex + offset + i]) }
        return value
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        (UInt16(self[self.startIndex + offset]) << 8) | UInt16(self[self.startIndex + offset + 1])
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
