import Metal

/// Custom temporal upscaler (TAAU; see taauKernel in Shaders/Output.metal), the alternative to MetalFX: one compute pass
/// at output resolution that writes the drawable directly. Owns the output-resolution history.
final class TemporalUpscaler {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    private let history: [MTLTexture]   // [2], ping-ponged: rgb = colour, a = accumulated sample weight
    private var frame = 0

    init(device: MTLDevice, inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) throws {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        func make(_ format: MTLPixelFormat, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: outputWidth, height: outputHeight, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        history = try (0..<2).map { try make(.rgba16Float, "TAAU history\($0)") }

    }

    /// `jitter` = this frame's sample offset in input pixels (the same value the primary rays used).
    func encode(_ enc: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, targets t: RenderTargets,
                drawable: MTLTexture, jitter: SIMD2<Float>, reset: Bool, settings: UpscalerSettings) {
        let cur = frame & 1, prev = cur ^ 1
        frame += 1
        // The motion cuts are tuned at 3x; lower factors (more input pixels per output pixel) want gentler cuts,
        // about in proportion to (factor - 1) (measured at 2x and 1.5x).
        let factorScale = max(Float(outputWidth) / Float(inputWidth) - 1, 0) / 2
        var params = [SIMD4<Float>(jitter.x, jitter.y, settings.motionCut * factorScale, settings.clipCut),
                      SIMD4<Float>(Float(inputWidth), Float(inputHeight), Float(outputWidth), Float(outputHeight)),
                      SIMD4<Float>(settings.maxHistory, settings.clipWidth, reset ? 1 : 0,
                                   settings.lanczosHistory ? settings.lanczosThreshold : 0),
                      SIMD4<Float>(settings.kernelSharpness, settings.kernelSharpnessMoving,
                                   settings.edgeMotionCut * factorScale, settings.dilationRadius)]
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * params.count, index: 0)
        enc.setTextures([t.upscaleColor, t.deviceDepth, t.pixelMotion, history[prev], history[cur], drawable], range: 0..<6)
        enc.dispatchThreads(MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    }
}
