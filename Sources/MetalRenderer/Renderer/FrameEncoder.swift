import EngineCore
import Metal
import Physics
import Plants
import QuartzCore

/// What MetalFX reads besides the frame's targets.
package struct UpscaleInputs {
    let targets: RenderTargets
    let normalDepth: MTLTexture
    let view: Upscaler.View
    let jitter: SIMD2<Float>
    let reset: Bool
}

/// When a frame's GPU work ran: the whole frame, and with a benchmark's split passes each pass's command buffer.
package struct FrameTimes {
    var start: CFTimeInterval = 0
    var end: CFTimeInterval = 0
    var passes: [(name: String, start: CFTimeInterval, end: CFTimeInterval)] = []
}

/// A frame being encoded: its command buffers and its open compute pass. Normally every pass shares one encoder;
/// benchmarks put each pass in its own command buffer (so its GPU time can be read back) and, with Metal 3, the panel's
/// pass timings in its own encoder. `Metal3Frame` encodes for an `MTLCommandQueue`, `Metal4Frame` for Metal 4's.
package protocol FrameEncoder: AnyObject {
    /// The compute pass for `name`: the open one, unless passes are timed apart. `serial`: its dispatches run in order
    /// even in a frame whose stages overlap (the TLAS and the sky, ahead of them). `concurrent`: they overlap even in a
    /// frame whose stages don't, and the pass sets its own barriers (the physics: the liquids side by side).
    func compute(_ name: String, serial: Bool, concurrent: Bool) -> ComputePass?
    /// Closes the open pass: at the end of the frame, or ahead of work that isn't a compute dispatch.
    func endCompute()
    func generateMipmaps(_ textures: [MTLTexture], pass: String)
    func updateTLAS(_ update: TLASUpdate, pass: String)
    /// Builds or refits per-mesh structures (the deforming ones after the skinning, the cut's clusters after the cut),
    /// ahead of the TLAS update.
    func updatePrimitives(_ work: PrimitiveWork, pass: String)
    /// Copies buffers' ranges into others (a terrain's sectors' new vertices into their buffers), ahead of what reads them.
    func copyBuffers(_ copies: [BufferCopy], pass: String)
    /// Maps and uploads the texture levels last frame's hits asked for, ahead of this frame's work.
    func streamTextures(_ streamer: TextureStreamer, frame: UInt32, slot: Int, framesInFlight: Int)
    /// MetalFX's denoising scaler, into its own texture (`Upscaler.hdrOutput`), which tonemapKernel then reads.
    func upscale(_ upscaler: Upscaler, _ inputs: UpscaleInputs, pass: String)
    /// MetalFX's frame interpolator: this frame's picture and the one between the last frame's and it into the
    /// interpolator's `slot` (FrameInterpolator.encode).
    func interpolate(_ interpolator: FrameInterpolator, _ inputs: InterpolateInputs, slot: Int, pass: String)
    /// Copies `texture` (4 bytes a pixel) into `buffer`, for a benchmark's PNG.
    func capture(_ texture: MTLTexture, into buffer: MTLBuffer)
    /// Presents `drawable` and commits. `completed` runs on another thread once the GPU is done; `wait` blocks until then.
    func commit(presenting drawable: CAMetalDrawable?, wait: Bool, completed: @escaping (FrameTimes) -> Void)
    /// `resources` are no longer used by any frame (Metal 3 tracks what each one uses: nothing to do).
    func release(_ resources: [MTLResource])
}

extension FrameEncoder {
    func release(_ resources: [MTLResource]) {}
    func compute(_ name: String) -> ComputePass? { compute(name, serial: false, concurrent: false) }
    func compute(_ name: String, serial: Bool) -> ComputePass? { compute(name, serial: serial, concurrent: false) }

    /// Runs stages in order, each in its named pass (consecutive stages of one pass share it).
    func run(_ stages: [ComputeStage]) {
        var pass: String?
        var enc: ComputePass?
        for stage in stages {
            if stage.pass != pass { enc = compute(stage.pass); pass = stage.pass }
            if let enc { stage.encode(enc) }
        }
    }
}

/// A frame for Metal 3's command queue.
final class Metal3Frame: FrameEncoder {
    private let cmd: MTLCommandBuffer
    private let queue: MTLCommandQueue
    private let profile: GPUProfiler.Frame?
    private let split: Bool, overlap: Bool
    private var buffers: [(name: String, cmd: MTLCommandBuffer)] = []   // split only, in the order they run
    private var open: MTLComputeCommandEncoder?
    private var openPass = ""
    private var openConcurrent = false

    package init?(queue: MTLCommandQueue, profile: GPUProfiler.Frame?, split: Bool, overlap: Bool) {
        guard let cmd = queue.makeCommandBuffer() else { return nil }
        (self.cmd, self.queue, self.profile, self.split, self.overlap) = (cmd, queue, profile, split, overlap)
    }

    /// The command buffer for pass `name`: the frame's, or with `split` a new one.
    private func buffer(_ name: String) -> MTLCommandBuffer {
        guard split, let cb = queue.makeCommandBuffer() else { return cmd }
        cb.label = name
        buffers.append((name, cb))
        return cb
    }

    func compute(_ name: String, serial: Bool, concurrent: Bool) -> ComputePass? {
        if let open, !split, profile == nil || name == openPass, !concurrent || openConcurrent { return Metal3Pass(enc: open) }
        endCompute()
        openPass = name
        openConcurrent = concurrent || overlap && !serial
        if let profile {
            open = profile.compute(cmd, name, concurrent: concurrent)
        } else if concurrent {
            open = buffer(name).makeComputeCommandEncoder(dispatchType: .concurrent)
        } else {
            open = overlap && !serial ? cmd.makeComputeCommandEncoder(dispatchType: .concurrent) : buffer(name).makeComputeCommandEncoder()
        }
        return open.map { Metal3Pass(enc: $0) }
    }

    func endCompute() {
        if let open { profile.end(open) }
        open = nil
    }

    func generateMipmaps(_ textures: [MTLTexture], pass: String) {
        endCompute()
        guard let blit = profile?.blit(cmd, pass) ?? buffer(pass).makeBlitCommandEncoder() else { return }
        for texture in textures { blit.generateMipmaps(for: texture) }
        profile.end(blit)
    }

    func updateTLAS(_ u: TLASUpdate, pass: String) {
        endCompute()
        guard let enc = profile?.accelerationStructure(cmd, pass) ?? buffer(pass).makeAccelerationStructureCommandEncoder() else { return }
        let d = u.descriptor(indirect: u.indirect)
        // Indirect descriptors name the meshes' structures by ID: the build reads them, so they must be resident.
        if u.indirect { enc.useResources(u.primitives, usage: .read) }
        if u.refit {
            enc.refit(sourceAccelerationStructure: u.structure, descriptor: d, destinationAccelerationStructure: u.structure,
                      scratchBuffer: u.scratch, scratchBufferOffset: 0)
        } else {
            enc.build(accelerationStructure: u.structure, descriptor: d, scratchBuffer: u.scratch, scratchBufferOffset: 0)
        }
        profile.end(enc)
    }

    func updatePrimitives(_ work: PrimitiveWork, pass: String) {
        endCompute()
        let cb = profile == nil ? buffer(pass) : cmd
        for part in 0..<work.encoderCount {
            guard let enc = (part == 0 ? profile?.accelerationStructure(cmd, pass) : nil) ?? cb.makeAccelerationStructureCommandEncoder() else { return }
            work.encode(into: enc, part: part)
            if part == 0 { profile.end(enc) } else { enc.endEncoding() }
        }
    }

    func copyBuffers(_ copies: [BufferCopy], pass: String) {
        guard !copies.isEmpty else { return }
        endCompute()
        guard let blit = buffer(pass).makeBlitCommandEncoder() else { return }
        blit.label = pass
        for c in copies {
            blit.copy(from: c.source, sourceOffset: c.sourceOffset, to: c.destination, destinationOffset: c.destinationOffset, size: c.size)
        }
        blit.endEncoding()
    }

    func streamTextures(_ streamer: TextureStreamer, frame: UInt32, slot: Int, framesInFlight: Int) {
        endCompute()
        let work = streamer.update(frame: frame, slot: slot, framesInFlight: framesInFlight)
        if !work.mappings.isEmpty || !work.uploads.isEmpty { work.encode(into: buffer("textures")) }
    }

    func upscale(_ upscaler: Upscaler, _ inputs: UpscaleInputs, pass: String) {
        endCompute()
        upscaler.encode(into: buffer(pass), inputs)
    }

    func interpolate(_ interpolator: FrameInterpolator, _ inputs: InterpolateInputs, slot: Int, pass: String) {
        endCompute()
        interpolator.encode(into: buffer(pass), inputs, slot: slot)
    }

    func capture(_ texture: MTLTexture, into buffer: MTLBuffer) {
        endCompute()
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        let w = texture.width, h = texture.height
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * 4 * h)
        blit.endEncoding()
    }

    func commit(presenting drawable: CAMetalDrawable?, wait: Bool, completed: @escaping (FrameTimes) -> Void) {
        endCompute()
        if let drawable { cmd.present(drawable) }
        let buffers = buffers
        cmd.addCompletedHandler { cb in
            var times = FrameTimes(start: cb.gpuStartTime, end: cb.gpuEndTime)
            for p in buffers {
                p.cmd.waitUntilCompleted()
                times.passes.append((p.name, p.cmd.gpuStartTime, p.cmd.gpuEndTime))
            }
            completed(times)
        }
        for p in buffers { p.cmd.commit() }
        cmd.commit()
        if wait { cmd.waitUntilCompleted() }
    }
}
