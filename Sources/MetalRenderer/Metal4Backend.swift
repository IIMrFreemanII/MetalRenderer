import Metal
import MetalFX
import QuartzCore

/// Frames through Metal 4's command model (`RenderAPI.metal4`, macOS 26): an `MTL4CommandQueue`, command buffers that
/// are reused with a command allocator per frame slot, one unified compute encoder for dispatches, blits and
/// acceleration-structure updates, bindings through an argument table, residency sets in place of `useResource`, and
/// explicit barriers where Metal 3 tracked hazards itself. One instance lives as long as the renderer; `begin` starts
/// each frame, and nothing but the commit's options is allocated per frame.
///
/// It is both the frame (`FrameEncoder`) and the pass the stages encode into (`ComputePass`): the kernels and their
/// stages are the same ones Metal 3 runs.
///
/// Left on the Metal 3 queue, where they run once or have no Metal 4 form: texture uploads and mip chains
/// (MaterialTextures), the per-mesh acceleration structures (built once per scene), and inside a frame (`interlude`)
/// mipmap generation and MetalFX's denoising scaler (see `generateMipmaps` and Upscaler for what Metal 4's do on macOS
/// 26.5). Streamed textures (TextureStreamer) are placement-sparse here: residency sets take no sparse heap, and the
/// queue maps their tiles between the frame's command buffers (`streamTextures`).
@available(macOS 26.0, *)
final class Metal4Frame: FrameEncoder, ComputePass {
    let queue: MTL4CommandQueue
    /// Compiles the pipelines (Pipelines).
    let compiler: MTL4Compiler
    private let device: MTLDevice
    private let allocators: [MTL4CommandAllocator]          // per frame slot
    private var pool: [[MTL4CommandBuffer]]                 // per frame slot; more than one only with split passes
    private let table: MTL4ArgumentTable                    // bindings are captured at each dispatch, so one serves all
    private let constants: [MTLBuffer]                      // per frame slot: what Metal 3's setBytes copies
    private static let constantsLength = 1 << 20
    private static let stages: MTLStages = [.dispatch, .blit, .accelerationStructure]
    /// What a new encoder waits for: the work committed before it (the visibility buffer's draws too, `render`), and
    /// the queue's mapping updates.
    private static let queueStages: MTLStages = stages.union([.resourceState, .vertex, .fragment])

    // Residency: every resource a frame binds, added the first time and dropped once unused for a while.
    private let residency: MTLResidencySet
    private var resident: [ObjectIdentifier: (allocation: MTLAllocation, used: UInt32)] = [:]
    private var residencyChanged = false
    private var frameCount: UInt32 = 0
    /// Frames. `METALRENDERER_RESIDENCY_LIFE=<frames>` shortens it, so that a run of a thousand frames reaches the
    /// dropping: a resource some frame reaches without declaring it faults a few hundred frames after its last use.
    private static let residencyLife: UInt32 = ProcessInfo.processInfo.environment["METALRENDERER_RESIDENCY_LIFE"].flatMap { UInt32($0) } ?? 600

    // Work that stays on the Metal 3 queue in the middle of a frame (`interlude`): each queue waits for the other
    // through this event's values.
    private let metal3Queue: MTLCommandQueue
    private let event: MTLSharedEvent
    private var eventValue: UInt64 = 0

    // The frame being encoded.
    private var slot = 0
    private var split = false, overlap = false
    private var cursor = 0                                   // command buffers of the slot's pool in use
    private var constantsCursor = 0
    /// The frame's command buffers in the order they run: Metal 4's, and between them the Metal 3 interludes, which
    /// wait for the event to reach `value` and leave it at `value + 1`, and the streamed textures' mapping updates.
    private enum Buffer {
        case metal4(name: String, cmd: MTL4CommandBuffer)
        case metal3(name: String, cmd: MTLCommandBuffer, value: UInt64)
        case mappings(heap: MTLHeap, [(texture: MTLTexture, ops: [MTL4UpdateSparseTextureMappingOperation])])
    }
    private var buffers: [Buffer] = []
    private var cmd: MTL4CommandBuffer?
    private var enc: MTL4ComputeCommandEncoder?
    private var serial = true                                // a barrier ahead of every dispatch, as Metal 3's serial encoder
    private var encoded: MTLStages = []                      // stages encoded since the encoder's last barrier

    init?(device: MTLDevice, streamQueue: MTLCommandQueue, framesInFlight: Int, layer: CAMetalLayer?) {
        guard let queue = device.makeMTL4CommandQueue(),
              let compiler = try? device.makeCompiler(descriptor: MTL4CompilerDescriptor()),
              let event = device.makeSharedEvent() else { return nil }
        let td = MTL4ArgumentTableDescriptor()
        td.maxBufferBindCount = 31
        td.maxTextureBindCount = 64
        guard let table = try? device.makeArgumentTable(descriptor: td),
              let residency = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor()) else { return nil }
        var allocators: [MTL4CommandAllocator] = [], pool: [[MTL4CommandBuffer]] = [], constants: [MTLBuffer] = []
        for slot in 0..<framesInFlight {
            guard let allocator = device.makeCommandAllocator(), let cmd = device.makeCommandBuffer(),
                  let buffer = device.makeBuffer(length: Metal4Frame.constantsLength, options: .storageModeShared) else { return nil }
            buffer.label = "constants\(slot)"
            allocators.append(allocator)
            pool.append([cmd])
            constants.append(buffer)
            residency.addAllocation(buffer)
        }
        residency.commit()
        queue.addResidencySet(residency)
        if let layer { queue.addResidencySet(layer.residencySet) }   // the drawables
        (self.device, self.queue, self.compiler, self.table, self.residency) = (device, queue, compiler, table, residency)
        (self.allocators, self.pool, self.constants) = (allocators, pool, constants)
        (self.metal3Queue, self.event) = (streamQueue, event)
    }

    /// Starts a frame in `slot`, whose last frame is done (the renderer's frame semaphore). `split`: a command buffer per
    /// pass, each timed; `overlap`: the stages' dispatches may run together, apart from where they set a barrier.
    func begin(slot: Int, split: Bool, overlap: Bool) -> Metal4Frame {
        (self.slot, self.split, self.overlap) = (slot, split, overlap)
        allocators[slot].reset()
        cursor = 0
        constantsCursor = 0
        buffers.removeAll(keepingCapacity: true)
        frameCount &+= 1
        if frameCount % 256 == 0 { releaseUnused() }
        if let changed = sceneChanged, frameCount &- changed > Metal4Frame.sceneLife {
            releaseUnused(since: changed)
            sceneChanged = nil
        }
        cmd = nil
        enc = nil
        return self
    }

    // MARK: - Residency

    fileprivate func keep(_ allocation: MTLAllocation) {
        let id = ObjectIdentifier(allocation)
        if resident.updateValue((allocation, frameCount), forKey: id) == nil {
            residency.addAllocation(allocation)
            residencyChanged = true
        }
    }

    /// The scene has been replaced: what the frames from here on don't bind is let go of `sceneLife` frames from now,
    /// not `residencyLife` later. The set holds on to what is in it, and an open world's scenes follow each other every
    /// few seconds with a gigabyte and a half each (a flight across two tiles peaked at 15 GB, Metal 3's at 8).
    func noteSceneChange() { sceneChanged = frameCount }
    private var sceneChanged: UInt32?
    private static let sceneLife: UInt32 = 8

    /// Lets go of what no frame has bound for `residencyLife` frames (render targets of another size), or since
    /// frame `since`.
    private func releaseUnused(since: UInt32? = nil) {
        for (id, entry) in resident where since.map({ entry.used <= $0 }) ?? (frameCount &- entry.used > Metal4Frame.residencyLife) {
            residency.removeAllocation(entry.allocation)
            resident[id] = nil
            residencyChanged = true
        }
    }

    // MARK: - Command buffers and the encoder

    /// The command buffer pass `name` goes into: the frame's one, or with `split` a new one.
    private func buffer(_ name: String) -> MTL4CommandBuffer {
        if let cmd, !split { return cmd }
        endCompute()
        cmd?.endCommandBuffer()
        if cursor == pool[slot].count, let more = device.makeCommandBuffer() { pool[slot].append(more) }
        let next = pool[slot][min(cursor, pool[slot].count - 1)]
        cursor += 1
        next.beginCommandBuffer(allocator: allocators[slot])
        buffers.append(.metal4(name: name, cmd: next))
        cmd = next
        return next
    }

    /// A Metal 3 command buffer in the middle of the frame, for what has no working Metal 4 form: it runs after the
    /// frame's command buffers so far, and the ones after it wait for it.
    private func interlude(_ name: String, _ encode: (MTLCommandBuffer) -> Void) {
        endCompute()
        cmd?.endCommandBuffer()
        cmd = nil
        guard let cb = metal3Queue.makeCommandBuffer() else { return }
        cb.label = name
        eventValue += 2
        cb.encodeWaitForEvent(event, value: eventValue)
        encode(cb)
        cb.encodeSignalEvent(event, value: eventValue + 1)
        buffers.append(.metal3(name: name, cmd: cb, value: eventValue))
    }

    /// The open encoder, or a new one. A new one waits for everything committed before it: Metal 4 orders nothing itself.
    private func encoder(_ name: String, newBuffer: Bool = false) -> MTL4ComputeCommandEncoder? {
        if let enc, !(split && newBuffer) { return enc }
        guard let next = buffer(name).makeComputeCommandEncoder() else { return nil }
        next.barrier(afterQueueStages: Metal4Frame.queueStages, beforeStages: Metal4Frame.stages, visibilityOptions: .device)
        next.setArgumentTable(table)
        encoded = []
        enc = next
        return next
    }

    /// Ahead of work in `stage`: with `serial`, it waits for what the encoder holds so far.
    private func order(_ stage: MTLStages) {
        if serial && !encoded.isEmpty { barrier(before: stage) }
        encoded.insert(stage)
    }

    private func barrier(before stage: MTLStages = Metal4Frame.stages) {
        guard !encoded.isEmpty else { return }
        enc?.barrier(afterEncoderStages: encoded, beforeEncoderStages: stage, visibilityOptions: .device)
        encoded = []
    }

    // MARK: - FrameEncoder

    func compute(_ name: String, serial: Bool) -> ComputePass? {
        let wasSerial = self.serial
        guard encoder(name, newBuffer: true) != nil else { return nil }
        self.serial = serial || !overlap
        if wasSerial != self.serial { barrier() }
        return self
    }

    func endCompute() {
        guard let enc else { return }
        enc.endEncoding()
        self.enc = nil
    }

    /// Through the Metal 3 queue: on macOS 26.5 Metal 4's `generateMipmaps` keeps one texel of each 2x2 (or 2x2x2)
    /// instead of their mean, for every texture type and format tried (a ramp of 0...1 ends in a 1x1 level of 0.98, not
    /// 0.49). The sky's mips are its means (they light the scene), so the frames differed from Metal 3's.
    func generateMipmaps(_ textures: [MTLTexture], pass: String) {
        interlude(pass) { cb in
            guard let blit = cb.makeBlitCommandEncoder() else { return }
            for texture in textures { blit.generateMipmaps(for: texture) }
            blit.endEncoding()
        }
    }

    /// A render encoder of its own, which waits for everything before it as a new compute encoder does; the bindings
    /// go through the same argument table, to the vertex stage.
    func render(_ name: String, _ attachments: RenderAttachments, encode: (RenderPass) -> Void) {
        endCompute()
        let d = MTL4RenderPassDescriptor()
        attachments.apply(color: d.colorAttachments[0], depth: d.depthAttachment)
        d.renderTargetArrayLength = attachments.layers
        if let color = attachments.color { keep(color) }
        keep(attachments.depth)
        guard let enc = buffer(name).makeRenderCommandEncoder(descriptor: d) else { return }
        enc.label = name
        enc.barrier(afterQueueStages: Metal4Frame.queueStages, beforeStages: [.vertex, .fragment], visibilityOptions: .device)
        enc.setArgumentTable(table, stages: [.vertex, .mesh])
        encode(RenderPass4(frame: self, enc: enc))
        enc.endEncoding()
    }

    private struct RenderPass4: RenderPass {
        unowned let frame: Metal4Frame
        let enc: MTL4RenderCommandEncoder

        func setRenderPipelineState(_ state: MTLRenderPipelineState) { enc.setRenderPipelineState(state) }
        func setDepthStencilState(_ state: MTLDepthStencilState) { enc.setDepthStencilState(state) }
        func clampDepth() { enc.setDepthClipMode(.clamp) }
        func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { frame.setBytes(bytes, length: length, index: index) }
        func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { frame.setBuffer(buffer, offset: offset, index: index) }
        func useResources(_ resources: [MTLResource]) { frame.useResources(resources, usage: .read) }
        func drawTriangles(indirectBuffer: MTLBuffer, indirectBufferOffset: Int) {
            frame.keep(indirectBuffer)
            enc.drawPrimitives(primitiveType: .triangle, indirectBuffer: indirectBuffer.gpuAddress + UInt64(indirectBufferOffset))
        }
        // (One argument table serves the vertex and the mesh stage.)
        func setMeshBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { frame.setBytes(bytes, length: length, index: index) }
        func setMeshBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { frame.setBuffer(buffer, offset: offset, index: index) }
        func drawMeshThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threads: Int) {
            frame.keep(indirectBuffer)
            enc.drawMeshThreadgroups(indirectBuffer: indirectBuffer.gpuAddress + UInt64(indirectBufferOffset),
                                     threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerMeshThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
        }
    }

    func updateTLAS(_ u: TLASUpdate, pass: String) {
        guard let enc = encoder(pass, newBuffer: true) else { return }
        serial = true
        ([u.structure, u.scratch, u.instances] as [MTLAllocation]).forEach(keep)
        u.primitives.forEach(keep)
        let d = u.descriptor4
        let scratch = MTL4BufferRange(bufferAddress: u.scratch.gpuAddress, length: UInt64(u.scratch.length))
        order(.accelerationStructure)
        if u.refit {
            enc.refit(sourceAccelerationStructure: u.structure, descriptor: d, destinationAccelerationStructure: u.structure,
                      scratchBuffer: scratch)
        } else {
            enc.build(destinationAccelerationStructure: u.structure, descriptor: d, scratchBuffer: scratch)
        }
    }

    /// Through the Metal 3 queue: the per-mesh structures are built there (once per scene), and the ones that deform
    /// are refitted where they were built.
    func refitPrimitives(_ refit: PrimitiveRefit, pass: String) {
        interlude(pass) { cb in
            guard let enc = cb.makeAccelerationStructureCommandEncoder() else { return }
            refit.encode(into: enc)
            enc.endEncoding()
        }
    }

    /// The mapping updates go to the queue, between the command buffers so far and the ones after them (whose encoders
    /// wait for them, `queueStages`); the uploads into the new tiles follow in a command buffer of their own.
    func streamTextures(_ streamer: TextureStreamer, frame: UInt32, slot: Int, framesInFlight: Int) {
        let work = streamer.update(frame: frame, slot: slot, framesInFlight: framesInFlight)
        if !work.mappings.isEmpty {
            endCompute()
            cmd?.endCommandBuffer()
            cmd = nil
            buffers.append(.mappings(heap: streamer.heap, work.mappings.map { m in
                (m.texture, m.ops.map { op in
                    MTL4UpdateSparseTextureMappingOperation(mode: op.mode, textureRegion: op.region, textureLevel: op.level,
                                                            textureSlice: 0, heapOffset: op.heapOffset)
                })
            }))
        }
        guard !work.uploads.isEmpty, let enc = encoder("textures", newBuffer: true) else { return }
        serial = true
        order(.blit)
        for u in work.uploads {
            keep(u.source)
            keep(u.texture)
            enc.copy(sourceBuffer: u.source, sourceOffset: u.offset, sourceBytesPerRow: u.bytesPerRow, sourceBytesPerImage: u.bytesPerImage,
                     sourceSize: u.size, destinationTexture: u.texture, destinationSlice: 0, destinationLevel: u.level,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
    }

    /// Always the Metal 3 scaler, between two of the frame's command buffers (see Upscaler.init).
    func upscale(_ upscaler: Upscaler, _ inputs: UpscaleInputs, pass: String) {
        interlude(pass) { upscaler.encode(into: $0, inputs) }
    }

    func capture(_ texture: MTLTexture, into buffer: MTLBuffer) {
        guard let enc = encoder("capture", newBuffer: true) else { return }
        keep(texture)
        keep(buffer)
        let w = texture.width, h = texture.height
        order(.blit)
        enc.copy(sourceTexture: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                 sourceSize: MTLSize(width: w, height: h, depth: 1), destinationBuffer: buffer, destinationOffset: 0,
                 destinationBytesPerRow: w * 4, destinationBytesPerImage: w * 4 * h)
    }

    func commit(presenting drawable: CAMetalDrawable?, wait: Bool, completed: @escaping (FrameTimes) -> Void) {
        endCompute()
        cmd?.endCommandBuffer()
        cmd = nil
        if residencyChanged {
            residency.commit()
            residencyChanged = false
        }
        let done = wait ? DispatchSemaphore(value: 0) : nil
        let split = split
        let commandBuffers = buffers.filter { if case .mappings = $0 { return false } else { return true } }.count
        let collector = FeedbackCollector(count: commandBuffers) { times in
            completed(times)
            done?.signal()
        }
        if let drawable { queue.waitForDrawable(drawable) }
        for buffer in buffers {
            switch buffer {
            case .metal4(let name, let cb):
                let options = MTL4CommitOptions()
                options.addFeedbackHandler { feedback in
                    if let error = feedback.error { print("Metal 4 command buffer \(name) failed: \(error)") }
                    collector.add(name: split && name != "capture" ? name : nil, start: feedback.gpuStartTime, end: feedback.gpuEndTime)
                }
                queue.commit([cb], options: options)
            case .metal3(let name, let cb, let value):
                queue.signalEvent(event, value: value)         // once what was committed so far is done
                cb.addCompletedHandler { cb in
                    collector.add(name: split ? name : nil, start: cb.gpuStartTime, end: cb.gpuEndTime)
                }
                cb.commit()
                queue.waitForEvent(event, value: value + 1)    // what follows runs after it
            case .mappings(let heap, let textures):
                for (texture, ops) in textures { queue.updateMappings(texture: texture, heap: heap, operations: ops) }
            }
        }
        if commandBuffers == 0 { collector.finish() }
        if let drawable {
            queue.signalDrawable(drawable)
            drawable.present()
        }
        done?.wait()
    }

    /// Gathers the feedback of a frame's command buffers (they come on Metal's queue, one at a time or not).
    private final class FeedbackCollector {
        private let lock = NSLock()
        private var left: Int
        private var times = FrameTimes(start: .infinity, end: 0)
        private let completed: (FrameTimes) -> Void

        init(count: Int, completed: @escaping (FrameTimes) -> Void) {
            left = count
            self.completed = completed
        }

        func add(name: String?, start: CFTimeInterval, end: CFTimeInterval) {
            lock.lock()
            times.start = min(times.start, start)
            times.end = max(times.end, end)
            if let name { times.passes.append((name, start, end)) }
            left -= 1
            let last = left == 0
            lock.unlock()
            if last { finish() }
        }

        func finish() {
            if times.start == .infinity { times.start = 0 }
            completed(times)
        }
    }

    // MARK: - ComputePass

    func setComputePipelineState(_ state: MTLComputePipelineState) { enc?.setComputePipelineState(state) }

    /// Metal 4 has no inline constants: they go into the slot's constants buffer, and their address into the table.
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        let buffer = constants[slot]
        let offset = (constantsCursor + 15) & ~15
        precondition(offset + length <= buffer.length, "the frame's constants outgrew their buffer")
        buffer.contents().advanced(by: offset).copyMemory(from: bytes, byteCount: length)
        constantsCursor = offset + length
        table.setAddress(buffer.gpuAddress + UInt64(offset), index: index)
    }

    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) {
        guard let buffer else { return }
        keep(buffer)
        table.setAddress(buffer.gpuAddress + UInt64(offset), index: index)
    }

    func setTexture(_ texture: MTLTexture?, index: Int) {
        guard let texture else { return }
        keep(texture)
        table.setTexture(texture.gpuResourceID, index: index)
    }

    func setTextures(_ textures: [MTLTexture?], range: Range<Int>) {
        for (texture, index) in zip(textures, range) { setTexture(texture, index: index) }
    }

    func setAccelerationStructure(_ accelerationStructure: MTLAccelerationStructure?, bufferIndex: Int) {
        guard let accelerationStructure else { return }
        keep(accelerationStructure)
        table.setResource(accelerationStructure.gpuResourceID, bufferIndex: bufferIndex)
    }

    // What Metal 3 is told a kernel reaches through an argument buffer: here it only has to be resident, which one
    // declaration a frame keeps it (`keep` notes the frame it was last used in).
    var declarationScope: AnyObject { self }
    func useResource(_ resource: MTLResource, usage: MTLResourceUsage) { keep(resource) }
    func useResources(_ resources: [MTLResource], usage: MTLResourceUsage) { resources.forEach(keep) }
    func useHeap(_ heap: MTLHeap) { keep(heap) }

    /// Stages that overlap (`overlap`) set their own barriers, as on Metal 3's concurrent encoder.
    func memoryBarrier(scope: MTLBarrierScope) { barrier() }

    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        order(.dispatch)
        enc?.dispatchThreads(threadsPerGrid: threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        order(.dispatch)
        enc?.dispatchThreadgroups(threadgroupsPerGrid: threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    func dispatchThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threadsPerThreadgroup: MTLSize) {
        keep(indirectBuffer)
        order(.dispatch)
        enc?.dispatchThreadgroups(indirectBuffer: indirectBuffer.gpuAddress + UInt64(indirectBufferOffset),
                                  threadsPerThreadgroup: threadsPerThreadgroup)
    }
}

@available(macOS 26.0, *)
extension TLASUpdate {
    /// Metal 4's descriptor for it. Its instance descriptors are the indirect ones (`indirect`).
    var descriptor4: MTL4InstanceAccelerationStructureDescriptor {
        let d = MTL4InstanceAccelerationStructureDescriptor()
        d.instanceDescriptorBuffer = MTL4BufferRange(bufferAddress: instances.gpuAddress, length: UInt64(instances.length))
        d.instanceDescriptorStride = instanceStride
        d.instanceCount = instanceCount
        d.instanceDescriptorType = .indirect
        d.usage = usage
        return d
    }
}
