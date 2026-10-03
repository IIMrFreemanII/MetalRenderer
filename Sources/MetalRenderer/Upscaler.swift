import Metal
import MetalFX

/// MetalFX temporal upscaling: the frame is traced at a lower resolution with a different sub-pixel
/// jitter every frame, and MetalFX accumulates those samples into a higher-resolution image.
/// Or, with `.metalFXSpatial`, MetalFX's spatial scaler: it upscales each frame on its own (no jitter, no history),
/// which is ~3x cheaper but softer and doesn't anti-alias edges.
/// Or, with `.metalFXDenoised` (macOS 26), MetalFX's denoising scaler: it takes the raw 1-spp light, still linear and
/// unbounded, with the surface's albedo, normal and roughness to guide it, and returns it denoised at the output
/// resolution. It stands in for SVGF, the shadow denoiser and the upscaler; `tonemapKernel` then writes the drawable.
final class Upscaler {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let kind: UpscalerKind
    var spatial: Bool { kind == .metalFXSpatial }
    var denoising: Bool { kind == .metalFXDenoised }
    /// What compositeKernel writes for MetalFX to upscale: `targets.upscaleColor`, or for the spatial scaler (which
    /// can't mix a linear input with the sRGB output) its own sRGB texture.
    let spatialInput: MTLTexture?
    /// The denoising scaler's output, linear and unbounded, for tonemapKernel. The others' is copied to the drawable.
    var hdrOutput: MTLTexture? { denoising ? output : nil }
    private let output: MTLTexture          // MetalFX needs a private output texture, so it can't write the drawable
    /// The scaler was made for Metal 4 frames: it encodes into Metal 4 command buffers (made with an MTL4Compiler)...
    let metal4: Bool
    /// ...or, the denoising scaler, into a Metal 3 one that runs between two of them.
    let bridged: Bool
    private let temporalScaler: MTLFXTemporalScaler?
    private let spatialScaler: MTLFXSpatialScaler?
    private let otherScaler: AnyObject?     // macOS 26: MTLFXTemporalDenoisedScaler, or one of MetalFX's Metal 4 scalers
    static let hdrFormat = MTLPixelFormat.rgba16Float

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
    /// `compiler`: Metal 4's (an `MTL4Compiler`): the scaler is then MetalFX's Metal 4 one, for an `MTL4CommandBuffer`.
    init(device: MTLDevice, inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int,
         kind: UpscalerKind = .metalFX, synchronous: Bool = false, compiler: AnyObject? = nil) throws {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.kind = kind
        metal4 = compiler != nil
        // MetalFX's Metal 4 denoising scaler fails an assertion in MPSGraph as it is made ("Incompatible shape for
        // parameter at index 0") for nearly every size on macOS 26.5: of 19 tried, only 960x540 and 960x544 to twice
        // that worked. So under Metal 4 the denoiser stays the Metal 3 one, on a Metal 3 command buffer between two
        // of the frame's (Metal4Frame.interlude).
        bridged = compiler != nil && kind == .metalFXDenoised
        let compiler = bridged ? nil : compiler
        let size = "\(inputWidth)×\(inputHeight) → \(outputWidth)×\(outputHeight)"
        var outputUsage = MTLTextureUsage.renderTarget
        var temporal: MTLFXTemporalScaler?, spatial: MTLFXSpatialScaler?, other: AnyObject?
        var spatialUsage: MTLTextureUsage?

        switch kind {
        case .metalFXDenoised:
            guard #available(macOS 26.0, *) else { throw RendererError.resourceCreation("MetalFX denoising scaler (needs macOS 26)") }
            let d = MTLFXTemporalDenoisedScalerDescriptor()
            d.colorTextureFormat = RenderTargets.upscaleColorFormat
            d.depthTextureFormat = RenderTargets.upscaleDepthFormat
            d.motionTextureFormat = RenderTargets.upscaleMotionFormat
            d.diffuseAlbedoTextureFormat = RenderTargets.gBufferFormat
            d.specularAlbedoTextureFormat = RenderTargets.gBufferFormat
            d.normalTextureFormat = RenderTargets.gBufferFormat
            d.roughnessTextureFormat = RenderTargets.roughnessFormat
            d.outputTextureFormat = Upscaler.hdrFormat
            (d.inputWidth, d.inputHeight, d.outputWidth, d.outputHeight) = (inputWidth, inputHeight, outputWidth, outputHeight)
            d.requiresSynchronousInitialization = synchronous
            // The light arrives before the camera's exposure (tonemapKernel applies it), so MetalFX finds its own. A fixed
            // exposure texture, and a denoise-strength mask over the sky and the emitters, scored the same (hwrtq).
            d.isAutoExposureEnabled = true
            let scaler: MTLFXTemporalDenoisedScalerBase?
            if let compiler = compiler as? MTL4Compiler { scaler = d.makeTemporalDenoisedScaler(device: device, compiler: compiler) }
            else { scaler = d.makeTemporalDenoisedScaler(device: device) }
            guard let scaler else { throw RendererError.resourceCreation("MetalFX denoising scaler \(size)") }
            scaler.motionVectorScaleX = 1   // as for the temporal scaler
            scaler.motionVectorScaleY = 1
            scaler.isDepthReversed = true
            outputUsage = scaler.outputTextureUsage.union(.shaderRead)   // tonemapKernel reads it
            other = scaler
        case .metalFXSpatial:
            let d = MTLFXSpatialScalerDescriptor()
            d.colorTextureFormat = Renderer.drawableFormat
            d.outputTextureFormat = Renderer.drawableFormat
            (d.inputWidth, d.inputHeight, d.outputWidth, d.outputHeight) = (inputWidth, inputHeight, outputWidth, outputHeight)
            if #available(macOS 26.0, *), let compiler = compiler as? MTL4Compiler {
                guard let scaler = d.makeSpatialScaler(device: device, compiler: compiler) else {
                    throw RendererError.resourceCreation("MetalFX spatial scaler (Metal 4) \(size)")
                }
                (outputUsage, spatialUsage, other) = (scaler.outputTextureUsage, scaler.colorTextureUsage, scaler)
            } else {
                guard let scaler = d.makeSpatialScaler(device: device) else {
                    throw RendererError.resourceCreation("MetalFX spatial scaler \(size)")
                }
                (outputUsage, spatialUsage, spatial) = (scaler.outputTextureUsage, scaler.colorTextureUsage, scaler)
            }
        default:
            let d = MTLFXTemporalScalerDescriptor()
            d.colorTextureFormat = RenderTargets.upscaleColorFormat
            d.depthTextureFormat = RenderTargets.upscaleDepthFormat
            d.motionTextureFormat = RenderTargets.upscaleMotionFormat
            d.outputTextureFormat = Renderer.drawableFormat   // same format as the drawable: a plain copy presents it
            (d.inputWidth, d.inputHeight, d.outputWidth, d.outputHeight) = (inputWidth, inputHeight, outputWidth, outputHeight)
            d.requiresSynchronousInitialization = synchronous
            if #available(macOS 26.0, *), let compiler = compiler as? MTL4Compiler {
                guard let scaler = d.makeTemporalScaler(device: device, compiler: compiler) else {
                    throw RendererError.resourceCreation("MetalFX temporal scaler (Metal 4) \(size)")
                }
                scaler.motionVectorScaleX = 1
                scaler.motionVectorScaleY = 1
                scaler.isDepthReversed = true
                (outputUsage, other) = (scaler.outputTextureUsage, scaler)
            } else {
                guard let scaler = d.makeTemporalScaler(device: device) else {
                    throw RendererError.resourceCreation("MetalFX temporal scaler \(size)")
                }
                scaler.motionVectorScaleX = 1   // motion is already in input pixels
                scaler.motionVectorScaleY = 1
                scaler.isDepthReversed = true   // traceKernel writes near / viewDepth, so 0 = far
                (outputUsage, temporal) = (scaler.outputTextureUsage, scaler)
            }
        }
        (temporalScaler, spatialScaler, otherScaler) = (temporal, spatial, other)

        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        spatialInput = try spatialUsage.map { try texture(Renderer.drawableFormat, inputWidth, inputHeight, $0.union(.shaderWrite), "spatial input") }
        output = try texture(kind == .metalFXDenoised ? Upscaler.hdrFormat : Renderer.drawableFormat, outputWidth, outputHeight,
                             outputUsage, "upscaled")
    }

    /// Upscales into a private texture, then copies it to `drawable` (`Renderer.drawableFormat`, outputWidth x outputHeight).
    /// The denoising scaler's result stays in `hdrOutput`, for tonemapKernel to write the drawable.
    func encode(into cmd: MTLCommandBuffer, _ inputs: UpscaleInputs, output drawable: MTLTexture) {
        let t = inputs.targets
        if #available(macOS 26.0, *), let scaler = otherScaler as? MTLFXTemporalDenoisedScaler {
            configure(scaler, inputs)
            scaler.encode(commandBuffer: cmd)
            return
        }
        if let scaler = spatialScaler {
            scaler.colorTexture = spatialInput
            scaler.outputTexture = output
            scaler.inputContentWidth = inputWidth
            scaler.inputContentHeight = inputHeight
            scaler.encode(commandBuffer: cmd)
        } else if let scaler = temporalScaler {
            scaler.colorTexture = t.upscaleColor
            scaler.depthTexture = t.deviceDepth
            scaler.motionTexture = t.pixelMotion
            scaler.outputTexture = output
            scaler.inputContentWidth = inputWidth
            scaler.inputContentHeight = inputHeight
            // MetalFX wants the offset that takes a sample back to the pixel center: the negated ray jitter.
            // (Measured: the wrong sign costs ~5 dB PSNR against a native-resolution render.)
            scaler.jitterOffsetX = -inputs.jitter.x
            scaler.jitterOffsetY = -inputs.jitter.y
            scaler.reset = inputs.reset
            scaler.encode(commandBuffer: cmd)
        }
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: output, to: drawable)
            blit.endEncoding()
        }
    }

    /// The same for a Metal 4 command buffer (the scaler was made with a compiler). MetalFX's passes wait for `fence`
    /// and update it, which orders them after the frame's encoder before them and ahead of the one after. Returns the
    /// textures the scaler uses, for the frame's residency set: the last is its result, which the caller copies out
    /// unless it is `hdrOutput`.
    @available(macOS 26.0, *)
    func encode(into cmd: MTL4CommandBuffer, _ inputs: UpscaleInputs, fence: MTLFence) -> [MTLTexture] {
        let t = inputs.targets
        switch otherScaler {
        case let scaler as MTL4FXTemporalDenoisedScaler:
            configure(scaler, inputs)
            scaler.fence = fence
            scaler.encode(commandBuffer: cmd)
            return [t.upscaleColor, t.deviceDepth, t.pixelMotion, t.albedo, t.specularAlbedo, inputs.normalDepth, t.roughness, output]
        case let scaler as MTL4FXSpatialScaler:
            scaler.colorTexture = spatialInput
            scaler.outputTexture = output
            scaler.inputContentWidth = inputWidth
            scaler.inputContentHeight = inputHeight
            scaler.fence = fence
            scaler.encode(commandBuffer: cmd)
            return [spatialInput, output].compactMap { $0 }
        case let scaler as MTL4FXTemporalScaler:
            scaler.colorTexture = t.upscaleColor
            scaler.depthTexture = t.deviceDepth
            scaler.motionTexture = t.pixelMotion
            scaler.outputTexture = output
            scaler.inputContentWidth = inputWidth
            scaler.inputContentHeight = inputHeight
            scaler.jitterOffsetX = -inputs.jitter.x
            scaler.jitterOffsetY = -inputs.jitter.y
            scaler.reset = inputs.reset
            scaler.fence = fence
            scaler.encode(commandBuffer: cmd)
            return [t.upscaleColor, t.deviceDepth, t.pixelMotion, output]
        default:
            return []
        }
    }

    /// This frame's inputs for the denoising scaler (the properties are MTLFXTemporalDenoisedScalerBase's, which the
    /// Metal 4 scaler shares).
    @available(macOS 26.0, *)
    private func configure(_ scaler: MTLFXTemporalDenoisedScalerBase, _ inputs: UpscaleInputs) {
        let t = inputs.targets
        scaler.colorTexture = t.upscaleColor
        scaler.depthTexture = t.deviceDepth
        scaler.motionTexture = t.pixelMotion
        scaler.diffuseAlbedoTexture = t.albedo
        scaler.specularAlbedoTexture = t.specularAlbedo
        scaler.normalTexture = inputs.normalDepth      // xyz = world-space shading normal
        scaler.roughnessTexture = t.roughness
        scaler.outputTexture = output
        scaler.jitterOffsetX = -inputs.jitter.x        // as for the temporal scaler
        scaler.jitterOffsetY = -inputs.jitter.y
        scaler.worldToViewMatrix = inputs.view.worldToView   // (as of macOS 26.5 the result is the same without them)
        scaler.viewToClipMatrix = inputs.view.viewToClip
        scaler.shouldResetHistory = inputs.reset
    }

    /// The camera a frame was traced with, for the denoising scaler.
    struct View {
        var worldToView = matrix_identity_float4x4
        var viewToClip = matrix_identity_float4x4
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
