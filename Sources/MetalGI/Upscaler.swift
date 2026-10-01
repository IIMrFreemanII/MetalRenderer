import Metal
import MetalFX

/// MetalFX temporal upscaling: the frame is traced at a lower resolution with a different sub-pixel
/// jitter every frame, and MetalFX accumulates those samples into a higher-resolution image.
/// Or, with `spatial`, MetalFX's spatial scaler: it upscales each frame on its own (no jitter, no history), which
/// is ~3x cheaper but softer and doesn't anti-alias edges.
/// (MetalFX's denoising scaler also runs on an M1 Max under macOS 27, but costs 4.2 ms here: more than the
/// SVGF denoiser plus the temporal scaler it would replace.)
final class Upscaler {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let spatial: Bool
    /// What compositeKernel writes for MetalFX to upscale: `targets.upscaleColor`, or for the spatial scaler (which
    /// can't mix a linear input with the sRGB output) its own sRGB texture.
    let spatialInput: MTLTexture?
    private let output: MTLTexture          // MetalFX needs a private output texture, so it can't write the drawable
    private let temporalScaler: MTLFXTemporalScaler?
    private let spatialScaler: MTLFXSpatialScaler?

    static func isSupported(on device: MTLDevice) -> Bool {
        MTLFXTemporalScalerDescriptor.supportsDevice(device)
    }

    /// Largest per-axis scale factor the GPU supports (3.0 on an M1 Max).
    static func maxScale(on device: MTLDevice) -> Float {
        guard #available(macOS 14.0, *) else { return 2 }
        return MTLFXTemporalScalerDescriptor.supportedInputContentMaxScale(device: device)
    }

    /// `synchronous` waits for MetalFX to compile its fast upscaler. Otherwise MetalFX returns at once and
    /// uses a slower interim upscaler for the first frames (same image quality), which skews benchmarks.
    init(device: MTLDevice, inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int,
         spatial: Bool = false, synchronous: Bool = false) throws {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.spatial = spatial
        let outputUsage: MTLTextureUsage
        if spatial {
            let d = MTLFXSpatialScalerDescriptor()
            d.colorTextureFormat = Renderer.drawableFormat
            d.outputTextureFormat = Renderer.drawableFormat
            d.inputWidth = inputWidth
            d.inputHeight = inputHeight
            d.outputWidth = outputWidth
            d.outputHeight = outputHeight
            guard let scaler = d.makeSpatialScaler(device: device) else {
                throw RendererError.resourceCreation("MetalFX spatial scaler \(inputWidth)×\(inputHeight) → \(outputWidth)×\(outputHeight)")
            }
            spatialScaler = scaler
            temporalScaler = nil
            outputUsage = scaler.outputTextureUsage
            let id = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.drawableFormat, width: inputWidth,
                                                              height: inputHeight, mipmapped: false)
            id.usage = scaler.colorTextureUsage.union(.shaderWrite)
            id.storageMode = .private
            guard let input = device.makeTexture(descriptor: id) else { throw RendererError.resourceCreation("texture spatial input") }
            input.label = "spatial input"
            spatialInput = input
        } else {
            let scaler = try Upscaler.makeTemporalScaler(device: device, inputWidth: inputWidth, inputHeight: inputHeight,
                                                         outputWidth: outputWidth, outputHeight: outputHeight,
                                                         synchronous: synchronous)
            temporalScaler = scaler
            spatialScaler = nil
            spatialInput = nil
            outputUsage = scaler.outputTextureUsage
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.drawableFormat, width: outputWidth,
                                                          height: outputHeight, mipmapped: false)
        td.usage = outputUsage
        td.storageMode = .private
        guard let output = device.makeTexture(descriptor: td) else {
            throw RendererError.resourceCreation("texture upscaled")
        }
        output.label = "upscaled"
        self.output = output
    }

    private static func makeTemporalScaler(device: MTLDevice, inputWidth: Int, inputHeight: Int, outputWidth: Int,
                                           outputHeight: Int, synchronous: Bool) throws -> MTLFXTemporalScaler {

        let d = MTLFXTemporalScalerDescriptor()
        d.colorTextureFormat = RenderTargets.upscaleColorFormat
        d.depthTextureFormat = RenderTargets.upscaleDepthFormat
        d.motionTextureFormat = RenderTargets.upscaleMotionFormat
        d.outputTextureFormat = Renderer.drawableFormat   // same format as the drawable: a plain copy presents it
        d.inputWidth = inputWidth
        d.inputHeight = inputHeight
        d.outputWidth = outputWidth
        d.outputHeight = outputHeight
        d.requiresSynchronousInitialization = synchronous
        guard let scaler = d.makeTemporalScaler(device: device) else {
            throw RendererError.resourceCreation("MetalFX temporal scaler \(inputWidth)×\(inputHeight) → \(outputWidth)×\(outputHeight)")
        }
        scaler.motionVectorScaleX = 1   // motion is already in input pixels
        scaler.motionVectorScaleY = 1
        scaler.isDepthReversed = true   // traceKernel writes near / viewDepth, so 0 = far
        return scaler
    }

    /// Upscales into a private texture, then copies it to `drawable` (`Renderer.drawableFormat`, outputWidth x outputHeight).
    func encode(into cmd: MTLCommandBuffer, targets t: RenderTargets, drawable: MTLTexture, jitter: SIMD2<Float>, reset: Bool) {
        if let scaler = spatialScaler {
            scaler.colorTexture = spatialInput
            scaler.outputTexture = output
            scaler.inputContentWidth = inputWidth
            scaler.inputContentHeight = inputHeight
            scaler.encode(commandBuffer: cmd)
        } else if let scaler = temporalScaler {
            encodeTemporal(scaler, into: cmd, targets: t, jitter: jitter, reset: reset)
        }
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: output, to: drawable)
            blit.endEncoding()
        }
    }

    private func encodeTemporal(_ scaler: MTLFXTemporalScaler, into cmd: MTLCommandBuffer, targets t: RenderTargets,
                                jitter: SIMD2<Float>, reset: Bool) {
        scaler.colorTexture = t.upscaleColor
        scaler.depthTexture = t.deviceDepth
        scaler.motionTexture = t.pixelMotion
        scaler.outputTexture = output
        scaler.inputContentWidth = inputWidth
        scaler.inputContentHeight = inputHeight
        // MetalFX wants the offset that takes a sample back to the pixel center: the negated ray jitter.
        // (Measured: the wrong sign costs ~5 dB PSNR against a native-resolution render.)
        scaler.jitterOffsetX = -jitter.x
        scaler.jitterOffsetY = -jitter.y
        scaler.reset = reset
        scaler.encode(commandBuffer: cmd)
    }

    /// Sub-pixel jitter in [-0.5, 0.5) pixels from the Halton(2, 3) sequence, added to each primary ray's pixel position.
    /// MetalFX suggests about 8 phases per unit of upscale area (8 × scale²).
    static func jitter(frame: UInt32, scale: Float) -> SIMD2<Float> {
        let phases = UInt32(max(8, (8 * scale * scale).rounded()))
        let i = frame % phases + 1
        return SIMD2(halton(i, 2), halton(i, 3)) - 0.5
    }

    private static func halton(_ index: UInt32, _ base: UInt32) -> Float {
        var f: Float = 1, r: Float = 0, i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }
}
