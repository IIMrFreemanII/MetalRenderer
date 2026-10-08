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
    /// Per frame slot, its steps' parameters (GPUParticleStep each), and after them the reset's and the pose's, each
    /// in a place of its own: written as the frame is encoded, read when it runs (one's in another's place would be
    /// read by both).
    private let stepParams: [MTLBuffer]
    private static let resetParams = ParticlesGPU.maxStepsPerFrame * MemoryLayout<GPUParticleStep>.stride
    private static let poseParams = resetParams + MemoryLayout<GPUParticleStep>.stride
    /// Per frame slot, what its rays meet: a record a pool slot (GPUParticleRender), their boxes
    /// (MTLAxisAlignedBoundingBox), and the structures over them, built every frame (`build`): the shadow casters'
    /// (the pool's first ParticleSystem.casterCapacity slots), which shadow rays look through, and the others'.
    let render: [MTLBuffer]
    let boxes: [MTLBuffer]
    let parts: [(casters: Part?, others: Part?)]
    /// Per frame slot, the boxes its structures were last built over (the casters', the others'): the CPU's bound on
    /// the alive particles then (ParticleSystem.partBounds), which the pose packs them into.
    private(set) var posed: [SIMD2<Int>]
    private var poseParity: UInt32 = 0
    private let scratch: MTLBuffer

    /// A structure over the boxes of slots first..<first + count (none for an empty range).
    struct Part {
        let structure: MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let first: Int
        let count: Int
        let scratchOffset: Int
    }
    /// The trails (ParticleEmitter.trail): their places, a ring each (the steps write them), and per frame slot their
    /// control points (xyz, the trail's radius), the structure's radii (widened for the camera), their records
    /// (MSL ParticleTrail) and the structure over their ribbons (flat curves); the segments' first points (fixed).
    let trailHistory: MTLBuffer
    let trailPoints: [MTLBuffer]
    let trailRadii: [MTLBuffer]
    let trailRecords: [MTLBuffer]
    let trails: [Trails?]
    private let trailIndices: MTLBuffer
    static let trailRecordSize = 32

    /// A frame slot's trails' structure.
    struct Trails {
        let structure: MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let scratchOffset: Int
    }
    /// The vector fields' table and nodes (ParticleSystem.gpuFields); the scene's SDF shapes (SDFBuffers.scene) for
    /// the colliders that are their instances (bound with the scene; a placeholder until the renderer sets it).
    let fields: MTLBuffer
    let fieldSamples: MTLBuffer
    var sdfScene: MTLBuffer?
    /// The flipbooks (ParticleTextures).
    let atlas: MTLTexture
    /// Per pool slot the light its particle scatters, averaged over the frames, and whose it is (particleLightKernel).
    let lighting: MTLBuffer

    static let countsSize = 1056
    /// MSL PARTICLE_WIDEN.
    static let widen: Float = 0.5
    /// Steps one frame encodes at most (a replay to a still's time catches up over the next frames): 10 s.
    static let maxStepsPerFrame = 600
    /// Offsets in `counts`, in uints (ParticleCounts).
    enum Counter {
        static let alive = 0, emits = 2, emitBase = 3, dead = 4, events = 36, emitted = 100, posed = 260
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
        let f = system.gpuFields
        let fields = try buffer(f.table.count * MemoryLayout<GPUParticleField>.stride, "particleFields")
        f.table.withUnsafeBytes { if !$0.isEmpty { fields.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        let fieldSamples = try buffer(f.samples.count * 16, "particleFieldSamples")
        f.samples.withUnsafeBytes { if !$0.isEmpty { fieldSamples.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        (self.fields, self.fieldSamples) = (fields, fieldSamples)
        particles = try buffer(n * MemoryLayout<GPUParticle>.stride, "particles")
        deadList = try buffer(n * 4, "particleDead")
        alive = try (0..<2).map { try buffer(n * 4, "particleAlive\($0)") }
        events = try (0..<2).map { try buffer(n * MemoryLayout<ParticleEvent>.stride, "particleEvents\($0)") }
        counts = try buffer(ParticlesGPU.countsSize, "particleCounts")
        args = try buffer(32, "particleArgs")
        stepParams = try (0..<slots).map {
            try buffer((ParticlesGPU.maxStepsPerFrame + 2) * MemoryLayout<GPUParticleStep>.stride, "particleSteps\($0)")
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
                          try part(system.casterCapacity, system.billboardCapacity - system.casterCapacity, "particleOthers")))
            scratchBytes = max(scratchBytes, offset)
        }
        (self.render, self.boxes, self.parts) = (render, boxes, parts)
        // The trails: a curve of control points (its places and the head) each, its segments four points a point
        // apart; the structure rebuilt every frame (`build`), with a scratch range after the boxes'.
        let t = system.trailCount, m = system.trailControlPoints, segments = t * system.trailSegments
        trailHistory = try buffer(t * system.trailPoints * 16, "particleTrailHistory")
        trailPoints = try (0..<slots).map { try buffer(t * m * 16, "particleTrailPoints\($0)") }
        trailRadii = try (0..<slots).map { try buffer(t * m * 4, "particleTrailRadii\($0)") }
        trailRecords = try (0..<slots).map { try buffer(t * ParticlesGPU.trailRecordSize, "particleTrails\($0)") }
        trailIndices = try buffer(segments * 4, "particleTrailSegments")
        let first = trailIndices.contents().bindMemory(to: UInt32.self, capacity: max(segments, 1))
        for trail in 0..<t { for k in 0..<system.trailSegments { first[trail * system.trailSegments + k] = UInt32(trail * m + k) } }
        var trails: [Trails?] = []
        for slot in 0..<slots {
            guard segments > 0, #available(macOS 14.0, *) else { trails.append(nil); continue }
            let g = MTLAccelerationStructureCurveGeometryDescriptor()
            g.controlPointBuffer = trailPoints[slot]
            g.controlPointCount = t * m
            g.controlPointStride = 16
            g.controlPointFormat = .float3
            g.radiusBuffer = trailRadii[slot]
            g.radiusStride = 4
            g.radiusFormat = .float
            g.indexBuffer = trailIndices
            g.indexType = .uint32
            g.segmentCount = segments
            g.segmentControlPointCount = 4
            g.curveType = .flat
            g.curveBasis = .catmullRom
            g.curveEndCaps = .none
            g.opaque = false                                       // the loops get every one
            g.allowDuplicateIntersectionFunctionInvocation = false
            let d = MTLPrimitiveAccelerationStructureDescriptor()
            d.geometryDescriptors = [g]
            d.usage = .preferFastBuild
            let sizes = device.accelerationStructureSizes(descriptor: d)
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                throw RendererError.resourceCreation("the particles' trails' acceleration structure")
            }
            accel.label = "particleTrails\(slot)"
            trails.append(Trails(structure: accel, descriptor: d, scratchOffset: scratchBytes))
            scratchBytes += (sizes.buildScratchBufferSize + 255) & ~255
        }
        self.trails = trails
        posed = Array(repeating: .zero, count: slots)
        scratch = try buffer(scratchBytes, "particlesScratch")
        lighting = try buffer(n * 48, "particleLighting")
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
        enc.setBuffer(trailHistory, offset: 0, index: 23)
        enc.setBuffer(fields, offset: 0, index: 24)
        enc.setBuffer(fieldSamples, offset: 0, index: 25)
        enc.setBuffer(sdfScene ?? fields, offset: 0, index: 26)
    }

    /// Back to the start: every slot free, the clock at 0.
    func encodeReset(_ enc: ComputePass, pipelines: Pipelines, slot: Int) {
        let params = stepParams[slot]
        params.contents().storeBytes(of: system.stepParams(0), toByteOffset: ParticlesGPU.resetParams, as: GPUParticleStep.self)
        bind(enc)
        enc.setBuffer(params, offset: ParticlesGPU.resetParams, index: 0)
        let reset = pipelines[.particleReset]
        enc.setComputePipelineState(reset)
        enc.dispatchThreads(MTLSize(width: max(system.capacity, ParticleSystem.maxEmitters), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        stepIndex = 0
        meshPosedAt = 0
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

    /// `slot`'s records and boxes, from where the steps left the particles: the alive ones packed at the front of
    /// their structure's range, as many as the CPU's bound at most, then the rest emptied. After the steps (in the
    /// same serial pass).
    /// `camera`: where the camera is, and its layer's texel a unit away (radians): the boxes hold the billboards as
    /// its rays widen them (PARTICLE_WIDEN in Shaders/Particles.metal).
    func encodePose(_ enc: ComputePass, pipelines: Pipelines, slot: Int, camera: SIMD4<Float> = .zero) {
        // The pose's parameters have a place of their own (the steps' and the reset's are this frame's too).
        let bounds = system.partBounds(after: stepIndex)
        posed[slot] = bounds
        var p = system.stepParams(stepIndex)
        p.capacity = UInt32(system.billboardCapacity)   // the meshes' slots aren't boxes
        p.casters = UInt32(system.casterCapacity)
        p.casterBound = UInt32(bounds.x)
        p.othersBound = UInt32(bounds.y)
        p.pose = poseParity
        p.wind = SIMD4(camera.x, camera.y, camera.z, camera.w * ParticlesGPU.widen * 1.1)
        poseParity ^= 1
        let params = stepParams[slot]
        params.contents().storeBytes(of: p, toByteOffset: ParticlesGPU.poseParams, as: GPUParticleStep.self)
        enc.setBuffer(params, offset: ParticlesGPU.poseParams, index: 0)
        enc.setBuffer(emitters, offset: 0, index: 13)
        enc.setBuffer(counts, offset: 0, index: 14)
        enc.setBuffer(particles, offset: 0, index: 16)
        enc.setBuffer(render[slot], offset: 0, index: 23)
        enc.setBuffer(boxes[slot], offset: 0, index: 24)
        let grid = MTLSize(width: max(system.billboardCapacity, 1), height: 1, depth: 1), group = MTLSize(width: 64, height: 1, depth: 1)
        enc.setComputePipelineState(pipelines[.particlePose])
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.setComputePipelineState(pipelines[.particlePoseTail])
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        guard system.trailCount > 0 else { return }
        struct TrailPose { var camera: SIMD4<Float>; var trails, points, step, emitters: UInt32 }
        var t = TrailPose(camera: p.wind, trails: UInt32(system.trailCount), points: UInt32(system.trailPoints), step: UInt32(stepIndex),
                          emitters: UInt32(system.emitters.count))
        enc.setBytes(&t, length: MemoryLayout<TrailPose>.stride, index: 0)
        enc.setBuffer(trailHistory, offset: 0, index: 17)
        enc.setBuffer(lighting, offset: 0, index: 18)
        enc.setBuffer(trailPoints[slot], offset: 0, index: 19)
        enc.setBuffer(trailRadii[slot], offset: 0, index: 20)
        enc.setBuffer(trailRecords[slot], offset: 0, index: 21)
        enc.setComputePipelineState(pipelines[.particleTrailPose])
        enc.dispatchThreads(MTLSize(width: system.trailCount * system.trailControlPoints, height: 1, depth: 1), threadsPerThreadgroup: group)
    }

    /// The mesh particles' instance records (and descriptors, `descriptorStride` > 0) in a frame slot's buffers, every
    /// frame (the CPU writes them too, as it does every moving instance): ahead of the top-level structure's update.
    /// From the pool as the last frame's steps left it.
    func encodeMeshPose(_ enc: ComputePass, pipelines: Pipelines, instances: MTLBuffer, descriptors: MTLBuffer?, descriptorStride: Int) {
        guard system.meshCapacity > 0 else { return }
        struct Params { var range: SIMD4<UInt32>; var lag: SIMD4<Float> }
        let lag = Float(max(stepIndex - meshPosedAt, 0)) * ParticleSystem.stepLength
        meshPosedAt = stepIndex
        var p = Params(range: SIMD4(UInt32(system.billboardCapacity), UInt32(system.meshCapacity),
                                    descriptors == nil ? 0 : UInt32(descriptorStride), UInt32(system.emitters.count)),
                       lag: SIMD4(lag, 0, 0, 0))
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.setBuffer(emitters, offset: 0, index: 13)
        enc.setBuffer(particles, offset: 0, index: 16)
        enc.setBuffer(instances, offset: 0, index: 25)
        enc.setBuffer(descriptors ?? instances, offset: 0, index: 26)
        enc.setComputePipelineState(pipelines[.particleMeshPose])
        enc.dispatchThreads(MTLSize(width: system.meshCapacity, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }
    private var meshPosedAt = 0

    /// The builds of `slot`'s structures over the boxes `encodePose` wrote: after it, ahead of everything that traces.
    /// Each over its posed boxes only (`counts`), from `firsts` (the others' start at the casters' bound).
    struct Build: PrimitiveWork4 {
        let parts: [Part]
        let firsts: [Int]
        let counts: [Int]
        let boxes: MTLBuffer
        let scratch: MTLBuffer
        /// The trails' structure, over its control points and radii, and the segments' first points.
        var trails: (Trails, points: MTLBuffer, radii: MTLBuffer, indices: MTLBuffer)?

        func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int) {
            let stride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
            for (i, p) in parts.enumerated() {
                // The descriptor is copied as the build is encoded: this frame's range, then the next frame's.
                let g = p.descriptor.geometryDescriptors![0] as! MTLAccelerationStructureBoundingBoxGeometryDescriptor
                g.boundingBoxBufferOffset = firsts[i] * stride
                g.boundingBoxCount = counts[i]
                enc.build(accelerationStructure: p.structure, descriptor: p.descriptor, scratchBuffer: scratch, scratchBufferOffset: p.scratchOffset)
            }
            if let (t, _, _, _) = trails {
                enc.build(accelerationStructure: t.structure, descriptor: t.descriptor, scratchBuffer: scratch, scratchBufferOffset: t.scratchOffset)
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
                g.boundingBoxBuffer = MTL4BufferRange(bufferAddress: boxes.gpuAddress + UInt64(firsts[i] * stride),
                                                      length: UInt64(counts[i] * stride))
                g.boundingBoxStride = stride
                g.boundingBoxCount = counts[i]
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
            if let (t, points, radii, indices) = trails,
               let g3 = t.descriptor.geometryDescriptors?.first as? MTLAccelerationStructureCurveGeometryDescriptor {
                [points, radii, indices, t.structure].forEach(keep)
                let g = MTL4AccelerationStructureCurveGeometryDescriptor()
                g.controlPointBuffer = MTL4BufferRange(bufferAddress: points.gpuAddress, length: UInt64(points.length))
                g.controlPointCount = g3.controlPointCount
                g.controlPointStride = g3.controlPointStride
                g.controlPointFormat = g3.controlPointFormat
                g.radiusBuffer = MTL4BufferRange(bufferAddress: radii.gpuAddress, length: UInt64(radii.length))
                g.radiusStride = g3.radiusStride
                g.radiusFormat = g3.radiusFormat
                g.indexBuffer = MTL4BufferRange(bufferAddress: indices.gpuAddress, length: UInt64(indices.length))
                g.indexType = g3.indexType
                g.segmentCount = g3.segmentCount
                g.segmentControlPointCount = g3.segmentControlPointCount
                g.curveType = g3.curveType
                g.curveBasis = g3.curveBasis
                g.curveEndCaps = g3.curveEndCaps
                g.opaque = false
                g.allowDuplicateIntersectionFunctionInvocation = false
                let d = MTL4PrimitiveAccelerationStructureDescriptor()
                d.geometryDescriptors = [g]
                d.usage = t.descriptor.usage
                enc.build(destinationAccelerationStructure: t.structure, descriptor: d,
                          scratchBuffer: MTL4BufferRange(bufferAddress: scratch.gpuAddress + UInt64(t.scratchOffset),
                                                         length: UInt64(scratch.length - t.scratchOffset)))
            }
        }
    }
    /// Nil if nothing can be alive (nothing to build; the rays skip empty structures: TraceScene's counts).
    func build(slot: Int) -> Build? {
        let b = posed[slot]
        var ps: [Part] = [], firsts: [Int] = [], counts: [Int] = []
        if let c = parts[slot].casters, b.x > 0 { ps.append(c); firsts.append(0); counts.append(b.x) }
        if let o = parts[slot].others, b.y > 0 { ps.append(o); firsts.append(b.x); counts.append(b.y) }
        var build = Build(parts: ps, firsts: firsts, counts: counts, boxes: boxes[slot], scratch: scratch)
        if let t = trails[slot] { build.trails = (t, trailPoints[slot], trailRadii[slot], trailIndices) }
        return ps.isEmpty && build.trails == nil ? nil : build
    }

    /// What the rays read of `slot`'s structures (TraceScene.particleCounts): the casters' boxes, the others' (0: not
    /// built, don't look); the others' records start at the first.
    func traceCounts(slot: Int) -> SIMD2<UInt32> { SIMD2(UInt32(posed[slot].x), UInt32(posed[slot].y)) }

    /// What `slot`'s ray queries read through TraceScene.
    func resources(slot: Int) -> [MTLResource] {
        [parts[slot].casters?.structure, parts[slot].others?.structure, trails[slot]?.structure].compactMap { $0 }
            + [render[slot], atlas, trailPoints[slot], trailRecords[slot]]
    }

    /// TraceScene's trail shape: (trails, control points each), or none.
    var trailShape: SIMD2<UInt32> {
        trails.allSatisfy { $0 == nil } ? .zero : SIMD2(UInt32(system.trailCount), UInt32(system.trailControlPoints))
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
