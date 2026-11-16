import Foundation
import Metal
import MetalFX
import QuartzCore
import CoreVideo

final class MetalContext: @unchecked Sendable {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let convertPipeline: MTLComputePipelineState
    let blitPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let linearSampler: MTLSamplerState
    var textureCache: CVMetalTextureCache?

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ConvertParams {
        float3x3 matrix;
        float3 offset;
    };

    kernel void ycbcrToRGB(texture2d<float, access::read> lumaTexture [[texture(0)]],
                           texture2d<float, access::read> chromaTexture [[texture(1)]],
                           texture2d<float, access::write> output [[texture(2)]],
                           constant ConvertParams &params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float y = lumaTexture.read(gid).r;
        float2 c = chromaTexture.read(gid / 2).rg;
        float3 ycc = float3(y, c.x, c.y) - params.offset;
        float3 rgb = clamp(params.matrix * ycc, 0.0, 1.0);
        output.write(float4(rgb, 1.0), gid);
    }

    struct QuadOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        QuadOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 quadFragment(QuadOut in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 sampler s [[sampler(0)]],
                                 constant float &opacity [[buffer(0)]]) {
        float4 color = source.sample(s, in.uv);
        return float4(color.rgb, opacity);
    }
    """

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.source, options: nil)
        convertPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "ycbcrToRGB")!)

        let blit = MTLRenderPipelineDescriptor()
        blit.vertexFunction = library.makeFunction(name: "quadVertex")
        blit.fragmentFunction = library.makeFunction(name: "quadFragment")
        blit.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitPipeline = try! device.makeRenderPipelineState(descriptor: blit)

        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = blit.vertexFunction
        composite.fragmentFunction = blit.fragmentFunction
        composite.colorAttachments[0].pixelFormat = .bgra8Unorm
        composite.colorAttachments[0].isBlendingEnabled = true
        composite.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        composite.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        composite.colorAttachments[0].sourceAlphaBlendFactor = .one
        composite.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        compositePipeline = try! device.makeRenderPipelineState(descriptor: composite)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func texture(from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    static func convertParams(for buffer: CVPixelBuffer) -> [Float] {
        let matrixKey = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let kr: Float, kb: Float
        if matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
            kr = 0.299; kb = 0.114
        } else if matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            kr = 0.2627; kb = 0.0593
        } else {
            kr = 0.2126; kb = 0.0722
        }
        let kg = 1 - kr - kb
        let yScale: Float = fullRange ? 1 : 255.0 / 219.0
        let cScale: Float = fullRange ? 1 : 255.0 / 224.0
        let yOffset: Float = fullRange ? 0 : 16.0 / 255.0
        let crR = 2 * (1 - kr) * cScale
        let cbB = 2 * (1 - kb) * cScale
        let cbG = -2 * kb * (1 - kb) / kg * cScale
        let crG = -2 * kr * (1 - kr) / kg * cScale
        return [
            yScale, yScale, yScale, 0,
            0, cbG, cbB, 0,
            crR, crG, 0, 0,
            yOffset, 128.0 / 255.0, 128.0 / 255.0, 0,
        ]
    }

    func convert(_ buffer: CVPixelBuffer, into target: inout MTLTexture?, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let luma = texture(from: buffer, plane: 0, format: .r8Unorm),
              let chroma = texture(from: buffer, plane: 1, format: .rg8Unorm) else { return false }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if target == nil || target!.width != width || target!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let output = target, let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var params = Self.convertParams(for: buffer)
        encoder.setComputePipelineState(convertPipeline)
        encoder.setTexture(luma.0, index: 0)
        encoder.setTexture(chroma.0, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&params, length: params.count * MemoryLayout<Float>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        encoder.endEncoding()
        let keep = [luma.1, chroma.1]
        commandBuffer.addCompletedHandler { _ in _ = keep }
        return true
    }

    func drawQuad(_ texture: MTLTexture, into encoder: MTLRenderCommandEncoder, viewport: MTLViewport, opacity: Float = 1, blended: Bool = false) {
        var alpha = opacity
        encoder.setRenderPipelineState(blended ? compositePipeline : blitPipeline)
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

final class MetalRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let context = MetalContext.shared
    private let queue = DispatchQueue(label: "bifrost.render", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var pendingStamp: CFTimeInterval = 0
    private var scheduled = false
    private var rgbTexture: MTLTexture?
    private var scaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private var drawableSize: CGSize = .zero
    private var upscalingEnabled = false
    var onPresented: ((CFTimeInterval) -> Void)?

    init() {
        layer.device = context.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 2
    }

    var upscaling: Bool {
        get { lock.lock(); defer { lock.unlock() }; return upscalingEnabled }
        set {
            lock.lock(); upscalingEnabled = newValue; lock.unlock()
            redraw()
        }
    }

    var latestTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return rgbTexture
    }

    func resize(_ size: CGSize, scale: CGFloat) {
        let pixels = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        lock.lock()
        let changed = pixels != drawableSize
        drawableSize = pixels
        lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.drawableSize = pixels
        CATransaction.commit()
        if changed { redraw() }
    }

    func render(_ buffer: CVPixelBuffer, arrival: CFTimeInterval) {
        lock.lock()
        pending = buffer
        pendingStamp = arrival
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { [weak self] in self?.drawPending() } }
    }

    func redraw() {
        queue.async { [weak self] in self?.draw(buffer: nil, stamp: 0) }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.rgbTexture = nil
            self.pending = nil
            self.lock.unlock()
            self.draw(buffer: nil, stamp: 0)
        }
    }

    private func drawPending() {
        lock.lock()
        let buffer = pending
        let stamp = pendingStamp
        pending = nil
        scheduled = false
        lock.unlock()
        draw(buffer: buffer, stamp: stamp)
    }

    private func draw(buffer: CVPixelBuffer?, stamp: CFTimeInterval) {
        guard let commandBuffer = context.queue.makeCommandBuffer() else { return }
        lock.lock()
        var source = rgbTexture
        let wantUpscale = upscalingEnabled
        lock.unlock()

        if let buffer {
            guard context.convert(buffer, into: &source, commandBuffer: commandBuffer) else { return }
            lock.lock(); rgbTexture = source; lock.unlock()
        }

        guard let drawable = layer.nextDrawable() else {
            commandBuffer.commit()
            return
        }
        let target = drawable.texture
        let fit = aspectFit(source: source, in: CGSize(width: target.width, height: target.height))
        var input = source

        if let src = source, wantUpscale, Int(fit.width) > src.width || Int(fit.height) > src.height,
           let scaled = upscale(src, to: (Int(fit.width), Int(fit.height)), commandBuffer: commandBuffer) {
            input = scaled
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            if let input {
                context.drawQuad(input, into: encoder, viewport: MTLViewport(originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height, znear: 0, zfar: 1))
            }
            encoder.endEncoding()
        }
        if stamp > 0, let onPresented {
            drawable.addPresentedHandler { _ in onPresented(stamp) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func aspectFit(source: MTLTexture?, in size: CGSize) -> CGRect {
        guard let source, source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / CGFloat(source.width), size.height / CGFloat(source.height))
        let w = (CGFloat(source.width) * scale).rounded(), h = (CGFloat(source.height) * scale).rounded()
        return CGRect(x: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: w, height: h)
    }

    private func upscale(_ source: MTLTexture, to size: (Int, Int), commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let key = (source.width, source.height, size.0, size.1)
        if scaler == nil || scalerKey != key {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = source.width
            descriptor.inputHeight = source.height
            descriptor.outputWidth = size.0
            descriptor.outputHeight = size.1
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual
            guard let made = descriptor.makeSpatialScaler(device: context.device) else { return nil }
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
            textureDescriptor.usage = made.outputTextureUsage.union(.shaderRead)
            textureDescriptor.storageMode = .private
            scaledTexture = context.device.makeTexture(descriptor: textureDescriptor)
            scaler = made
            scalerKey = key
        }
        guard let scaler, let output = scaledTexture else { return nil }
        scaler.colorTexture = source
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
        return output
    }
}
