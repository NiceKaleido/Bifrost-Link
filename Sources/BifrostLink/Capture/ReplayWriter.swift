import AVFoundation
import CoreMedia

private final class SamplePump: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let count: Int
    private let produce: (Int) -> CMSampleBuffer?
    private var index = 0
    private var done = false

    init(input: AVAssetWriterInput, count: Int, produce: @escaping (Int) -> CMSampleBuffer?) {
        self.input = input
        self.count = count
        self.produce = produce
    }

    func run(on queue: DispatchQueue, group: DispatchGroup) {
        group.enter()
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData && index < count {
                if let sample = produce(index) { input.append(sample) }
                index += 1
            }
            if index >= count && !done {
                done = true
                input.markAsFinished()
                group.leave()
            }
        }
    }
}

enum ReplayWriter {
    static func write(url: URL, video: [ReplayBuffer.VideoItem], audio: [ReplayBuffer.AudioItem], audioFormat: AVAudioFormat) async -> URL? {
        guard let first = video.first, first.key, let format = CMSampleBufferGetFormatDescription(first.sample),
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let base = first.time
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let audioItems = audio.filter { $0.time >= base }
        var audioInput: AVAssetWriterInput?
        if !audioItems.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: MediaTiming.audioSettings, sourceFormatHint: audioFormat.formatDescription)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        var lastPTS = CMTime.negativeInfinity
        let videoPump = SamplePump(input: videoInput, count: video.count) { index in
            let item = video[index]
            var pts = CMTime(seconds: item.time - base, preferredTimescale: 90_000)
            if pts <= lastPTS { pts = lastPTS + CMTime(value: 1, timescale: 90_000) }
            lastPTS = pts
            return MediaTiming.retimed(item.sample, pts: pts)
        }
        videoPump.run(on: DispatchQueue(label: "bifrost.replay.video"), group: group)

        var audioPump: SamplePump?
        if let audioInput {
            let pump = SamplePump(input: audioInput, count: audioItems.count) { index in
                let item = audioItems[index]
                let rate = CMTimeScale(item.buffer.format.sampleRate)
                guard let sample = MediaTiming.audioSample(from: item.buffer) else { return nil }
                return MediaTiming.retimed(sample, pts: CMTime(seconds: item.time - base, preferredTimescale: rate), duration: CMTime(value: 1, timescale: rate))
            }
            pump.run(on: DispatchQueue(label: "bifrost.replay.audio"), group: group)
            audioPump = pump
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        _ = audioPump
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
}
