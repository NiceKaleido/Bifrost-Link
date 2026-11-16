import Foundation
import QuartzCore

final class ScreenStats: @unchecked Sendable {
    struct Snapshot: Equatable {
        var fps: Double
        var receivedFps: Double
        var mbps: Double
        var latencyMs: Double
        var dropped: Int
        var resolution: String
        var codec: String
    }

    private let lock = NSLock()
    private var bytes = 0
    private var received = 0
    private var decodedCount = 0
    private var presentedCount = 0
    private var latencySum: Double = 0
    private var latencyCount = 0
    private var lastSample = CACurrentMediaTime()

    func received(bytes count: Int) {
        lock.lock()
        bytes += count
        received += 1
        lock.unlock()
    }

    func decoded() {
        lock.lock(); decodedCount += 1; lock.unlock()
    }

    func presented(latency: CFTimeInterval) {
        lock.lock()
        presentedCount += 1
        if latency > 0 && latency < 2 {
            latencySum += latency
            latencyCount += 1
        }
        lock.unlock()
    }

    func snapshot(size: CGSize, codec: String) -> Snapshot {
        lock.lock()
        let now = CACurrentMediaTime()
        let elapsed = max(0.001, now - lastSample)
        let result = Snapshot(
            fps: Double(presentedCount) / elapsed,
            receivedFps: Double(received) / elapsed,
            mbps: Double(bytes) * 8 / elapsed / 1_000_000,
            latencyMs: latencyCount > 0 ? latencySum / Double(latencyCount) * 1000 : 0,
            dropped: max(0, decodedCount - presentedCount),
            resolution: "\(Int(size.width))×\(Int(size.height))",
            codec: codec)
        bytes = 0
        received = 0
        decodedCount = 0
        presentedCount = 0
        latencySum = 0
        latencyCount = 0
        lastSample = now
        lock.unlock()
        return result
    }
}
