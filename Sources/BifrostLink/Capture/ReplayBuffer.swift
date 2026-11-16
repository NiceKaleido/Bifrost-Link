import AVFoundation
import CoreMedia
import QuartzCore

final class ReplayBuffer: @unchecked Sendable {
    struct VideoItem {
        let sample: CMSampleBuffer
        let time: CFTimeInterval
        let key: Bool
    }

    struct AudioItem {
        let buffer: AVAudioPCMBuffer
        let time: CFTimeInterval
    }

    private let lock = NSLock()
    private var video: [ScreenRole: [VideoItem]] = [:]
    private var audio: [AudioItem] = []
    private var window: CFTimeInterval

    init(seconds: Int) {
        window = CFTimeInterval(seconds)
    }

    func setSeconds(_ seconds: Int) {
        lock.lock(); window = CFTimeInterval(seconds); lock.unlock()
    }

    func append(video sample: CMSampleBuffer, keyFrame: Bool, role: ScreenRole) {
        let now = CACurrentMediaTime()
        lock.lock()
        var items = video[role] ?? []
        items.append(VideoItem(sample: sample, time: now, key: keyFrame))
        let cutoff = now - window
        if let first = items.first, first.time < cutoff - 1 {
            if let keep = items.lastIndex(where: { $0.key && $0.time <= cutoff }) , keep > 0 {
                items.removeFirst(keep)
            }
        }
        video[role] = items
        lock.unlock()
    }

    func append(audio buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let copy = MediaTiming.copy(buffer) else { return }
        let time = AVAudioTime.seconds(forHostTime: hostTime)
        lock.lock()
        audio.append(AudioItem(buffer: copy, time: time))
        let cutoff = CACurrentMediaTime() - window - 15
        if let index = audio.firstIndex(where: { $0.time >= cutoff }), index > 0 {
            audio.removeFirst(index)
        }
        lock.unlock()
    }

    func snapshot() -> (video: [ScreenRole: [VideoItem]], audio: [AudioItem]) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = CACurrentMediaTime() - window
        var clipped: [ScreenRole: [VideoItem]] = [:]
        for (role, items) in video {
            let start = items.lastIndex(where: { $0.key && $0.time <= cutoff }) ?? items.firstIndex(where: { $0.key }) ?? items.count
            clipped[role] = Array(items[start...])
        }
        return (clipped, audio)
    }

    func clear() {
        lock.lock()
        video.removeAll()
        audio.removeAll()
        lock.unlock()
    }
}
