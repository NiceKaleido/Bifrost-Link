import Foundation
import CoreMedia
import VideoToolbox
import QuartzCore

enum VideoCodecKind: String, CaseIterable, Identifiable {
    case h265
    case h264

    var id: String { rawValue }
    var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264 (AVC)" }

    init?(codecId: UInt32) {
        switch codecId {
        case 0x6832_3634: self = .h264
        case 0x6832_3635: self = .h265
        default: return nil
        }
    }
}

protocol VideoStreamDelegate: AnyObject {
    func videoStream(_ stream: VideoStream, didChangeSize size: CGSize)
    func videoStream(_ stream: VideoStream, didDecode pixelBuffer: CVPixelBuffer, arrival: CFTimeInterval)
    func videoStream(_ stream: VideoStream, didReceiveCompressed sample: CMSampleBuffer, keyFrame: Bool)
    func videoStreamDidEnd(_ stream: VideoStream)
}

final class VideoStream: @unchecked Sendable {
    private let socket: TCPSocket
    weak var delegate: VideoStreamDelegate?
    private(set) var codec: VideoCodecKind = .h265
    private(set) var size: CGSize = .zero
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var session: VTDecompressionSession?
    private(set) var framesDecoded = 0
    private var arrivals: [Int64: CFTimeInterval] = [:]
    private let arrivalLock = NSLock()

    init(socket: TCPSocket) {
        self.socket = socket
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.qualityOfService = .userInteractive
        thread.name = "bifrost.video"
        thread.start()
    }

    func stop() {
        socket.close()
    }

    private func run() {
        defer {
            invalidateSession()
            delegate?.videoStreamDidEnd(self)
        }
        guard let codecData = socket.readExactly(4) else { return }
        let codecId = codecData.readUInt32BE(at: 0)
        guard let kind = VideoCodecKind(codecId: codecId) else {
            NSLog("Unsupported or disabled video codec 0x%08x", codecId)
            return
        }
        codec = kind

        while true {
            guard let header = socket.readExactly(12) else { return }
            let first = header.readUInt64BE(at: 0)
            if first & (1 << 63) != 0 {
                let width = header.readUInt32BE(at: 4)
                let height = header.readUInt32BE(at: 8)
                size = CGSize(width: Int(width), height: Int(height))
                delegate?.videoStream(self, didChangeSize: size)
                continue
            }
            let length = Int(header.readUInt32BE(at: 8))
            guard let payload = socket.readExactly(length) else { return }
            let isConfig = first & (1 << 62) != 0
            let isKey = first & (1 << 61) != 0
            let pts = Int64(first & ((1 << 61) - 1))
            handle(payload: payload, config: isConfig, key: isKey, pts: pts)
        }
    }

    private func nalType(_ nal: Data) -> Int {
        guard let b = nal.first else { return -1 }
        return codec == .h265 ? Int((b >> 1) & 0x3F) : Int(b & 0x1F)
    }

    private func isParameterSet(_ type: Int) -> Bool {
        codec == .h265 ? (type == 32 || type == 33 || type == 34) : (type == 7 || type == 8)
    }

    private func handle(payload: Data, config: Bool, key: Bool, pts: Int64) {
        let nals = Self.splitAnnexB(payload)
        let params = nals.filter { isParameterSet(nalType($0)) }
        if !params.isEmpty {
            updateParameterSets(params)
        }
        if config { return }
        let frames = nals.filter { !isParameterSet(nalType($0)) }
        guard !frames.isEmpty, let format = formatDescription else { return }

        var avcc = Data()
        for nal in frames {
            avcc.appendBE(UInt32(nal.count))
            avcc.append(nal)
        }
        guard let sample = makeSample(avcc: avcc, format: format, pts: pts, key: key) else { return }
        arrivalLock.lock()
        arrivals[pts] = CACurrentMediaTime()
        if arrivals.count > 120 {
            let cutoff = arrivals.keys.sorted().dropLast(60)
            cutoff.forEach { arrivals.removeValue(forKey: $0) }
        }
        arrivalLock.unlock()
        delegate?.videoStream(self, didReceiveCompressed: sample, keyFrame: key)
        decode(sample)
    }

    private func updateParameterSets(_ params: [Data]) {
        var sets: [Data] = []
        if codec == .h265 {
            for wanted in [32, 33, 34] {
                if let p = params.first(where: { nalType($0) == wanted }) ?? parameterSets.first(where: { nalType($0) == wanted }) {
                    sets.append(p)
                }
            }
            guard sets.count == 3 else { return }
        } else {
            for wanted in [7, 8] {
                if let p = params.first(where: { nalType($0) == wanted }) ?? parameterSets.first(where: { nalType($0) == wanted }) {
                    sets.append(p)
                }
            }
            guard sets.count == 2 else { return }
        }
        if sets == parameterSets, formatDescription != nil { return }
        parameterSets = sets

        var format: CMFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            if codec == .h265 {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            } else {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            NSLog("Format description failed: %d", status)
            return
        }
        formatDescription = format
        invalidateSession()
        createSession(format: format)
    }

    private func withPointers<R>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        return pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in
                body(pp.baseAddress!, sp.baseAddress!)
            }
        }
    }

    private func createSession(format: CMVideoFormatDescription) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            NSLog("Decoder session failed: %d", status)
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func makeSample(avcc: Data, format: CMVideoFormatDescription, pts: Int64, key: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let count = avcc.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sizes = [count]
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }
        if !key, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func decode(_ sample: CMSampleBuffer) {
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, pts, _ in
            guard let self, status == noErr, let imageBuffer else { return }
            self.framesDecoded += 1
            self.arrivalLock.lock()
            let arrival = self.arrivals.removeValue(forKey: pts.value) ?? CACurrentMediaTime()
            self.arrivalLock.unlock()
            self.delegate?.videoStream(self, didDecode: imageBuffer, arrival: arrival)
        }
        if status == kVTInvalidSessionErr, let format = formatDescription {
            invalidateSession()
            createSession(format: format)
        }
    }

    static func splitAnnexB(_ data: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && bytes[end - 1] == 0 { end -= 1 }
                    if end > start { result.append(Data(bytes[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n {
            result.append(Data(bytes[start..<n]))
        } else if start < 0 && n > 0 {
            result.append(data)
        }
        return result
    }
}
