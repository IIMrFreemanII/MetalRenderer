import Metal
import simd

/// A scene's particle effects on the GPU (Shaders/Particles.metal): the pool, its dead and alive lists, the events
/// children spawn from, and the steps (`encodeSteps`). Written once but for the counters the kernels keep and each
/// step's parameters, which the CPU writes per frame slot (a replay can take hundreds of steps in one frame: more
/// than Metal 4's inline constants hold).
final class ParticlesGPU {
    let system: ParticleSystem
    let emitters: MTLBuffer
    let colliders: MTLBuffer
    let particles: MTLBuffer
    let deadList: MTLBuffer
    let alive: [MTLBuffer]
    let events: [MTLBuffer]
    /// ParticleCounts (Shaders/Particles.metal).
    let counts: MTLBuffer
    /// The indirect arguments `begin` writes: emit's threadgroups at 0, simulate's at 16.
    let args: MTLBuffer
    /// Per frame slot, its steps' parameters (GPUParticleStep each), and after them the reset's and the pose's (which
    /// read only the pool's size and the emitters'): written as the frame is encoded, read when it runs.
    private let stepParams: [MTLBuffer]
    private static let extraParams = ParticlesGPU.maxStepsPerFrame * MemoryLayout<GPUParticleStep>.stride
    /// Per frame slot, what its rays meet: a record a pool slot (GPUParticleRender), their boxes
    /// (MTLAxisAlignedBoundingBox), and the structures over them, built every frame (`build`): the shadow casters'
    /// (the pool's first ParticleSystem.casterCapacity slots), which shadow rays look through, and the others'.
    let render: [MTLBuffer]
    let boxes: [MTLBuffer]
    let parts: [(casters: Part?, others: Part?)]
    private let scratch: MTLBuffer

    /// A structure over the boxes of slots first..<first + count (none for an empty range).
    struct Part {
        let structure: MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let first: Int
        let count: Int
        let scratchOffset: Int
    }
    /// The flipbooks (ParticleTextures).
    let atlas: MTLTexture
    /// Per pool slot the light its particle scatters, averaged over the frames, and whose it is (particleLightKernel).
    let lighting: MTLBuffer

    static let countsSize = 1040
    /// Steps one frame encodes at most (a replay to a still's time catches up over the next frames): 10 s.
    static let maxStepsPerFrame = 600
    /// Offsets in `counts`, in uints (ParticleCounts).
    enum Counter {
        static let alive = 0, emits = 2, emitBase = 3, dead = 4, events = 36, emitted = 100
    }

    /// The steps encoded since the start (the GPU's clock, as the CPU counts it).
    private(set) var stepIndex = 0

    init(device: MTLDevice, system: ParticleSystem, slots: Int, atlas: MTLTexture? = nil) throws {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 256), options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            memset(b.contents(), 0, b.length)
            b.label = label
            return b
        }
        self.system = system
        let n = system.capacity
        let gpuEmitters = system.gpuEmitters, gpuColliders = system.gpuColliders
        let emitters = try buffer(gpuEmitters.count * MemoryLayout<GPUParticleEmitter>.stride, "particleEmitters")
        gpuEmitters.withUnsafeBytes { emitters.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let colliders = try buffer(gpuColliders.count * MemoryLayout<GPUParticleCollider>.stride, "particleColliders")
        gpuColliders.withUnsafeBytes { if !$0.isEmpty { colliders.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        (self.emitters, self.colliders) = (emitters, colliders)
        particles = try buffer(n * MemoryLayout<GPUParticle>.stride, "particles")
        deadList = try buffer(n * 4, "particleDead")
        alive = try (0..<2).map { try buffer(n * 4, "particleAlive\($0)") }
        events = try (0..<2).map { try buffer(n * MemoryLayout<ParticleEvent>.stride, "particleEvents\($0)") }
        counts = try buffer(ParticlesGPU.countsSize, "particleCounts")
        args = try buffer(32, "particleArgs")
        stepParams = try (0..<slots).map {
            try buffer((ParticlesGPU.maxStepsPerFrame + 1) * MemoryLayout<GPUParticleStep>.stride, "particleSteps\($0)")
        }
        // The structures: a box a pool slot (a dead one far away), no primitive data (its id is its slot, less the
        // part's first). Each part has a scratch range of its own, so the two builds may run side by side.
        var render: [MTLBuffer] = [], boxes: [MTLBuffer] = [], parts: [(casters: Part?, others: Part?)] = []
        var scratchBytes = 16
        for slot in 0..<slots {
            render.append(try buffer(n * MemoryLayout<GPUParticleRender>.stride, "particleRender\(slot)"))
            let b = try buffer(n * MemoryLayout<MTLAxisAlignedBoundingBox>.stride, "particleBoxes\(slot)")
            boxes.append(b)
            var offset = 0
            func part(_ first: Int, _ count: Int, _ label: String) throws -> Part? {
                guard count > 0 else { return nil }
                let stride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
                let geometry = MTLAccelerationStructureBoundingBoxGeometryDescriptor()
                geometry.boundingBoxBuffer = b
                geometry.boundingBoxBufferOffset = first * stride
                geometry.boundingBoxStride = stride
                geometry.boundingBoxCount = count
                geometry.opaque = false                                       // the loops get every box
                geometry.allowDuplicateIntersectionFunctionInvocation = false // ...once: a shadow multiplies each one in
                let d = MTLPrimitiveAccelerationStructureDescriptor()
                d.geometryDescriptors = [geometry]
                d.usage = .preferFastBuild
                let sizes = device.accelerationStructureSizes(descriptor: d)
                guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                    throw RendererError.resourceCreation("the particles' acceleration structure")
                }
                accel.label = "\(label)\(slot)"
                defer { offset += (sizes.buildScratchBufferSize + 255) & ~255 }
                return Part(structure: accel, descriptor: d, first: first, count: count, scratchOffset: offset)
            }
            parts.append((try part(0, system.casterCapacity, "particleCasters"),
                          try part(system.casterCapacity, n - system.casterCapacity, "particleOthers")))
            scratchBytes = max(scratchBytes, offset)
        }
        (self.render, self.boxes, self.parts) = (render, boxes, parts)
        scratch = try buffer(scratchBytes, "particlesScratch")
        lighting = try buffer(n * 16, "particleLighting")
        self.atlas = try atlas ?? ParticleTextures.atlas(device: device)
    }

    /// The kernels' buffers at 13 and up: the simulate pass has the scene at 1 to 12 (its collisions).
    private func bind(_ enc: ComputePass) {
        enc.setBuffer(emitters, offset: 0, index: 13)
        enc.setBuffer(counts, offset: 0, index: 14)
        enc.setBuffer(args, offset: 0, index: 15)
        enc.setBuffer(particles, offset: 0, index: 16)
        enc.setBuffer(deadList, offset: 0, index: 17)
        enc.setBuffer(alive[0], offset: 0, index: 18)
        enc.setBuffer(alive[1], offset: 0, index: 19)
        enc.setBuffer(events[0], offset: 0, index: 20)
        enc.setBuffer(events[1], offset: 0, index: 21)
        enc.setBuffer(colliders, offset: 0, index: 22)
    }

    /// Back to the start: every slot free, the clock at 0.
    func encodeReset(_ enc: ComputePass, pipelines: Pipelines, slot: Int) {
        let params = stepParams[slot]
        params.contents().storeBytes(of: system.stepParams(0), toByteOffset: ParticlesGPU.extraParams, as: GPUParticleStep.self)
        bind(enc)
        enc.setBuffer(params, offset: ParticlesGPU.extraParams, index: 0)
        let reset = pipelines[.particleReset]
        enc.setComputePipelineState(reset)
        enc.dispatchThreads(MTLSize(width: max(system.capacity, ParticleSystem.maxEmitters), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        stepIndex = 0
    }

    /// `steps` steps (at most maxStepsPerFrame), from where the last left off, in `wind` (WindFrame.wind). In a serial
    /// pass: each dispatch reads what the one before it wrote. `scene` binds the scene (Renderer.bindScene) for the
    /// emitters that collide with it; without it they don't.
    func encodeSteps(_ enc: ComputePass, pipelines: Pipelines, steps: Int, slot: Int, wind: SIMD4<Float> = .zero,
                     scene: ((ComputePass) -> Void)? = nil) {
        guard steps > 0 else { return }
        precondition(steps <= ParticlesGPU.maxStepsPerFrame, "more particle steps than a frame takes")
        let params = stepParams[slot]
        let p = params.contents().bindMemory(to: GPUParticleStep.self, capacity: ParticlesGPU.maxStepsPerFrame)
        for k in 0..<steps { p[k] = system.stepParams(stepIndex + k, wind: wind, scene: scene != nil) }
        scene?(enc)
        bind(enc)
        let begin = pipelines[.particleBegin], emit = pipelines[.particleEmit], simulate = pipelines[.particleSimulate]
        let group = MTLSize(width: 64, height: 1, depth: 1)
        for k in 0..<steps {
            enc.setBuffer(params, offset: k * MemoryLayout<GPUParticleStep>.stride, index: 0)
            enc.setComputePipelineState(begin)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            enc.setComputePipelineState(emit)
            enc.dispatchThreadgroups(indirectBuffer: args, indirectBufferOffset: 0, threadsPerThreadgroup: group)
            enc.setComputePipelineState(simulate)
            enc.dispatchThreadgroups(indirectBuffer: args, indirectBufferOffset: 16, threadsPerThreadgroup: group)
        }
        stepIndex += steps
    }

    // MARK: - What the rays meet

    /// `slot`'s records and boxes, from where the steps left the particles. After the steps (in the same serial pass).
    func encodePose(_ enc: ComputePass, pipelines: Pipelines, slot: Int) {
        // The pose reads the pool's size and emitter count (the reset's place: the steps' are this frame's).
        let params = stepParams[slot]
        params.contents().storeBytes(of: system.stepParams(stepIndex), toByteOffset: ParticlesGPU.extraParams, as: GPUParticleStep.self)
        enc.setBuffer(params, offset: ParticlesGPU.extraParams, index: 0)
        enc.setBuffer(emitters, offset: 0, index: 13)
        enc.setBuffer(particles, offset: 0, index: 16)
        enc.setBuffer(render[slot], offset: 0, index: 23)
        enc.setBuffer(boxes[slot], offset: 0, index: 24)
        let pose = pipelines[.particlePose]
        enc.setComputePipelineState(pose)
        enc.dispatchThreads(MTLSize(width: system.capacity, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }

    /// The builds of `slot`'s structures over the boxes `encodePose` wrote: after it, ahead of everything that traces.
    struct Build: PrimitiveWork4 {
        let parts: [Part]
        let boxes: MTLBuffer
        let scratch: MTLBuffer

        func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int) {
            for p in parts {
                enc.build(accelerationStructure: p.structure, descriptor: p.descriptor, scratchBuffer: scratch, scratchBufferOffset: p.scratchOffset)
            }
        }

        @available(macOS 26.0, *)
        func encode4(into enc: MTL4ComputeCommandEncoder, keep: (MTLAllocation) -> Void) {
            keep(boxes)
            keep(scratch)
            let stride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
            for (i, p) in parts.enumerated() {
                keep(p.structure)
                let g = MTL4AccelerationStructureBoundingBoxGeometryDescriptor()
                g.boundingBoxBuffer = MTL4BufferRange(bufferAddress: boxes.gpuAddress + UInt64(p.first * stride), length: UInt64(p.count * stride))
                g.boundingBoxStride = stride
                g.boundingBoxCount = p.count
                g.opaque = false
                g.allowDuplicateIntersectionFunctionInvocation = false
                let d = MTL4PrimitiveAccelerationStructureDescriptor()
                d.geometryDescriptors = [g]
                d.usage = p.descriptor.usage
                let end = i + 1 < parts.count ? parts[i + 1].scratchOffset : scratch.length
                enc.build(destinationAccelerationStructure: p.structure, descriptor: d,
                          scratchBuffer: MTL4BufferRange(bufferAddress: scratch.gpuAddress + UInt64(p.scratchOffset),
                                                         length: UInt64(end - p.scratchOffset)))
            }
        }
    }
    func build(slot: Int) -> Build {
        Build(parts: [parts[slot].casters, parts[slot].others].compactMap { $0 }, boxes: boxes[slot], scratch: scratch)
    }

    /// What `slot`'s ray queries read through TraceScene.
    func resources(slot: Int) -> [MTLResource] {
        [parts[slot].casters?.structure, parts[slot].others?.structure].compactMap { $0 } + [render[slot], atlas]
    }

    func readRender(slot: Int) -> [GPUParticleRender] {
        Array(UnsafeBufferPointer(start: render[slot].contents().bindMemory(to: GPUParticleRender.self, capacity: system.capacity),
                                  count: system.capacity))
    }

    // MARK: - Reading back (tests; the GPU idle)

    func readCounts() -> [UInt32] {
        let c = counts.contents().bindMemory(to: UInt32.self, capacity: ParticlesGPU.countsSize / 4)
        return (0..<ParticlesGPU.countsSize / 4).map { c[$0] }
    }

    /// The alive list the next step reads.
    func readAliveSlots() -> [UInt32] {
        let n = Int(readCounts()[Counter.alive + (stepIndex & 1)])
        let a = alive[stepIndex & 1].contents().bindMemory(to: UInt32.self, capacity: system.capacity)
        return (0..<n).map { a[$0] }
    }

    func readParticles() -> [GPUParticle] {
        Array(UnsafeBufferPointer(start: particles.contents().bindMemory(to: GPUParticle.self, capacity: system.capacity),
                                  count: system.capacity))
    }

    /// Emitter `e`'s dead list.
    func readDead(_ e: Int) -> [UInt32] {
        let n = Int(readCounts()[Counter.dead + e]), base = system.bases[e]
        let d = deadList.contents().bindMemory(to: UInt32.self, capacity: system.capacity)
        return (0..<n).map { d[base + $0] }
    }
}
