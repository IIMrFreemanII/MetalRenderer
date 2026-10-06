import Metal
import simd

/// The physics on the GPU (Shaders/Physics.metal): the world's state in buffers, its steps encoded into the frame's
/// "physics" pass ahead of the acceleration structures, then a pose kernel that writes every body's instance record
/// (and Metal's instance descriptor) for the frame. The CPU's copy of the poses comes from a per-slot snapshot that the
/// pose kernel writes and the CPU reads once the slot's frame is done: three frames late, the same three every time.
///
/// Buffers are written once (the parameters too: a step sets no bytes, so a replay of hundreds of steps fits a
/// frame's constants on Metal 4). A substep reads the bodies from one buffer and writes the other twice, so the
/// state is in `bodies[0]` between substeps.
final class PhysicsGPU {
    /// MSL PhysicsPoseParams.
    struct PoseParams {
        var bodies: UInt32
        var descriptorStride: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }

    let world: PhysicsWorld
    private let params: MTLBuffer
    private let bodies: [MTLBuffer]
    private let initial: MTLBuffer
    private let statics: MTLBuffer
    private let staticBounds: MTLBuffer
    private let shapes: MTLBuffer
    private let samples: MTLBuffer
    private let heads: MTLBuffer
    private let next: MTLBuffer
    private let pairs: MTLBuffer
    private let pairCounts: MTLBuffer
    private let contacts: MTLBuffer
    private let wake: MTLBuffer
    private let lastPose: MTLBuffer
    private let substepCount: MTLBuffer
    /// The step's contacts (entry x 4 + slot), their count, and each one's push or kick (MSL PhysicsResult).
    private let list: MTLBuffer
    private let listed: MTLBuffer
    private let results: MTLBuffer
    private let snapshots: [MTLBuffer]
    /// The particles (twice: their solve reads one and writes the other), their start, their grid, their neighbours and
    /// colliders, and where each was last frame.
    private let particles: [MTLBuffer]
    private let initialParticles: MTLBuffer
    private let particleHeads: MTLBuffer
    private let particleNext: MTLBuffer
    private let neighbours: MTLBuffer
    private let neighbourCounts: MTLBuffer
    private let colliders: MTLBuffer
    private let colliderCounts: MTLBuffer
    private let lastParticle: MTLBuffer
    private let particleCount: Int
    /// The cloths' constraints by colour, and where each colour starts.
    private let constraints: MTLBuffer
    private let colourStarts: MTLBuffer
    /// The cloths' meshes (MSL PhysicsCloth), if there are any; and when the CPU steps them, the particles as it left
    /// them, a buffer per frame slot (`upload`).
    private let clothTable: MTLBuffer?
    private let uploads: [MTLBuffer]
    /// It steps the world; otherwise it only draws the CPU's cloths.
    let simulates: Bool
    var hasCloth: Bool { clothTable != nil }
    /// The scene's SDF shapes (SDFBuffers.scene) and what it points at, for the narrow phase.
    private let sdfScene: MTLBuffer
    private let sdfResources: [MTLBuffer]
    private let count: Int

    /// `simulates`: it steps the world; otherwise the CPU does and this only draws its cloths. `clothPrevOffsets`: per
    /// cloth, its mesh's last-frame offset (GPUMesh.prevOffset).
    init(device: MTLDevice, world: PhysicsWorld, sdfScene: MTLBuffer, sdfResources: [MTLBuffer], slots: Int, simulates: Bool = true,
         clothPrevOffsets: [UInt32] = []) throws {
        self.world = world
        self.simulates = simulates
        func buffer<T>(_ array: [T], _ label: String, length: Int? = nil) throws -> MTLBuffer {
            let size = max(length ?? array.count * MemoryLayout<T>.stride, 16)
            guard let b = device.makeBuffer(length: size, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            array.withUnsafeBytes { raw in if !raw.isEmpty { b.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) } }
            b.label = label
            return b
        }
        let n = world.bodies.count, k = PhysicsWorld.maxPairs
        count = n
        params = try buffer([world.params], "physicsParams")
        initial = try buffer(world.initialBodies, "physicsInitial")
        bodies = [try buffer(world.initialBodies, "physicsBodies0"), try buffer(world.initialBodies, "physicsBodies1")]
        statics = try buffer(world.statics, "physicsStatics")
        staticBounds = try buffer(world.staticBounds.flatMap { [SIMD4($0.lo, 0), SIMD4($0.hi, 0)] }, "physicsStaticBounds")
        shapes = try buffer(world.shapes, "physicsShapes")
        samples = try buffer(world.samples, "physicsSamples")
        heads = try buffer([UInt32](), "physicsHeads", length: world.buckets * 4)
        next = try buffer([UInt32](), "physicsNext", length: n * 4)
        pairs = try buffer([GPUPhysicsPair](), "physicsPairs", length: n * k * MemoryLayout<GPUPhysicsPair>.stride)
        pairCounts = try buffer([UInt32](repeating: 0, count: n), "physicsPairCounts")
        contacts = try buffer([GPUPhysicsContact](), "physicsContacts",
                              length: n * k * PhysicsWorld.maxContacts * MemoryLayout<GPUPhysicsContact>.stride)
        wake = try buffer([UInt32](repeating: 0, count: n), "physicsWake")
        let poses = world.initialBodies.flatMap { [SIMD4(PhysicsMath.xyz($0.position), 0), $0.rotation] }
        lastPose = try buffer(poses, "physicsLastPose")
        substepCount = try buffer([UInt32(world.substeps)], "physicsSubsteps")
        list = try buffer([UInt32](), "physicsList", length: n * k * PhysicsWorld.maxContacts * 4)
        listed = try buffer([UInt32(0)], "physicsListed")
        results = try buffer([UInt32](), "physicsResults", length: n * k * PhysicsWorld.maxContacts * 48)
        snapshots = try (0..<slots).map { try buffer(poses, "physicsSnapshot\($0)") }
        let np = world.particles.count
        particleCount = np
        particles = [try buffer(world.initialParticles, "physicsParticles0"), try buffer(world.initialParticles, "physicsParticles1")]
        initialParticles = try buffer(world.initialParticles, "physicsInitialParticles")
        particleHeads = try buffer([UInt32](), "physicsParticleHeads", length: world.particleBuckets * 4)
        particleNext = try buffer([UInt32](), "physicsParticleNext", length: np * 4)
        neighbours = try buffer([UInt32](), "physicsNeighbours", length: np * PhysicsWorld.maxNeighbours * 4)
        neighbourCounts = try buffer([UInt32](repeating: 0, count: np), "physicsNeighbourCounts")
        colliders = try buffer([UInt32](), "physicsColliders", length: np * PhysicsWorld.maxColliders * 4)
        colliderCounts = try buffer([UInt32](repeating: 0, count: np), "physicsColliderCounts")
        clothTable = world.cloths.isEmpty ? nil : try buffer(world.clothTable(prevOffsets: clothPrevOffsets), "physicsCloths")
        uploads = simulates || world.cloths.isEmpty ? [] : try (0..<slots).map { try buffer(world.initialParticles, "physicsUpload\($0)") }
        constraints = try buffer(world.constraints, "physicsConstraints")
        colourStarts = try buffer(world.colourStarts, "physicsColourStarts")
        lastParticle = try buffer(world.initialParticles.map { SIMD4(PhysicsMath.xyz($0.position), 0) }, "physicsLastParticle")
        self.sdfScene = sdfScene
        self.sdfResources = sdfResources
    }

    // MARK: - Encoding

    private func dispatch(_ enc: ComputePass, _ state: MTLComputePipelineState, _ threads: Int) {
        let width = min(state.threadExecutionWidth, max(threads, 1))
        enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Back to the start (a replay).
    private var empty: Bool { count + particleCount == 0 }

    func encodeReset(_ enc: ComputePass, pipelines: Pipelines) {
        guard !empty else { return }
        enc.setComputePipelineState(pipelines[.physicsReset])
        enc.setBuffer(params, offset: 0, index: 0)
        enc.setBuffer(initial, offset: 0, index: 1)
        enc.setBuffer(bodies[0], offset: 0, index: 2)
        enc.setBuffer(wake, offset: 0, index: 3)
        enc.setBuffer(lastPose, offset: 0, index: 4)
        enc.setBuffer(initialParticles, offset: 0, index: 5)
        enc.setBuffer(particles[0], offset: 0, index: 6)
        enc.setBuffer(lastParticle, offset: 0, index: 7)
        dispatch(enc, pipelines[.physicsReset], max(count, particleCount))
    }

    /// `steps` steps, in order, into a serial pass.
    func encodeSteps(_ enc: ComputePass, pipelines: Pipelines, steps: Int) {
        guard !empty, steps > 0 else { return }
        let k = PhysicsWorld.maxPairs
        enc.useResources(sdfResources, usage: .read)
        enc.setBuffer(params, offset: 0, index: 0)
        for _ in 0..<steps {
            enc.setComputePipelineState(pipelines[.physicsClear])
            enc.setBuffer(heads, offset: 0, index: 1)
            enc.setBuffer(listed, offset: 0, index: 2)
            enc.setBuffer(particleHeads, offset: 0, index: 3)
            dispatch(enc, pipelines[.physicsClear], max(world.buckets, world.particleBuckets))
            enc.setComputePipelineState(pipelines[.physicsInsert])
            enc.setBuffer(bodies[0], offset: 0, index: 1)
            enc.setBuffer(heads, offset: 0, index: 2)
            enc.setBuffer(next, offset: 0, index: 3)
            dispatch(enc, pipelines[.physicsInsert], count)
            enc.setComputePipelineState(pipelines[.physicsParticleInsert])
            enc.setBuffer(particles[0], offset: 0, index: 1)
            enc.setBuffer(particleHeads, offset: 0, index: 2)
            enc.setBuffer(particleNext, offset: 0, index: 3)
            dispatch(enc, pipelines[.physicsParticleInsert], particleCount)
            enc.setComputePipelineState(pipelines[.physicsPairs])
            enc.setBuffer(bodies[0], offset: 0, index: 1)
            enc.setBuffer(statics, offset: 0, index: 2)
            enc.setBuffer(staticBounds, offset: 0, index: 3)
            enc.setBuffer(shapes, offset: 0, index: 4)
            enc.setBuffer(heads, offset: 0, index: 5)
            enc.setBuffer(next, offset: 0, index: 6)
            enc.setBuffer(pairs, offset: 0, index: 7)
            enc.setBuffer(pairCounts, offset: 0, index: 8)
            dispatch(enc, pipelines[.physicsPairs], count)
            enc.setComputePipelineState(pipelines[.physicsLink])
            enc.setBuffer(bodies[0], offset: 0, index: 1)
            enc.setBuffer(pairs, offset: 0, index: 2)
            enc.setBuffer(pairCounts, offset: 0, index: 3)
            enc.setBuffer(wake, offset: 0, index: 4)
            dispatch(enc, pipelines[.physicsLink], count)
            enc.setComputePipelineState(pipelines[.physicsNarrow])
            enc.setBuffer(bodies[0], offset: 0, index: 1)
            enc.setBuffer(statics, offset: 0, index: 2)
            enc.setBuffer(shapes, offset: 0, index: 3)
            enc.setBuffer(samples, offset: 0, index: 4)
            enc.setBuffer(sdfScene, offset: 0, index: 5)
            enc.setBuffer(pairs, offset: 0, index: 6)
            enc.setBuffer(pairCounts, offset: 0, index: 7)
            enc.setBuffer(contacts, offset: 0, index: 8)
            enc.setBuffer(list, offset: 0, index: 9)
            enc.setBuffer(listed, offset: 0, index: 10)
            // A SIMD group per entry (its lanes share the samples).
            let narrow = pipelines[.physicsNarrow], simd = narrow.threadExecutionWidth
            if count > 0 {
                enc.dispatchThreads(MTLSize(width: count * k * simd, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(narrow.maxTotalThreadsPerThreadgroup / simd, 4) * simd, height: 1, depth: 1))
            }
            // The particles' neighbours and colliders (through the bodies' grid).
            enc.setComputePipelineState(pipelines[.physicsParticleNeighbours])
            enc.setBuffer(particles[0], offset: 0, index: 1)
            enc.setBuffer(particleHeads, offset: 0, index: 2)
            enc.setBuffer(particleNext, offset: 0, index: 3)
            enc.setBuffer(neighbours, offset: 0, index: 4)
            enc.setBuffer(neighbourCounts, offset: 0, index: 5)
            enc.setBuffer(bodies[0], offset: 0, index: 6)
            enc.setBuffer(statics, offset: 0, index: 7)
            enc.setBuffer(staticBounds, offset: 0, index: 8)
            enc.setBuffer(shapes, offset: 0, index: 9)
            enc.setBuffer(heads, offset: 0, index: 10)
            enc.setBuffer(next, offset: 0, index: 11)
            enc.setBuffer(colliders, offset: 0, index: 12)
            enc.setBuffer(colliderCounts, offset: 0, index: 13)
            dispatch(enc, pipelines[.physicsParticleNeighbours], particleCount)
            // Every substep in one threadgroup (Physics.metal's physicsSubstepsKernel).
            let substeps = pipelines[.physicsSubsteps]
            enc.setComputePipelineState(substeps)
            enc.setBuffer(bodies[0], offset: 0, index: 1)
            enc.setBuffer(bodies[1], offset: 0, index: 2)
            enc.setBuffer(statics, offset: 0, index: 3)
            enc.setBuffer(pairs, offset: 0, index: 4)
            enc.setBuffer(pairCounts, offset: 0, index: 5)
            enc.setBuffer(contacts, offset: 0, index: 6)
            enc.setBuffer(wake, offset: 0, index: 7)
            enc.setBuffer(substepCount, offset: 0, index: 8)
            enc.setBuffer(list, offset: 0, index: 9)
            enc.setBuffer(listed, offset: 0, index: 10)
            enc.setBuffer(results, offset: 0, index: 11)
            enc.setBuffer(particles[0], offset: 0, index: 12)
            enc.setBuffer(particles[1], offset: 0, index: 13)
            enc.setBuffer(neighbours, offset: 0, index: 14)
            enc.setBuffer(neighbourCounts, offset: 0, index: 15)
            enc.setBuffer(colliders, offset: 0, index: 16)
            enc.setBuffer(colliderCounts, offset: 0, index: 17)
            enc.setBuffer(shapes, offset: 0, index: 18)
            enc.setBuffer(samples, offset: 0, index: 19)
            enc.setBuffer(sdfScene, offset: 0, index: 20)
            enc.setBuffer(constraints, offset: 0, index: 21)
            enc.setBuffer(colourStarts, offset: 0, index: 22)
            let lanes = substeps.threadExecutionWidth
            let width = min(substeps.maxTotalThreadsPerThreadgroup / lanes * lanes, (max(count, particleCount) + lanes - 1) / lanes * lanes)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
    }

    /// The frame's instance records (and descriptors, `descriptorStride` > 0) from the bodies, and slot `slot`'s snapshot.
    func encodePose(_ enc: ComputePass, pipelines: Pipelines, slot: Int, instances: MTLBuffer, descriptors: MTLBuffer?,
                    descriptorStride: Int) {
        guard !empty else { return }
        var p = PoseParams(bodies: UInt32(count), descriptorStride: descriptors == nil ? 0 : UInt32(descriptorStride))
        enc.setComputePipelineState(pipelines[.physicsPose])
        enc.setBytes(&p, length: MemoryLayout<PoseParams>.stride, index: 0)
        enc.setBuffer(bodies[0], offset: 0, index: 1)
        enc.setBuffer(shapes, offset: 0, index: 2)
        enc.setBuffer(lastPose, offset: 0, index: 3)
        enc.setBuffer(snapshots[slot], offset: 0, index: 4)
        enc.setBuffer(instances, offset: 0, index: 5)
        enc.setBuffer(descriptors ?? instances, offset: 0, index: 6)
        dispatch(enc, pipelines[.physicsPose], count)
        guard particleCount > 0 else { return }
        var q = PoseParams(bodies: UInt32(particleCount), descriptorStride: p.descriptorStride)
        enc.setComputePipelineState(pipelines[.physicsParticlePose])
        enc.setBytes(&q, length: MemoryLayout<PoseParams>.stride, index: 0)
        enc.setBuffer(particles[0], offset: 0, index: 1)
        enc.setBuffer(lastParticle, offset: 0, index: 2)
        enc.setBuffer(instances, offset: 0, index: 3)
        enc.setBuffer(descriptors ?? instances, offset: 0, index: 4)
        dispatch(enc, pipelines[.physicsParticlePose], particleCount)
    }

    /// The CPU's particles for slot `slot`'s frame (when the CPU steps them): what the cloths are drawn from.
    func upload(slot: Int) {
        guard !uploads.isEmpty else { return }
        world.particles.withUnsafeBytes { uploads[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    /// The cloths' vertices (and last frame's) and normals into the scene's vertex buffers, ahead of the refits.
    func encodeClothMesh(_ enc: ComputePass, pipelines: Pipelines, slot: Int, positions: MTLBuffer, normals: MTLBuffer) {
        guard let clothTable else { return }
        var n = UInt32(particleCount)
        enc.setComputePipelineState(pipelines[.physicsClothMesh])
        enc.setBytes(&n, length: 4, index: 0)
        enc.setBuffer(simulates ? particles[0] : uploads[slot], offset: 0, index: 1)
        enc.setBuffer(clothTable, offset: 0, index: 2)
        enc.setBuffer(positions, offset: 0, index: 3)
        enc.setBuffer(normals, offset: 0, index: 4)
        dispatch(enc, pipelines[.physicsClothMesh], particleCount)
    }

    /// The particles as the GPU has them (tests).
    func readParticles() -> [GPUPhysicsParticle] {
        Array(UnsafeBufferPointer(start: particles[0].contents().bindMemory(to: GPUPhysicsParticle.self, capacity: particleCount),
                                  count: particleCount))
    }

    // MARK: - Reading back

    /// Slot `slot`'s poses (position, rotation per body), from when its frame was done.
    func snapshot(slot: Int) -> UnsafeBufferPointer<SIMD4<Float>> {
        UnsafeBufferPointer(start: snapshots[slot].contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * count), count: 2 * count)
    }

    /// The bodies as the GPU has them (the work that wrote them must be done): tests and the check.
    func readBodies() -> [GPUPhysicsBody] {
        Array(UnsafeBufferPointer(start: bodies[0].contents().bindMemory(to: GPUPhysicsBody.self, capacity: count), count: count))
    }
}
