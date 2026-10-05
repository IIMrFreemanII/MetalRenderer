import Metal
import MetalFX

/// MetalFX's denoising scaler (macOS 26): the frame is traced at a lower resolution with a different sub-pixel jitter
/// every frame, and MetalFX takes the raw 1-spp light, still linear and unbounded, with the surface's albedo, normal
/// and roughness to guide it, and returns it denoised at the output resolution. It stands in for SVGF, the shadow
/// denoiser and an upscaler; `tonemapKernel` then writes the drawable.
final class Upscaler {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    /// The scaler's output, linear and unbounded, for tonemapKernel (MetalFX needs a private output texture, so it
    /// can't write the drawable).
    let hdrOutput: MTLTexture
    private let scaler: AnyObject           // MTLFXTemporalDenoisedScaler
    static let hdrFormat = MTLPixelFormat.rgba16Float

    /// Largest per-axis scale factor the GPU supports.
    static func maxScale(on device: MTLDevice) -> Float {
        guard #available(macOS 26.0, *) else { return 1 }
        return MTLFXTemporalDenoisedScalerDescriptor.supportedInputContentMaxScale(device: device)
    }

    /// `synchronous` waits for MetalFX to compile its fast scaler. Otherwise MetalFX returns at once and uses a slower
    /// interim one for the first frames (same image quality), which skews benchmarks.
    /// It is always the Metal 3 scaler: MetalFX's Metal 4 denoising scaler fails an assertion in MPSGraph as it is made
    /// ("Incompatible shape for parameter at index 0") for nearly every size on macOS 26.5: of 19 tried, only 960x540
    /// and 960x544 to twice that worked. So under Metal 4 it runs on a Metal 3 command buffer between two of the
    /// frame's (Metal4Frame.interlude).
    init(device: MTLDevice, inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int,
         synchronous: Bool = false) throws {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
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
        guard let scaler = d.makeTemporalDenoisedScaler(device: device) else {
            throw RendererError.resourceCreation("MetalFX denoising scaler \(inputWidth)×\(inputHeight) → \(outputWidth)×\(outputHeight)")
        }
        scaler.motionVectorScaleX = 1   // motion is already in input pixels
        scaler.motionVectorScaleY = 1
        scaler.isDepthReversed = true   // traceKernel writes near / viewDepth, so 0 = far
        self.scaler = scaler

        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Upscaler.hdrFormat, width: outputWidth, height: outputHeight,
                                                         mipmapped: false)
        t.usage = scaler.outputTextureUsage.union(.shaderRead)   // tonemapKernel reads it
        t.storageMode = .private
        guard let output = device.makeTexture(descriptor: t) else { throw RendererError.resourceCreation("texture upscaled") }
        output.label = "upscaled"
        hdrOutput = output
    }

    /// Denoises and upscales this frame's light into `hdrOutput`, for tonemapKernel to write the drawable.
    func encode(into cmd: MTLCommandBuffer, _ inputs: UpscaleInputs) {
        guard #available(macOS 26.0, *), let scaler = scaler as? MTLFXTemporalDenoisedScaler else { return }
        let t = inputs.targets
        scaler.colorTexture = t.upscaleColor
        scaler.depthTexture = t.deviceDepth
        scaler.motionTexture = t.pixelMotion
        scaler.diffuseAlbedoTexture = t.albedo
        scaler.specularAlbedoTexture = t.specularAlbedo
        scaler.normalTexture = inputs.normalDepth      // xyz = world-space shading normal
        scaler.roughnessTexture = t.roughness
        scaler.outputTexture = hdrOutput
        // MetalFX wants the offset that takes a sample back to the pixel center: the negated ray jitter.
        // (Measured with MetalFX's temporal scaler: the wrong sign cost ~5 dB PSNR against a native-resolution render.)
        scaler.jitterOffsetX = -inputs.jitter.x
        scaler.jitterOffsetY = -inputs.jitter.y
        scaler.worldToViewMatrix = inputs.view.worldToView   // (as of macOS 26.5 the result is the same without them)
        scaler.viewToClipMatrix = inputs.view.viewToClip
        scaler.shouldResetHistory = inputs.reset
        scaler.encode(commandBuffer: cmd)
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
