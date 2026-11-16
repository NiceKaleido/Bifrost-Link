import AVFoundation
import CoreMedia
import QuartzCore

enum MediaTiming {
    static func audioSample(from buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sample
    }

    static func retimed(_ sample: CMSampleBuffer, pts: CMTime, duration: CMTime = .invalid) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            if let src = from.mData, let dst = to.mData {
                memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
        }
        return copy
    }

    static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]
}

final class ScreenRecorderTrack: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let audioFormat: AVAudioFormat
    private var baseTime: CFTimeInterval?
    private var lastVideoPTS = CMTime.negativeInfinity
    private var finished = false
    private let queue = DispatchQueue(label: "bifrost.recorder")

    init(url: URL, audioFormat: AVAudioFormat) throws {
        self.url = url
        self.audioFormat = audioFormat
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false
    }

    func append(video sample: CMSampleBuffer, keyFrame: Bool, at time: CFTimeInterval = CACurrentMediaTime()) {
        queue.async { [self] in
            if finished { return }
            if baseTime == nil {
                guard keyFrame, let format = CMSampleBufferGetFormatDescription(sample), start(format: format) else { return }
                baseTime = time
            }
            guard let base = baseTime, let input = videoInput, input.isReadyForMoreMediaData else { return }
            var pts = CMTime(seconds: time - base, preferredTimescale: 90_000)
            if pts <= lastVideoPTS { pts = lastVideoPTS + CMTime(value: 1, timescale: 90_000) }
            lastVideoPTS = pts
            if let copy = MediaTiming.retimed(sample, pts: pts) { input.append(copy) }
        }
    }

    func append(audio buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        append(audio: buffer, at: AVAudioTime.seconds(forHostTime: hostTime))
    }

    func append(audio buffer: AVAudioPCMBuffer, at time: CFTimeInterval) {
        guard let sample = MediaTiming.audioSample(from: buffer) else { return }
        let rate = CMTimeScale(buffer.format.sampleRate)
        queue.async { [self] in
            guard !finished, let base = baseTime, let input = audioInput, time >= base, input.isReadyForMoreMediaData else { return }
            let pts = CMTime(seconds: time - base, preferredTimescale: rate)
            if let copy = MediaTiming.retimed(sample, pts: pts, duration: CMTime(value: 1, timescale: rate)) { input.append(copy) }
        }
    }

    private func start(format: CMFormatDescription) -> Bool {
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        videoInput = video
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: MediaTiming.audioSettings, sourceFormatHint: audioFormat.formatDescription)
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        }
        guard writer.startWriting() else {
            Log.write("recorder: could not start \(writer.error?.localizedDescription ?? "")")
            finished = true
            return false
        }
        writer.startSession(atSourceTime: .zero)
        return true
    }

    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if finished || baseTime == nil {
                    finished = true
                    if writer.status == .writing { writer.cancelWriting() }
                    continuation.resume(returning: nil)
                    return
                }
                finished = true
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }
}
