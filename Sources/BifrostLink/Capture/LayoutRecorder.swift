import AVFoundation
import Metal
import CoreVideo
import QuartzCore

final class LayoutRecorder: @unchecked Sendable {
    let url: URL
    let size: CGSize
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = MetalContext.shared
    private let queue = DispatchQueue(label: "bifrost.layout-recorder", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var baseTime: CFTimeInterval?
    private var lastPTS = CMTime.negativeInfinity
    private var finished = false
    private var spec: LayoutSpec
    private let sources: [ScreenRole: MetalRenderer]

    init(url: URL, spec: LayoutSpec, sources: [ScreenRole: MetalRenderer], audioFormat: AVAudioFormat) throws {
        self.url = url
        self.spec = spec
        self.sources = sources
        let content = StageLayout.contentSize(spec: spec) ?? CGSize(width: 1920, height: 1080)
        let scale = min(1, 2560 / max(content.width, content.height))
        size = CGSize(width: (content.width * scale / 2).rounded() * 2, height: (content.height * scale / 2).rounded() * 2)

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(videoInput)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: MediaTiming.audioSettings, sourceFormatHint: audioFormat.formatDescription)
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }
    }

    func start() -> Bool {
        guard writer.startWriting() else {
            Log.write("layout recorder: \(writer.error?.localizedDescription ?? "could not start")")
            return false
        }
        writer.startSession(atSourceTime: .zero)
        lock.lock(); baseTime = CACurrentMediaTime(); lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        self.timer = timer
        return true
    }

    func update(spec: LayoutSpec) {
        lock.lock(); self.spec = spec; lock.unlock()
    }

    func append(audio buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let audioInput, let sample = MediaTiming.audioSample(from: buffer) else { return }
        let time = AVAudioTime.seconds(forHostTime: hostTime)
        let rate = CMTimeScale(buffer.format.sampleRate)
        queue.async { [self] in
            lock.lock()
            let base = baseTime
            let done = finished
            lock.unlock()
            guard !done, let base, time >= base, audioInput.isReadyForMoreMediaData else { return }
            if let copy = MediaTiming.retimed(sample, pts: CMTime(seconds: time - base, preferredTimescale: rate), duration: CMTime(value: 1, timescale: rate)) {
                audioInput.append(copy)
            }
        }
    }

    private func renderFrame() {
        lock.lock()
        let spec = self.spec
        let base = baseTime
        let done = finished
        lock.unlock()
        guard !done, let base, videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer,
              let target = context.texture(from: pixelBuffer, plane: 0, format: .bgra8Unorm),
              let commandBuffer = context.queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.0
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let placements = StageLayout.placements(in: size, gap: 0, spec: spec)
        let ordered = placements.sorted { !$0.value.floating && $1.value.floating }
        for (role, placement) in ordered where placement.visible {
            guard let texture = sources[role]?.latestTexture else { continue }
            let r = placement.rect
            context.drawQuad(texture, into: encoder,
                             viewport: MTLViewport(originX: r.minX, originY: r.minY, width: r.width, height: r.height, znear: 0, zfar: 1),
                             opacity: placement.floating ? Float(spec.overlayOpacity) : 1,
                             blended: placement.floating)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pts = CMTime(seconds: CACurrentMediaTime() - base, preferredTimescale: 600)
        if pts <= lastPTS { pts = lastPTS + CMTime(value: 1, timescale: 600) }
        lastPTS = pts
        adaptor.append(pixelBuffer, withPresentationTime: pts)
        _ = target.1
    }

    func finish() async -> URL? {
        timer?.cancel()
        timer = nil
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                lock.lock(); finished = true; lock.unlock()
                guard writer.status == .writing else {
                    continuation.resume(returning: nil)
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }
}
