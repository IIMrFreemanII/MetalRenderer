import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
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
/// benchmarks and the Debug window's pass timings put each pass in its own command buffer, so its GPU time can be read
/// back. `Metal4Frame` (Metal4Backend.swift) encodes it for Metal 4's queue.
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
    /// `resources` are no longer used by any frame: they leave the residency set.
    func release(_ resources: [MTLResource])
    /// What follows waits on the GPU for `event` to reach `value`; `event` is set to `value` once the work encoded so
    /// far is done: the frame and another queue's work (the physics' steps, Renderer.encodeSceneUpdate) in step.
    func wait(for event: MTLSharedEvent, value: UInt64)
    func signal(_ event: MTLSharedEvent, value: UInt64)
}

extension FrameEncoder {
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
