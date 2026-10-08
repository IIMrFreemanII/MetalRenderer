import Metal
import QuartzCore

/// What a compute stage encodes into: Metal 3's compute encoder (`Metal3Pass`), or Metal 4's with its argument table
/// (`Metal4Frame`). The methods are `MTLComputeCommandEncoder`'s, so the stages read the same for both.
protocol ComputePass {
    func setComputePipelineState(_ state: MTLComputePipelineState)
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setTexture(_ texture: MTLTexture?, index: Int)
    func setTextures(_ textures: [MTLTexture?], range: Range<Int>)
    func setAccelerationStructure(_ accelerationStructure: MTLAccelerationStructure?, bufferIndex: Int)
    func useResource(_ resource: MTLResource, usage: MTLResourceUsage)
    func useResources(_ resources: [MTLResource], usage: MTLResourceUsage)
    func useHeap(_ heap: MTLHeap)
    func memoryBarrier(scope: MTLBarrierScope)
    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
    /// As many threadgroups as an `MTLDispatchThreadgroupsIndirectArguments` the GPU wrote says.
    func dispatchThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threadsPerThreadgroup: MTLSize)
    /// What `useResource`, `useResources` and `useHeap` hold for: Metal 3's encoder, Metal 4's frame. The renderer
    /// declares the scene's resources once per scope (`Renderer.bindScene`).
    var declarationScope: AnyObject { get }
}

/// Metal 3: straight through to the encoder. One reference wide, so passing it as `ComputePass` allocates nothing.
struct Metal3Pass: ComputePass {
    let enc: MTLComputeCommandEncoder
    var declarationScope: AnyObject { enc }

    func setComputePipelineState(_ state: MTLComputePipelineState) { enc.setComputePipelineState(state) }
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { enc.setBytes(bytes, length: length, index: index) }
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { enc.setBuffer(buffer, offset: offset, index: index) }
    func setTexture(_ texture: MTLTexture?, index: Int) { enc.setTexture(texture, index: index) }
    func setTextures(_ textures: [MTLTexture?], range: Range<Int>) { enc.setTextures(textures, range: range) }
    func setAccelerationStructure(_ accelerationStructure: MTLAccelerationStructure?, bufferIndex: Int) {
        enc.setAccelerationStructure(accelerationStructure, bufferIndex: bufferIndex)
    }
    func useResource(_ resource: MTLResource, usage: MTLResourceUsage) { enc.useResource(resource, usage: usage) }
    func useResources(_ resources: [MTLResource], usage: MTLResourceUsage) { enc.useResources(resources, usage: usage) }
    func useHeap(_ heap: MTLHeap) { enc.useHeap(heap) }
    func memoryBarrier(scope: MTLBarrierScope) { enc.memoryBarrier(scope: scope) }
    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        enc.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        enc.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
    func dispatchThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threadsPerThreadgroup: MTLSize) {
        enc.dispatchThreadgroups(indirectBuffer: indirectBuffer, indirectBufferOffset: indirectBufferOffset,
                                 threadsPerThreadgroup: threadsPerThreadgroup)
    }
}

/// What the raster visibility buffer's draw encodes into: Metal 3's render encoder (`Metal3RenderPass`) or Metal 4's
/// (`Metal4Frame`). Buffers go to the vertex stage, and with `setMeshBuffer` to the mesh stage (the raster clusters).
protocol RenderPass {
    func setRenderPipelineState(_ state: MTLRenderPipelineState)
    func setDepthStencilState(_ state: MTLDepthStencilState)
    /// Depth beyond the near and far planes clamped rather than clipped (a shadow caster outside a light's range).
    func clampDepth()
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    /// What the vertices reach through addresses (the meshes' own buffers, the instance blocks', the cut's BLASes).
    func useResources(_ resources: [MTLResource])
    /// Triangles, as many as an `MTLDrawPrimitivesIndirectArguments` the GPU wrote says.
    func drawTriangles(indirectBuffer: MTLBuffer, indirectBufferOffset: Int)
    func setMeshBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setMeshBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    /// Mesh-shader threadgroups of `threads` each, as many as an `MTLDispatchThreadgroupsIndirectArguments` says.
    func drawMeshThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threads: Int)
}

struct Metal3RenderPass: RenderPass {
    let enc: MTLRenderCommandEncoder

    func setRenderPipelineState(_ state: MTLRenderPipelineState) { enc.setRenderPipelineState(state) }
    func setDepthStencilState(_ state: MTLDepthStencilState) { enc.setDepthStencilState(state) }
    func clampDepth() { enc.setDepthClipMode(.clamp) }
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { enc.setVertexBytes(bytes, length: length, index: index) }
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { enc.setVertexBuffer(buffer, offset: offset, index: index) }
    func useResources(_ resources: [MTLResource]) {
        if !resources.isEmpty { enc.useResources(resources, usage: .read, stages: [.vertex, .mesh]) }
    }
    func drawTriangles(indirectBuffer: MTLBuffer, indirectBufferOffset: Int) {
        enc.drawPrimitives(type: .triangle, indirectBuffer: indirectBuffer, indirectBufferOffset: indirectBufferOffset)
    }
    func setMeshBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { enc.setMeshBytes(bytes, length: length, index: index) }
    func setMeshBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { enc.setMeshBuffer(buffer, offset: offset, index: index) }
    func drawMeshThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threads: Int) {
        enc.drawMeshThreadgroups(indirectBuffer: indirectBuffer, indirectBufferOffset: indirectBufferOffset,
                                 threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerMeshThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
    }
}

/// A render pass's attachments: a colour target (or none) and a depth target, cleared (the colour to `clearColor`, the
/// depth to 0, the far end of reversed Z) or loaded as an earlier pass left them. `layers`: a layered pass's slices
/// (the vertices pick theirs), 0 for one.
struct RenderAttachments {
    let color: MTLTexture?
    let depth: MTLTexture
    let clear: Bool
    var clearColor = MTLClearColor()
    var layers = 0

    func apply(color c: MTLRenderPassColorAttachmentDescriptor, depth d: MTLRenderPassDepthAttachmentDescriptor) {
        if let color {
            c.texture = color
            c.loadAction = clear ? .clear : .load
            c.storeAction = .store
            c.clearColor = clearColor
        }
        d.texture = depth
        d.loadAction = clear ? .clear : .load
        d.storeAction = .store
        d.clearDepth = 0
    }
}

/// One named compute dispatch (or a few) of a frame.
struct ComputeStage {
    let pass: String
    let encode: (ComputePass) -> Void
}

/// This frame's update of the top-level acceleration structure: a refit of the tree it has, or a build.
struct TLASUpdate {
    let structure: MTLAccelerationStructure
    let scratch: MTLBuffer
    let refit: Bool
    let instanceCount: Int
    let usage: MTLAccelerationStructureUsage
    /// Metal 3: instance descriptors that index `primitives`, or `indirect` ones, which name them by resource ID
    /// (Metal 4's always are).
    let instances: MTLBuffer
    let instanceStride: Int
    let primitives: [MTLAccelerationStructure]
    var indirect = false

    /// Metal 3's descriptor for it.
    var descriptor: MTLInstanceAccelerationStructureDescriptor {
        let d = MTLInstanceAccelerationStructureDescriptor()
        d.instancedAccelerationStructures = primitives
        d.instanceCount = instanceCount
        d.instanceDescriptorBuffer = instances
        d.instanceDescriptorBufferOffset = 0
        d.instanceDescriptorStride = instanceStride
        d.instanceDescriptorType = .default
        d.usage = usage
        return d
    }

    /// Metal 3's descriptor for a build from either kind of instance descriptors: a still scene's structure is built
    /// once, off the frames, on a Metal 3 queue (SceneBuffers).
    func descriptor(indirect: Bool) -> MTLInstanceAccelerationStructureDescriptor {
        let d = descriptor
        if indirect, #available(macOS 14.0, *) {
            d.instancedAccelerationStructures = nil
            d.instanceDescriptorType = .indirect
        }
        return d
    }
}

/// Per-mesh structures a frame builds or refits, in an acceleration-structure encoder of their own (Metal 4: on the
/// Metal 3 queue, between the frame's command buffers; the plants' variants in the frame's encoder, PlantTracing.Refit).
protocol PrimitiveWork {
    /// How many encoders it takes: the M1 Max's driver doesn't refit many instance structures in one encoder (three
    /// crash), so the plants' variants take two each (PlantTracing.Refit.perEncoder).
    var encoderCount: Int { get }
    /// Encodes part `part` (0..<encoderCount) of the work.
    func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int)
}
extension PrimitiveWork {
    var encoderCount: Int { 1 }
}

/// This frame's refit of the per-mesh structures that deform (the crowd's pose slots): each keeps its tree and takes
/// its boxes from the vertices its descriptor points at, which the skinning has just rewritten. And the build of those
/// whose triangles change (a liquid's surface: FluidSurface.swift), from scratch, into the same structure.
struct PrimitiveRefit: PrimitiveWork {
    let structures: [MTLAccelerationStructure]
    let descriptors: [MTLPrimitiveAccelerationStructureDescriptor]
    let scratch: MTLBuffer
    let scratchOffsets: [Int]
    var rebuilt: [(structure: MTLAccelerationStructure, descriptor: MTLPrimitiveAccelerationStructureDescriptor, scratchOffset: Int)] = []
    /// The mesh each rebuilt structure is of.
    var rebuiltMeshes: [Int] = []

    /// How many of rebuilt structure `i`'s triangles the next builds take (the rest are left out: a liquid's surface
    /// holds room for far more than it needs): at most what it was made for.
    func setTriangles(_ i: Int, _ count: Int) {
        guard let geometry = rebuilt[i].descriptor.geometryDescriptors?.first as? MTLAccelerationStructureTriangleGeometryDescriptor
        else { return }
        geometry.triangleCount = count
    }

    func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int) {
        for (i, structure) in structures.enumerated() {
            enc.refit(sourceAccelerationStructure: structure, descriptor: descriptors[i], destinationAccelerationStructure: structure,
                      scratchBuffer: scratch, scratchBufferOffset: scratchOffsets[i])
        }
        for r in rebuilt {
            enc.build(accelerationStructure: r.structure, descriptor: r.descriptor, scratchBuffer: scratch, scratchBufferOffset: r.scratchOffset)
        }
    }
}

/// What MetalFX reads besides the frame's targets.
struct UpscaleInputs {
    let targets: RenderTargets
    let normalDepth: MTLTexture
    let view: Upscaler.View
    let jitter: SIMD2<Float>
    let reset: Bool
}

/// When a frame's GPU work ran: the whole frame, and with a benchmark's split passes each pass's command buffer.
struct FrameTimes {
    var start: CFTimeInterval = 0
    var end: CFTimeInterval = 0
    var passes: [(name: String, start: CFTimeInterval, end: CFTimeInterval)] = []
}

/// A frame being encoded: its command buffers and its open compute pass. Normally every pass shares one encoder;
/// benchmarks put each pass in its own command buffer (so its GPU time can be read back) and, with Metal 3, the panel's
/// pass timings in its own encoder. `Metal3Frame` encodes for an `MTLCommandQueue`, `Metal4Frame` for Metal 4's.
protocol FrameEncoder: AnyObject {
    /// The compute pass for `name`: the open one, unless passes are timed apart. `serial`: its dispatches run in order
    /// even in a frame whose stages overlap (the TLAS and the sky, ahead of them). `concurrent`: they overlap even in a
    /// frame whose stages don't, and the pass sets its own barriers (the physics: the liquids side by side).
    func compute(_ name: String, serial: Bool, concurrent: Bool) -> ComputePass?
    /// Closes the open pass: at the end of the frame, or ahead of work that isn't a compute dispatch.
    func endCompute()
    func generateMipmaps(_ textures: [MTLTexture], pass: String)
    /// A render pass into `attachments`, between the compute passes before and after it.
    func render(_ name: String, _ attachments: RenderAttachments, encode: (RenderPass) -> Void)
    func updateTLAS(_ update: TLASUpdate, pass: String)
    /// Builds or refits per-mesh structures (the deforming ones after the skinning, the cut's clusters after the cut),
    /// ahead of the TLAS update.
    func updatePrimitives(_ work: PrimitiveWork, pass: String)
    /// Maps and uploads the texture levels last frame's hits asked for, ahead of this frame's work.
    func streamTextures(_ streamer: TextureStreamer, frame: UInt32, slot: Int, framesInFlight: Int)
    /// MetalFX's denoising scaler, into its own texture (`Upscaler.hdrOutput`), which tonemapKernel then reads.
    func upscale(_ upscaler: Upscaler, _ inputs: UpscaleInputs, pass: String)
    /// Copies `texture` (4 bytes a pixel) into `buffer`, for a benchmark's PNG.
    func capture(_ texture: MTLTexture, into buffer: MTLBuffer)
    /// Presents `drawable` and commits. `completed` runs on another thread once the GPU is done; `wait` blocks until then.
    func commit(presenting drawable: CAMetalDrawable?, wait: Bool, completed: @escaping (FrameTimes) -> Void)
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

    init?(queue: MTLCommandQueue, profile: GPUProfiler.Frame?, split: Bool, overlap: Bool) {
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

    func render(_ name: String, _ attachments: RenderAttachments, encode: (RenderPass) -> Void) {
        endCompute()
        let d = MTLRenderPassDescriptor()
        attachments.apply(color: d.colorAttachments[0], depth: d.depthAttachment)
        d.renderTargetArrayLength = attachments.layers
        guard let enc = profile?.render(cmd, name, d) ?? buffer(name).makeRenderCommandEncoder(descriptor: d) else { return }
        enc.label = name
        encode(Metal3RenderPass(enc: enc))
        profile.end(enc)
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

    func streamTextures(_ streamer: TextureStreamer, frame: UInt32, slot: Int, framesInFlight: Int) {
        endCompute()
        let work = streamer.update(frame: frame, slot: slot, framesInFlight: framesInFlight)
        if !work.mappings.isEmpty || !work.uploads.isEmpty { work.encode(into: buffer("textures")) }
    }

    func upscale(_ upscaler: Upscaler, _ inputs: UpscaleInputs, pass: String) {
        endCompute()
        upscaler.encode(into: buffer(pass), inputs)
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
