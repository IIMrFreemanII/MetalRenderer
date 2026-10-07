import Metal
import simd

/// The physics on the GPU (Shaders/Physics.metal): the world's state in buffers, its steps encoded into the frame's
/// "physics" pass ahead of the acceleration structures, then a pose kernel that writes every body's instance record
/// (and Metal's instance descriptor) for the frame. The CPU's copy of the poses comes from a per-slot snapshot that the
/// pose kernel writes and the CPU reads once the slot's frame is done: three frames late, the same three every time.
///
/// Buffers are written once (the parameters too: a step sets no bytes, so a replay of hundreds of steps fits a
/// frame's constants on Metal 4). A step's substeps run in groups of `PhysicsWorld.contactRefresh`, the narrow phase
/// before each.
final class PhysicsGPU {
    /// MSL PhysicsGroup: a run of a step's substeps.
    struct Group {
        var first: UInt32
        var count: UInt32
        var last: UInt32
        var pad: UInt32 = 0
    }

    /// MSL PhysicsPoseParams.
    struct PoseParams {
        var bodies: UInt32
        var descriptorStride: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }

    let world: PhysicsWorld
    private let params: MTLBuffer
    private let bodies: MTLBuffer
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
    /// A step's runs of substeps (MSL PhysicsGroup), each bound at its offset; every body's pose at the step's start
    /// (what the settling measures it against); and the colouring's pairs in order, and its per-entry flags.
    private let groups: MTLBuffer
    private let groupCount: Int
    private let start: MTLBuffer
    private let order: MTLBuffer
    private let won: MTLBuffer
    private let live: MTLBuffer
    /// Where each colour starts, then the colours and how many pairs the rounds left.
    private let colouring: MTLBuffer
    private let snapshots: [MTLBuffer]
    /// Per frame slot, the body the mouse holds (MSL PhysicsGrab) as the CPU set it for that frame's steps.
    private let grabs: [MTLBuffer]
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
    /// The joints by colour, where each colour starts, and each ragdoll's bodies (first, count).
    private let joints: MTLBuffer
    private let jointStarts: MTLBuffer
    private let ragdolls: MTLBuffer
    /// The soft bodies' tets by colour, where each colour starts, their drawn vertices (MSL PhysicsSoftVertex), where
    /// each is in its tets, and the triangles around each.
    private let tets: MTLBuffer
    private let tetStarts: MTLBuffer
    private let softVertices: MTLBuffer
    private let softRings: MTLBuffer
    private let softEmbeds: MTLBuffer
    /// The cloths' meshes (MSL PhysicsCloth), if there are any; and when the CPU steps them, the particles as it left
    /// them, a buffer per frame slot (`upload`).
    private let clothTable: MTLBuffer?
    private let uploads: [MTLBuffer]
    /// The hair (PhysicsHair.swift): its strands, their vertices and their start, what its kernel is told, its groups
    /// of drawn strands (one MSL PhysicsHairGroup each, bound at its offset), its clock; and when the CPU steps it, its
    /// vertices and the bodies as the CPU left them, per frame slot (what the drawn strands are made from).
    private let hairStrands: MTLBuffer
    private let hairVertices: MTLBuffer
    private let initialHairVertices: MTLBuffer
    private let hairParams: MTLBuffer
    private let hairGroups: MTLBuffer
    private let hairClock: MTLBuffer
    private let hairUploads: [(vertices: MTLBuffer, bodies: MTLBuffer)]
    private let strandCount: Int
    /// The flesh (PhysicsFlesh.swift: GPUFleshHeader, then the pose table, the muscles, the pins...); and when the CPU
    /// steps it, the bodies as it left them per frame slot (what heads and hands are drawn on).
    private let flesh: MTLBuffer
    private let bodyUploads: [MTLBuffer]
    /// The liquids (PhysicsFluidGPU.swift), stepped before each group's narrow phase.
    let fluid: FluidGPU?
    /// It steps the world; otherwise it only draws the CPU's cloths and hair.
    let simulates: Bool
    var hasCloth: Bool { clothTable != nil }
    var hasHair: Bool { !world.hairGroups.isEmpty }
    var hasSoftBodies: Bool { !world.softVertices.isEmpty }
    /// The scene's SDF shapes (SDFBuffers.scene) and what it points at, for the narrow phase.
    private let sdfScene: MTLBuffer
    private let sdfResources: [MTLBuffer]
    private let count: Int

    /// `simulates`: it steps the world; otherwise the CPU does and this only draws its cloths, soft bodies and hair. `clothPrevOffsets`: per
    /// cloth, its mesh's last-frame offset (GPUMesh.prevOffset).
    init(device: MTLDevice, world: PhysicsWorld, sdfScene: MTLBuffer, sdfResources: [MTLBuffer], slots: Int, simulates: Bool = true,
         clothPrevOffsets: [UInt32] = []) throws {
        self.world = world
        self.simulates = simulates
        func buffer<T>(_ array: [T], _ label: String, length: Int? = nil) throws -> MTLBuffer {
            let size = max(length ?? array.count * MemoryLayout<T>.stride, 256)   // (an empty one still holds a record: validation)
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
        bodies = try buffer(world.initialBodies, "physicsBodies")
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
        let runs = stride(from: 0, to: world.substeps, by: PhysicsWorld.contactRefresh).map { first in
            Group(first: UInt32(first), count: UInt32(min(PhysicsWorld.contactRefresh, world.substeps - first)),
                  last: first + PhysicsWorld.contactRefresh >= world.substeps ? 1 : 0)
        }
        groupCount = runs.count
        groups = try buffer(runs, "physicsGroups")
        start = try buffer([SIMD4<Float>](), "physicsStart", length: n * 32)
        order = try buffer([UInt32](), "physicsOrder", length: n * k * 4)
        won = try buffer([UInt32](), "physicsWon", length: n * k * 4)
        live = try buffer([UInt32](), "physicsLive", length: n * k * 4)
        colouring = try buffer([UInt32](repeating: 0, count: PhysicsWorld.maxColours + 3), "physicsColouring")
        snapshots = try (0..<slots).map { try buffer(poses, "physicsSnapshot\($0)") }
        grabs = try (0..<slots).map { try buffer([GPUPhysicsGrab()], "physicsGrab\($0)") }
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
        uploads = simulates || world.cloths.isEmpty && world.softVertices.isEmpty ? []
            : try (0..<slots).map { try buffer(world.initialParticles, "physicsUpload\($0)") }
        constraints = try buffer(world.constraints, "physicsConstraints")
        colourStarts = try buffer(world.colourStarts, "physicsColourStarts")
        joints = try buffer(world.joints, "physicsJoints")
        jointStarts = try buffer(world.jointStarts, "physicsJointStarts")
        ragdolls = try buffer(world.ragdolls, "physicsRagdolls")
        tets = try buffer(world.tets, "physicsTets")
        tetStarts = try buffer(world.tetStarts, "physicsTetStarts")
        softVertices = try buffer(world.softVertices, "physicsSoftVertices")
        softRings = try buffer(world.softRings, "physicsSoftRings")
        softEmbeds = try buffer(world.softEmbeds, "physicsSoftEmbeds")
        lastParticle = try buffer(world.initialParticles.map { SIMD4(PhysicsMath.xyz($0.position), 0) }, "physicsLastParticle")
        strandCount = world.hairStrands.count
        hairStrands = try buffer(world.hairStrands, "physicsHairStrands")
        hairVertices = try buffer(world.initialHairVertices, "physicsHairVertices")
        initialHairVertices = try buffer(world.initialHairVertices, "physicsInitialHairVertices")
        hairParams = try buffer([world.hairParams], "physicsHairParams")
        hairGroups = try buffer(world.hairGroups, "physicsHairGroups")
        hairClock = try buffer([Float(0)], "physicsHairClock")
        hairUploads = simulates || world.hairGroups.isEmpty ? [] : try (0..<slots).map {
            (try buffer(world.initialHairVertices, "physicsHairUpload\($0)"), try buffer(world.initialBodies, "physicsBodyUpload\($0)"))
        }
        flesh = try buffer(world.fleshWords(), "physicsFlesh")
        bodyUploads = simulates || !world.softEmbeds.contains(where: { $0.ids.w == GPUSoftEmbed.bodyKind }) ? []
            : try (0..<slots).map { try buffer(world.initialBodies, "physicsFleshBodies\($0)") }
        self.sdfScene = sdfScene
        self.sdfResources = sdfResources
        if simulates, let liquids = world.fluid {
            fluid = try FluidGPU(device: device, fluid: liquids, bodies: n,
                                 world: FluidGPU.World(params: params, bodies: bodies, statics: statics, staticBounds: staticBounds,
                                                       shapes: shapes, samples: samples, sdfScene: sdfScene))
        } else {
            fluid = nil
        }
    }

    // MARK: - Encoding

    private func dispatch(_ enc: ComputePass, _ state: MTLComputePipelineState, _ threads: Int) {
        let width = min(state.threadExecutionWidth, max(threads, 1))
        enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Back to the start (a replay).
    private var empty: Bool { count + particleCount == 0 && fluid == nil }

    func encodeReset(_ enc: ComputePass, pipelines: Pipelines) {
        guard !empty else { return }
        enc.setComputePipelineState(pipelines[.physicsReset])
        enc.setBuffer(params, offset: 0, index: 0)
        enc.setBuffer(initial, offset: 0, index: 1)
        enc.setBuffer(bodies, offset: 0, index: 2)
        enc.setBuffer(wake, offset: 0, index: 3)
        enc.setBuffer(lastPose, offset: 0, index: 4)
        enc.setBuffer(initialParticles, offset: 0, index: 5)
        enc.setBuffer(particles[0], offset: 0, index: 6)
        enc.setBuffer(lastParticle, offset: 0, index: 7)
        enc.setBuffer(flesh, offset: 0, index: 8)
        dispatch(enc, pipelines[.physicsReset], max(count, particleCount, 1))
        fluid?.encodeReset(enc, pipelines: pipelines)
        guard strandCount > 0 else { return }
        var vertexCount = UInt32(world.initialHairVertices.count)
        enc.setComputePipelineState(pipelines[.physicsHairReset])
        enc.setBuffer(hairParams, offset: 0, index: 0)
        enc.setBuffer(initialHairVertices, offset: 0, index: 1)
        enc.setBuffer(hairVertices, offset: 0, index: 2)
        enc.setBuffer(hairStrands, offset: 0, index: 3)
        enc.setBuffer(hairClock, offset: 0, index: 4)
        enc.setBytes(&vertexCount, length: 4, index: 5)
        dispatch(enc, pipelines[.physicsHairReset], max(Int(vertexCount), strandCount))
    }

    /// The body held for slot `slot`'s steps (the world's `grab`), written once the slot's last frame is done.
    func setGrab(slot: Int, _ grab: GPUPhysicsGrab) {
        grabs[slot].contents().storeBytes(of: grab, as: GPUPhysicsGrab.self)
    }

    /// `steps` steps, in order, into a serial pass, with slot `slot`'s grab.
    func encodeSteps(_ enc: ComputePass, pipelines: Pipelines, steps: Int, slot: Int = 0) {
        guard !empty, steps > 0 else { return }
        enc.useResources(sdfResources, usage: .read)
        enc.setBuffer(params, offset: 0, index: 0)
        // Liquids alone (no bodies, no particles): only their groups (the bodies' stages have nothing to dispatch).
        if count + particleCount == 0, let fluid {
            for _ in 0..<(steps * groupCount) { fluid.encodeGroup(enc, pipelines: pipelines) }
            return
        }
        for _ in 0..<steps {
            enc.setComputePipelineState(pipelines[.physicsClear])
            enc.setBuffer(heads, offset: 0, index: 1)
            enc.setBuffer(particleHeads, offset: 0, index: 3)
            dispatch(enc, pipelines[.physicsClear], max(world.buckets, world.particleBuckets))
            enc.setComputePipelineState(pipelines[.physicsInsert])
            enc.setBuffer(bodies, offset: 0, index: 1)
            enc.setBuffer(heads, offset: 0, index: 2)
            enc.setBuffer(next, offset: 0, index: 3)
            dispatch(enc, pipelines[.physicsInsert], count)
            enc.setComputePipelineState(pipelines[.physicsParticleInsert])
            enc.setBuffer(particles[0], offset: 0, index: 1)
            enc.setBuffer(particleHeads, offset: 0, index: 2)
            enc.setBuffer(particleNext, offset: 0, index: 3)
            dispatch(enc, pipelines[.physicsParticleInsert], particleCount)
            enc.setComputePipelineState(pipelines[.physicsPairs])
            enc.setBuffer(bodies, offset: 0, index: 1)
            enc.setBuffer(statics, offset: 0, index: 2)
            enc.setBuffer(staticBounds, offset: 0, index: 3)
            enc.setBuffer(shapes, offset: 0, index: 4)
            enc.setBuffer(heads, offset: 0, index: 5)
            enc.setBuffer(next, offset: 0, index: 6)
            enc.setBuffer(pairs, offset: 0, index: 7)
            enc.setBuffer(pairCounts, offset: 0, index: 8)
            dispatch(enc, pipelines[.physicsPairs], count)
            enc.setComputePipelineState(pipelines[.physicsLink])
            enc.setBuffer(bodies, offset: 0, index: 1)
            enc.setBuffer(pairs, offset: 0, index: 2)
            enc.setBuffer(pairCounts, offset: 0, index: 3)
            enc.setBuffer(wake, offset: 0, index: 4)
            dispatch(enc, pipelines[.physicsLink], count)
            // The particles' neighbours and colliders (through the bodies' grid).
            enc.setComputePipelineState(pipelines[.physicsParticleNeighbours])
            enc.setBuffer(particles[0], offset: 0, index: 1)
            enc.setBuffer(particleHeads, offset: 0, index: 2)
            enc.setBuffer(particleNext, offset: 0, index: 3)
            enc.setBuffer(neighbours, offset: 0, index: 4)
            enc.setBuffer(neighbourCounts, offset: 0, index: 5)
            enc.setBuffer(bodies, offset: 0, index: 6)
            enc.setBuffer(statics, offset: 0, index: 7)
            enc.setBuffer(staticBounds, offset: 0, index: 8)
            enc.setBuffer(shapes, offset: 0, index: 9)
            enc.setBuffer(heads, offset: 0, index: 10)
            enc.setBuffer(next, offset: 0, index: 11)
            enc.setBuffer(colliders, offset: 0, index: 12)
            enc.setBuffer(colliderCounts, offset: 0, index: 13)
            dispatch(enc, pipelines[.physicsParticleNeighbours], particleCount)
            for g in 0..<groupCount {
                fluid?.encodeGroup(enc, pipelines: pipelines)
                encodeNarrow(enc, pipelines: pipelines, group: g)
                encodeSubsteps(enc, pipelines: pipelines, group: g, slot: slot)
            }
            encodeHair(enc, pipelines: pipelines)
        }
    }

    /// The strands' step, after the bodies' (a thread a strand), then the clock a step on.
    private func encodeHair(_ enc: ComputePass, pipelines: Pipelines) {
        guard strandCount > 0 else { return }
        enc.setComputePipelineState(pipelines[.physicsHair])
        enc.setBuffer(params, offset: 0, index: 0)
        enc.setBuffer(hairParams, offset: 0, index: 1)
        enc.setBuffer(hairStrands, offset: 0, index: 2)
        enc.setBuffer(hairVertices, offset: 0, index: 3)
        enc.setBuffer(bodies, offset: 0, index: 4)
        enc.setBuffer(start, offset: 0, index: 5)
        enc.setBuffer(statics, offset: 0, index: 6)
        enc.setBuffer(staticBounds, offset: 0, index: 7)
        enc.setBuffer(shapes, offset: 0, index: 8)
        enc.setBuffer(samples, offset: 0, index: 9)
        enc.setBuffer(sdfScene, offset: 0, index: 10)
        enc.setBuffer(hairClock, offset: 0, index: 11)
        dispatch(enc, pipelines[.physicsHair], strandCount)
        enc.setComputePipelineState(pipelines[.physicsHairTick])
        enc.setBuffer(hairParams, offset: 0, index: 0)
        enc.setBuffer(hairClock, offset: 0, index: 1)
        dispatch(enc, pipelines[.physicsHairTick], 1)
        enc.setBuffer(params, offset: 0, index: 0)
    }

    /// The drawn strands' control points (and last frame's) into the scene's vertex buffer, ahead of the refits.
    func encodeHairCurves(_ enc: ComputePass, pipelines: Pipelines, slot: Int, positions: MTLBuffer) {
        guard hasHair else { return }
        enc.setComputePipelineState(pipelines[.physicsHairCurves])
        enc.setBuffer(hairStrands, offset: 0, index: 1)
        enc.setBuffer(simulates ? hairVertices : hairUploads[slot].vertices, offset: 0, index: 2)
        enc.setBuffer(simulates ? bodies : hairUploads[slot].bodies, offset: 0, index: 3)
        enc.setBuffer(positions, offset: 0, index: 4)
        for (g, group) in world.hairGroups.enumerated() {
            enc.setBuffer(hairGroups, offset: g * MemoryLayout<GPUHairGroup>.stride, index: 0)
            dispatch(enc, pipelines[.physicsHairCurves], Int(group.counts.y * group.counts.z))
        }
    }

    /// The hair's vertices as the GPU has them (tests).
    func readHairVertices() -> [GPUHairVertex] {
        let n = world.initialHairVertices.count
        return Array(UnsafeBufferPointer(start: hairVertices.contents().bindMemory(to: GPUHairVertex.self, capacity: n), count: n))
    }

    /// Every owned entry's contacts, where the bodies are now (before `group`; after the first, those of pairs that
    /// move): a SIMD group per entry (its lanes share the samples).
    private func encodeNarrow(_ enc: ComputePass, pipelines: Pipelines, group: Int) {
        guard count > 0 else { return }
        let narrow = pipelines[.physicsNarrow], simd = narrow.threadExecutionWidth
        enc.setComputePipelineState(narrow)
        enc.setBuffer(bodies, offset: 0, index: 1)
        enc.setBuffer(statics, offset: 0, index: 2)
        enc.setBuffer(shapes, offset: 0, index: 3)
        enc.setBuffer(samples, offset: 0, index: 4)
        enc.setBuffer(sdfScene, offset: 0, index: 5)
        enc.setBuffer(pairs, offset: 0, index: 6)
        enc.setBuffer(pairCounts, offset: 0, index: 7)
        enc.setBuffer(contacts, offset: 0, index: 8)
        enc.setBuffer(groups, offset: group * MemoryLayout<Group>.stride, index: 9)
        enc.dispatchThreads(MTLSize(width: count * PhysicsWorld.maxPairs * simd, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(narrow.maxTotalThreadsPerThreadgroup / simd, 4) * simd, height: 1, depth: 1))
    }

    /// Run `group` of the step's substeps in one threadgroup (Physics.metal's physicsSubstepsKernel).
    private func encodeSubsteps(_ enc: ComputePass, pipelines: Pipelines, group: Int, slot: Int) {
        let substeps = pipelines[.physicsSubsteps]
        enc.setComputePipelineState(substeps)
        enc.setBuffer(bodies, offset: 0, index: 1)
        enc.setBuffer(start, offset: 0, index: 2)
        enc.setBuffer(statics, offset: 0, index: 3)
        enc.setBuffer(pairs, offset: 0, index: 4)
        enc.setBuffer(pairCounts, offset: 0, index: 5)
        enc.setBuffer(contacts, offset: 0, index: 6)
        enc.setBuffer(wake, offset: 0, index: 7)
        enc.setBuffer(groups, offset: group * MemoryLayout<Group>.stride, index: 8)
        enc.setBuffer(order, offset: 0, index: 9)
        enc.setBuffer(won, offset: 0, index: 10)
        enc.setBuffer(live, offset: 0, index: 11)
        enc.setBuffer(colouring, offset: 0, index: 23)
        enc.setBuffer(grabs[slot], offset: 0, index: 24)
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
        enc.setBuffer(joints, offset: 0, index: 25)
        enc.setBuffer(jointStarts, offset: 0, index: 26)
        enc.setBuffer(ragdolls, offset: 0, index: 27)
        enc.setBuffer(tets, offset: 0, index: 28)
        enc.setBuffer(tetStarts, offset: 0, index: 29)
        enc.setBuffer(flesh, offset: 0, index: 30)
        let lanes = substeps.threadExecutionWidth
        let width = min(substeps.maxTotalThreadsPerThreadgroup / lanes * lanes, (max(count, particleCount) + lanes - 1) / lanes * lanes)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// The frame's instance records (and descriptors, `descriptorStride` > 0) from the bodies, and slot `slot`'s snapshot.
    func encodePose(_ enc: ComputePass, pipelines: Pipelines, slot: Int, instances: MTLBuffer, descriptors: MTLBuffer?,
                    descriptorStride: Int) {
        guard !empty else { return }
        var p = PoseParams(bodies: UInt32(count), descriptorStride: descriptors == nil ? 0 : UInt32(descriptorStride))
        enc.setComputePipelineState(pipelines[.physicsPose])
        enc.setBytes(&p, length: MemoryLayout<PoseParams>.stride, index: 0)
        enc.setBuffer(bodies, offset: 0, index: 1)
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
        if !uploads.isEmpty {
            world.particles.withUnsafeBytes { uploads[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        if !hairUploads.isEmpty {
            world.hairVertices.withUnsafeBytes { hairUploads[slot].vertices.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            world.bodies.withUnsafeBytes {
                if !$0.isEmpty { hairUploads[slot].bodies.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
        }
        if !bodyUploads.isEmpty {
            world.bodies.withUnsafeBytes { bodyUploads[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
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

    /// The soft bodies' drawn vertices (and last frame's) and normals into the scene's vertex buffers, ahead of the refits.
    func encodeSoftMesh(_ enc: ComputePass, pipelines: Pipelines, slot: Int, positions: MTLBuffer, normals: MTLBuffer) {
        guard hasSoftBodies else { return }
        var n = UInt32(world.softVertices.count)
        enc.setComputePipelineState(pipelines[.physicsSoftMesh])
        enc.setBytes(&n, length: 4, index: 0)
        enc.setBuffer(simulates ? particles[0] : uploads[slot], offset: 0, index: 1)
        enc.setBuffer(softVertices, offset: 0, index: 2)
        enc.setBuffer(positions, offset: 0, index: 3)
        enc.setBuffer(softEmbeds, offset: 0, index: 4)
        enc.setBuffer(simulates ? bodies : bodyUploads.isEmpty ? bodies : bodyUploads[slot], offset: 0, index: 5)
        dispatch(enc, pipelines[.physicsSoftMesh], Int(n))
        enc.setComputePipelineState(pipelines[.physicsSoftNormals])
        enc.setBuffer(softVertices, offset: 0, index: 1)
        enc.setBuffer(softRings, offset: 0, index: 2)
        enc.setBuffer(normals, offset: 0, index: 4)
        dispatch(enc, pipelines[.physicsSoftNormals], Int(n))
    }

    /// The liquids' surfaces into the scene's vertex and index buffers, ahead of the structures' builds.
    func encodeFluidSurfaces(_ enc: ComputePass, pipelines: Pipelines, positions: MTLBuffer, normals: MTLBuffer, indices: MTLBuffer) {
        fluid?.encodeSurfaces(enc, pipelines: pipelines, positions: positions, normals: normals, indices: indices)
    }
    var hasFluid: Bool { fluid != nil }

    /// The flesh's buffer as the GPU has it (tests: its clock, the muscles' activations).
    func readFlesh() -> [SIMD4<UInt32>] {
        let n = flesh.length / 16
        return Array(UnsafeBufferPointer(start: flesh.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: n), count: n))
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
        Array(UnsafeBufferPointer(start: bodies.contents().bindMemory(to: GPUPhysicsBody.self, capacity: count), count: count))
    }
}
