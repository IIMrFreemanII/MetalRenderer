import EngineCore
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
package final class PhysicsGPU {
    /// MSL PhysicsGroup: a run of a step's substeps.
    package struct Group {
        package var first: UInt32
        package var count: UInt32
        package var last: UInt32
        package var wide: UInt32 = 0   // (1: coloured across the GPU, encodeColours)
    }

    /// MSL PhysicsPoseParams.
    package struct PoseParams {
        package var bodies: UInt32
        package var descriptorStride: UInt32
        package var pad0: UInt32 = 0
        package var pad1: UInt32 = 0
    }

    package let world: PhysicsWorld
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
    /// With fractured objects, four a body: its still time's anchor (position, rotation), its motion over the last step,
    /// its first position (Physics.metal's physSettleHeap, physLink; PhysicsCPU.settle).
    private let sleepState: MTLBuffer
    /// With fractured objects, the bodies' grid in levels (Physics.metal's physicsFractureInsertKernel; PhysicsLevels):
    /// its heads and next, the levels used, the big bodies and the first level's cell (`levels.z`).
    private let levelHeads: MTLBuffer, levelNext: MTLBuffer, levels: MTLBuffer, bigBodies: MTLBuffer
    /// ...and per bucket whether a body that isn't quiet is in it: a quiet body with none in reach keeps its partners.
    private let hotBuckets: MTLBuffer
    /// With fractured objects, the narrow phase's work: the step's owned entries (how many, then them:
    /// physicsNarrowListKernel), and the dispatches over them and over the colours' pairs (encodeNarrow).
    private let narrowList: MTLBuffer, narrowArgs: MTLBuffer
    /// ...and the bodies that look for partners this step (how many, then them: physicsPairsKeepKernel), its dispatch.
    private let looking: MTLBuffer, lookingArgs: MTLBuffer
    /// With fractured objects and no ragdolls (which wake whole in the substeps' kernel), the pairs are coloured
    /// across the GPU (encodeColours) rather than by the substeps' one threadgroup; `colourWork`: its counts.
    private let wide: Bool
    /// ...and with nothing but bodies and joints (no particles, cloth, soft bodies), the substeps too (encodeWideSubsteps):
    /// their stages as dispatches over every body and each colour, not the substeps' one threadgroup (one GPU core).
    private let wideSteps: Bool
    private let runs: [Group]
    private let jointRuns: [SIMD2<UInt32>]   // (each joint colour's run: encodeWideSubsteps)
    private let wideArgs: MTLBuffer
    private let colourWork: MTLBuffer
    /// The greedy colouring's rounds (MSL PHYS_GREEDY_ROUNDS; physicsColourPickKernel), and per body its colours and
    /// two arrays of claims.
    static let greedyRounds = 48
    private let colourMarks: MTLBuffer
    /// The kicks by Jacobi (with `wideSteps`, `jacobi`: encodeWideSubsteps): per pair entry its kick for both bodies
    /// and its impacts' strikes, then per body the entries that touch it (where each body's run starts, the end, its
    /// cursors; the runs, in entry order): MSL physicsJacobiKickKernel, physicsJacobiApplyKernel.
    private let kicks: MTLBuffer, strikes: MTLBuffer, touches: MTLBuffer, touchList: MTLBuffer
    /// The colours' kicks by Jacobi, in one dispatch over every pair and one over the bodies (not a dispatch a colour,
    /// one after another): `METALRENDERER_PHYSICS_JACOBI=0` for a colour at a time, as the CPU.
    package static let jacobi = ProcessInfo.processInfo.environment["METALRENDERER_PHYSICS_JACOBI"] != "0"
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
    /// The particles the world's own stages step: those before the cars' nodes (the cars' kernels step theirs).
    private let worldParticles: Int
    /// The cars (Shaders/PhysicsCars.metal), when the world has cars and this steps it.
    package let cars: CarsGPU?
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
    package let fluid: FluidGPU?
    /// Fractured objects (Physics+Fracture.swift): per body its node and its step's state, the welds (and as they
    /// start), per body its welds (from `weldStarts`), the commands and their clock (steps run, commands), what the
    /// fracture kernels are told; and the substeps' tables (MSL PhysicsTables: the tets', the welds', the states',
    /// the loose links' addresses, the loose joints) and what they point at.
    private let fractureNodes: MTLBuffer
    private let fractureState: MTLBuffer
    private let shapeBoxes: MTLBuffer
    private let welds: MTLBuffer
    private let initialWelds: MTLBuffer
    private let weldStarts: MTLBuffer
    private let weldList: MTLBuffer
    private let commands: MTLBuffer
    private let fractureClock: MTLBuffer
    private let fractureParams: MTLBuffer
    private let tables: MTLBuffer
    private let tableResources: [MTLResource]
    /// The loose links (Physics+LooseJoints.swift; with `loose`): the step's in their colours (MSL PHYS_LINK_HEAD
    /// words, where each colour's run starts and how many colours, then the welds in their colours, then the gather's
    /// scratch: physicsLooseGatherKernel), and per body the colours its links took (between steps all 0).
    private let looseLinks: MTLBuffer
    private let looseMasks: MTLBuffer
    private let loose: Bool
    /// Per body whether it broke this step, and the ring of steps' breaks the dust is made from (MSL
    /// physicsFractureEventsKernel: a header per slot, then its events); the particles read it (ParticlesGPU.breakRing).
    private let broke: MTLBuffer
    package let breakRing: MTLBuffer
    private var commandsSent = 0, commandsKept = 0
    package var fractures: Bool { world.fractures }
    /// It steps the world; otherwise it only draws the CPU's cloths and hair.
    package let simulates: Bool
    package var hasCloth: Bool { clothTable != nil }
    package var hasHair: Bool { !world.hairGroups.isEmpty }
    package var hasSoftBodies: Bool { !world.softVertices.isEmpty }
    /// The scene's SDF shapes (SDFBuffers.scene) and what it points at, for the narrow phase.
    private let sdfScene: MTLBuffer
    private let sdfResources: [MTLBuffer]
    private let count: Int

    /// `simulates`: it steps the world; otherwise the CPU does and this only draws its cloths, soft bodies and hair. `clothPrevOffsets`: per
    /// cloth, its mesh's last-frame offset (GPUMesh.prevOffset).
    /// The statics' heightfields changed (a terrain's sectors under a brush): their samples, shapes and boxes copied
    /// again (shared buffers: a frame in flight may see them a frame early).
    package func refreshStatics(_ world: PhysicsWorld) {
        func copy<T>(_ array: [T], into b: MTLBuffer) {
            array.withUnsafeBytes { raw in
                if !raw.isEmpty && raw.count <= b.length { b.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
            }
        }
        copy(world.samples, into: samples)
        copy(world.shapes, into: shapes)
        copy(world.staticBounds.flatMap { [SIMD4($0.lo, 0), SIMD4($0.hi, 0)] }, into: staticBounds)
    }

    package init(device: MTLDevice, world: PhysicsWorld, sdfScene: MTLBuffer, sdfResources: [MTLBuffer], slots: Int, simulates: Bool = true,
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
        // With cars: their nodes are the world's last particles, which its own stages leave to the cars' kernels, and
        // their wheels kinematic bodies of no mass to it (CarsGPU).
        let carNodes = simulates && world.hasCars ? CarsGPU.firstNode(world) : nil
        precondition(!(simulates && world.hasCars) || carNodes != nil, "a world with cars and particles after their nodes")
        var startBodies = world.initialBodies, startParams = world.params
        if let carNodes {
            CarsGPU.prepare(&startBodies, world.carSystem)
            startParams.particles.x = UInt32(carNodes)
        }
        worldParticles = carNodes ?? world.particles.count
        params = try buffer([startParams], "physicsParams")
        initial = try buffer(startBodies, "physicsInitial")
        bodies = try buffer(startBodies, "physicsBodies")
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
        // (The first level's cells: twice the most a body of the bodies' mean radius reaches in a step.)
        let mean = world.bodies.isEmpty ? 1 : world.bodies.reduce(Float(0)) { $0 + $1.invInertia.w } / Float(world.bodies.count)
        let first = 2 * PhysicsLevels.most(max(mean, 0.01))
        levelHeads = try buffer([UInt32](), "physicsLevelHeads", length: world.buckets * 4)
        hotBuckets = try buffer([UInt32](), "physicsHotBuckets", length: world.fractures ? world.buckets * 4 : 0)
        narrowList = try buffer([UInt32](), "physicsNarrowList", length: world.fractures ? (1 + n * k) * 4 : 0)
        narrowArgs = try buffer([UInt32](repeating: 0, count: 6), "physicsNarrowArgs")
        looking = try buffer([UInt32](), "physicsLooking", length: world.fractures ? (1 + n) * 4 : 0)
        lookingArgs = try buffer([UInt32](repeating: 0, count: 6), "physicsLookingArgs")
        levelNext = try buffer([UInt32](), "physicsLevelNext", length: max(n, 1) * 4)
        levels = try buffer([SIMD4<UInt32>(0, 0, first.bitPattern, 0)], "physicsLevels")
        bigBodies = try buffer([UInt32](), "physicsBigBodies", length: max(n, 1) * 4)
        sleepState = try buffer(world.initialBodies.flatMap { [$0.position, $0.rotation, .zero, $0.position] }, "physicsSleep",
                                length: max(n, 1) * 64)
        // (w: how far it is hidden: a disabled body, 1, until the pose kernel's snapshots say otherwise.)
        let poses = world.initialBodies.flatMap {
            [SIMD4(PhysicsMath.xyz($0.position), $0.info.y & PhysicsWorld.disabledBit != 0 ? 1 : 0), $0.rotation]
        }
        lastPose = try buffer(poses, "physicsLastPose")
        wide = world.fractures && world.ragdolls.isEmpty
        wideSteps = wide && worldParticles == 0 && world.constraints.isEmpty && world.tets.isEmpty
        jointRuns = (0..<(world.jointStarts.count - 1)).map { SIMD2(world.jointStarts[$0], world.jointStarts[$0 + 1]) }
        colourWork = try buffer([UInt32](repeating: 0, count: 128), "physicsColourWork")
        colourMarks = try buffer([UInt32](), "physicsColourMarks", length: wide ? 3 * n * 4 : 0)
        // (Each colour's dispatch, then by Jacobi every pair's and the tail's, then the links': physicsWideArgsKernel.)
        wideArgs = try buffer([UInt32](repeating: 0, count: 6 * PhysicsWorld.maxColours + 9), "physicsWideArgs")
        let jacobi = wideSteps && PhysicsGPU.jacobi
        kicks = try buffer([SIMD4<Float>](), "physicsKicks", length: jacobi ? n * k * 64 : 0)
        strikes = try buffer([SIMD4<Float>](), "physicsStrikes", length: jacobi ? n * k * 32 : 0)
        touches = try buffer([UInt32](), "physicsTouches", length: jacobi ? (2 * n + 2) * 4 : 0)
        touchList = try buffer([UInt32](), "physicsTouchList", length: jacobi ? 2 * n * k * 4 : 0)
        runs = stride(from: 0, to: world.substeps, by: PhysicsWorld.contactRefresh).map { [wide] first in
            Group(first: UInt32(first), count: UInt32(min(PhysicsWorld.contactRefresh, world.substeps - first)),
                  last: first + PhysicsWorld.contactRefresh >= world.substeps ? 1 : 0, wide: wide ? 1 : 0)
        }
        groupCount = runs.count
        // (After the runs, one of no substeps that only settles: encodeWideSubsteps' last.)
        groups = try buffer(runs + [Group(first: 1, count: 0, last: 1, wide: 1)], "physicsGroups")
        start = try buffer([SIMD4<Float>](), "physicsStart", length: n * 32)
        order = try buffer([UInt32](), "physicsOrder", length: n * k * 4)
        won = try buffer([UInt32](), "physicsWon", length: n * k * 4)
        live = try buffer([UInt32](), "physicsLive", length: n * k * 4)
        // (Where each colour starts, the end, the colours, how many are left over; with fractured objects, the
        // left-over pairs' colours: where each starts, the end, how many: physColourPairs.)
        colouring = try buffer([UInt32](repeating: 0, count: 2 * PhysicsWorld.maxColours + 5), "physicsColouring")
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
        carStates = world.carSystem.cars
        carSurfaces = world.carSurfaces
        carRestSize = carStates.map { PhysicsGPU.carSize($0, world.initialParticles) }
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
        fractureNodes = try buffer(world.fractureNodes, "physicsFractureNodes")
        fractureState = try buffer(world.fractureState, "physicsFractureState")
        shapeBoxes = try buffer(world.shapeBoxes.isEmpty ? [SIMD4<Float>.zero] : world.shapeBoxes, "physicsShapeBoxes")
        welds = try buffer(world.initialWelds, "physicsWelds")
        initialWelds = try buffer(world.initialWelds, "physicsInitialWelds")
        weldStarts = try buffer(world.weldStarts, "physicsWeldStarts")
        weldList = try buffer(world.weldList, "physicsWeldList")
        commands = try buffer([GPUFractureCommand](), "physicsCommands",
                              length: world.fractures ? PhysicsWorld.maxCommands * MemoryLayout<GPUFractureCommand>.stride : 0)
        fractureClock = try buffer([SIMD4<UInt32>()], "physicsFractureClock")
        let looseJoints = world.fractures ? world.looseJoints.flatMap { $0.on ? $0 : nil } : nil
        loose = looseJoints != nil
        fractureParams = try buffer([GPUFractureParams(counts: SIMD4(UInt32(n), UInt32(world.initialWelds.count), UInt32(PhysicsWorld.maxCommands), 0),
                                                       tuning: world.fractureTuning, shaken: SIMD4(looseJoints?.shaken ?? 0, 0, 0, 0))],
                                    "physicsFractureParams")
        looseLinks = try buffer([UInt32](), "physicsLooseLinks", length: loose ? (PhysicsGPU.linkHead + 3 * world.initialWelds.count) * 4 : 0)
        looseMasks = try buffer([UInt64](repeating: 0, count: loose ? n : 0), "physicsLooseMasks")
        tables = try buffer([Tables(tets: tets.gpuAddress, tetStarts: tetStarts.gpuAddress, welds: welds.gpuAddress,
                                    fracture: fractureState.gpuAddress, flags: SIMD4(world.fractures ? 1 : 0, jacobi ? 1 : 0, 0, 0),
                                    links: looseLinks.gpuAddress, masks: looseMasks.gpuAddress, weldStarts: weldStarts.gpuAddress,
                                    weldList: weldList.gpuAddress, loose: GPULooseParams(looseJoints),
                                    kicks: kicks.gpuAddress, strikes: strikes.gpuAddress, touches: touches.gpuAddress,
                                    touchList: touchList.gpuAddress)], "physicsTables")
        tableResources = [tets, tetStarts, welds, fractureState, looseLinks, looseMasks, weldStarts, weldList, kicks, strikes, touches, touchList]
        broke = try buffer([UInt32](), "physicsBroke", length: n * 4)
        breakRing = try buffer([UInt32](), "physicsBreakRing", length: world.fractures || carNodes != nil
            ? PhysicsWorld.ringSlots * (16 + PhysicsWorld.ringEvents * MemoryLayout<GPUBreakEvent>.stride) : 0)
        if simulates, let liquids = world.fluid {
            fluid = try FluidGPU(device: device, fluid: liquids, bodies: n,
                                 world: FluidGPU.World(params: params, bodies: bodies, statics: statics, staticBounds: staticBounds,
                                                       shapes: shapes, samples: samples, sdfScene: sdfScene))
        } else {
            fluid = nil
        }
        cars = try carNodes.map { try CarsGPU(device: device, world: world, firstNode: $0, slots: slots) }
        sendCommands()   // (a scene's scripted ones)
    }

    /// The buffers of the world's the cars' kernels read and write.
    private var carWorld: CarsGPU.World {
        CarsGPU.World(params: params, particles: particles[0], bodies: bodies, statics: statics, staticBounds: staticBounds, shapes: shapes,
                      samples: samples, sdfScene: sdfScene, ring: breakRing, fractureState: fractureState, fractureNodes: fractureNodes)
    }

    // MARK: - Encoding

    /// The pass runs its dispatches together (with liquids, `Renderer.encodeSceneUpdate`): a barrier ahead of each of
    /// the bodies' (theirs run in order), and the liquids' side by side (FluidGPU).
    package var concurrent = false {
        didSet { fluid?.concurrent = concurrent }
    }

    /// Bench only (`METALRENDERER_PHYSICS_PARTS=1`, passes timed apart): the step's parts each in a pass of their own,
    /// named (`phys broad`, `phys narrow`, `phys colour`, `phys substeps`, `phys fracture`), so the benchmark's table
    /// times them apart. The renderer sets it around `encodeSteps`: it closes the open pass and opens the named one.
    package var parts: ((String) -> Void)?

    private func part(_ name: String) { parts?(name) }

    /// Ahead of a dispatch in a concurrent pass: what came before it is done.
    private func barrier(_ enc: ComputePass) {
        if concurrent { enc.memoryBarrier(scope: .buffers) }
    }

    private func dispatch(_ enc: ComputePass, _ state: MTLComputePipelineState, _ threads: Int) {
        barrier(enc)
        let width = min(state.threadExecutionWidth, max(threads, 1))
        enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Back to the start (a replay).
    private var empty: Bool { count + particleCount == 0 && fluid == nil }

    /// Steps encoded since the last reset (what the particles' dust keeps behind: Renderer.encodeSceneUpdate).
    package private(set) var stepsEncoded = 0

    package func encodeReset(_ enc: ComputePass, pipelines: Pipelines) {
        guard !empty else { return }
        stepsEncoded = 0
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
        if fractures {
            enc.setComputePipelineState(pipelines[.physicsFractureReset])
            enc.setBuffer(fractureParams, offset: 0, index: 1)
            enc.setBuffer(fractureState, offset: 0, index: 2)
            enc.setBuffer(welds, offset: 0, index: 3)
            enc.setBuffer(initialWelds, offset: 0, index: 4)
            enc.setBuffer(fractureClock, offset: 0, index: 5)
            enc.setBuffer(sleepState, offset: 0, index: 6)
            dispatch(enc, pipelines[.physicsFractureReset], max(count, world.initialWelds.count, 1))
        }
        fluid?.encodeReset(enc, pipelines: pipelines)
        if let cars {
            barrier(enc)
            cars.encodeReset(enc, pipelines: pipelines)
        }
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
    package func setGrab(slot: Int, _ grab: GPUPhysicsGrab) {
        grabs[slot].contents().storeBytes(of: grab, as: GPUPhysicsGrab.self)
    }

    /// `steps` steps, in order, into a serial pass, with slot `slot`'s grab.
    package func encodeSteps(_ enc: ComputePass, pipelines: Pipelines, steps: Int, slot: Int = 0) {
        guard !empty, steps > 0 else { return }
        enc.useResources(sdfResources, usage: .read)
        enc.setBuffer(params, offset: 0, index: 0)
        // Liquids alone (no bodies, no particles): only their groups (the bodies' stages have nothing to dispatch).
        if count + particleCount == 0, let fluid {
            for _ in 0..<(steps * groupCount) { fluid.encodeGroup(enc, pipelines: pipelines) }
            return
        }
        enc.useResources(tableResources, usage: [.read, .write])   // (the substeps reach them through `tables`)
        cars?.sendCommands(world, slot: slot, steps: steps)
        stepsEncoded += steps
        for _ in 0..<steps {
            part("phys fracture")
            if fractures { encodeFractureCommands(enc, pipelines: pipelines) }
            if loose { encodeLooseGather(enc, pipelines: pipelines) }
            part("phys broad")
            encodeBroad(enc, pipelines: pipelines)
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
            dispatch(enc, pipelines[.physicsParticleNeighbours], worldParticles)
            if let cars {
                part("phys cars")
                cars.encodeBegin(enc, pipelines: pipelines, world: carWorld, slot: slot) { barrier(enc) }
            }
            for g in 0..<groupCount {
                fluid?.encodeGroup(enc, pipelines: pipelines)
                part("phys narrow")
                encodeNarrow(enc, pipelines: pipelines, group: g, slot: slot)
                if let cars {
                    // (The cars' substeps before the world's: its bodies meet the wheels where the group leaves them.)
                    part("phys cars")
                    cars.encodeSubsteps(enc, pipelines: pipelines, world: carWorld, groups: groups, groupOffset: g * MemoryLayout<Group>.stride) { barrier(enc) }
                }
                encodeSubsteps(enc, pipelines: pipelines, group: g, slot: slot)
            }
            encodeHair(enc, pipelines: pipelines)
            part("phys fracture")
            if fractures, let cars { cars.encodeStrikes(enc, pipelines: pipelines, world: carWorld) { barrier(enc) } }
            if fractures { encodeFractureEnd(enc, pipelines: pipelines) }
            if let cars {
                part("phys cars")
                cars.encodeEnd(enc, pipelines: pipelines, world: carWorld) { barrier(enc) }
                if fractures { cars.encodeGiveWay(enc, pipelines: pipelines, world: carWorld) { barrier(enc) } }
            }
        }
    }

    /// The step's broad phase: the grids, each body's partners, their owners and who wakes.
    private func encodeBroad(_ enc: ComputePass, pipelines: Pipelines) {
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
        dispatch(enc, pipelines[.physicsParticleInsert], worldParticles)
        if world.fractures {   // (the levelled grid, for the bodies' partners; the particles' colliders use the other)
            enc.setComputePipelineState(pipelines[.physicsFractureClear])
            enc.setBuffer(levelHeads, offset: 0, index: 1)
            enc.setBuffer(levels, offset: 0, index: 2)
            enc.setBuffer(hotBuckets, offset: 0, index: 3)
            enc.setBuffer(narrowList, offset: 0, index: 4)
            enc.setBuffer(looking, offset: 0, index: 5)
            dispatch(enc, pipelines[.physicsFractureClear], world.buckets)
            enc.setComputePipelineState(pipelines[.physicsFractureInsert])
            enc.setBuffer(bodies, offset: 0, index: 1)
            enc.setBuffer(levelHeads, offset: 0, index: 2)
            enc.setBuffer(levelNext, offset: 0, index: 3)
            enc.setBuffer(levels, offset: 0, index: 4)
            enc.setBuffer(bigBodies, offset: 0, index: 5)
            enc.setBuffer(hotBuckets, offset: 0, index: 6)
            dispatch(enc, pipelines[.physicsFractureInsert], count)
        }
        let pairing = pipelines[world.fractures ? .physicsFracturePairs : .physicsPairs]
        enc.setComputePipelineState(pairing)
        enc.setBuffer(bodies, offset: 0, index: 1)
        enc.setBuffer(statics, offset: 0, index: 2)
        enc.setBuffer(staticBounds, offset: 0, index: 3)
        enc.setBuffer(shapes, offset: 0, index: 4)
        enc.setBuffer(world.fractures ? levelHeads : heads, offset: 0, index: 5)
        enc.setBuffer(world.fractures ? levelNext : next, offset: 0, index: 6)
        enc.setBuffer(pairs, offset: 0, index: 7)
        enc.setBuffer(pairCounts, offset: 0, index: 8)
        if world.fractures {
            enc.setBuffer(shapeBoxes, offset: 0, index: 9)
            enc.setBuffer(levels, offset: 0, index: 10)
            enc.setBuffer(bigBodies, offset: 0, index: 11)
            enc.setBuffer(hotBuckets, offset: 0, index: 12)
            enc.setBuffer(looking, offset: 0, index: 13)
            // (Only the bodies that look, a SIMD group each: the rest keep their partners.)
            enc.setComputePipelineState(pipelines[.physicsPairsKeep])
            dispatch(enc, pipelines[.physicsPairsKeep], count)
            encodeArgs(enc, pipelines: pipelines, list: looking, args: lookingArgs, perGroup: simdPerGroup(pairing))
            enc.setComputePipelineState(pairing)
            enc.setBuffer(bodies, offset: 0, index: 1)   // (the args' kernel had 1 to 4)
            enc.setBuffer(statics, offset: 0, index: 2)
            enc.setBuffer(staticBounds, offset: 0, index: 3)
            enc.setBuffer(shapes, offset: 0, index: 4)
            barrier(enc)
            enc.dispatchThreadgroups(indirectBuffer: lookingArgs, indirectBufferOffset: 0,
                                     threadsPerThreadgroup: MTLSize(width: simdPerGroup(pairing) * pairing.threadExecutionWidth, height: 1, depth: 1))
        } else {
            dispatch(enc, pairing, count)
        }
        let linking = pipelines[world.fractures ? .physicsFractureLink : .physicsLink]
        enc.setComputePipelineState(linking)
        enc.setBuffer(bodies, offset: 0, index: 1)
        enc.setBuffer(pairs, offset: 0, index: 2)
        enc.setBuffer(pairCounts, offset: 0, index: 3)
        enc.setBuffer(wake, offset: 0, index: 4)
        if world.fractures { enc.setBuffer(sleepState, offset: 0, index: 5) }
        dispatch(enc, linking, count)
        guard world.fractures else { return }
        enc.setComputePipelineState(pipelines[.physicsNarrowList])
        enc.setBuffer(narrowList, offset: 0, index: 5)
        dispatch(enc, pipelines[.physicsNarrowList], count)
        encodeNarrowArgs(enc, pipelines: pipelines, which: PhysicsGPU.narrowListed)
    }

    /// MSL PHYS_NARROW_*: what the fractured objects' narrow phase goes over.
    private static let narrowAll: UInt32 = 0, narrowListed: UInt32 = 1, narrowSolved: UInt32 = 2

    /// Items a threadgroup of a kernel with a SIMD group an item (the narrow phase's entries, the pairs' bodies).
    private func simdPerGroup(_ kernel: MTLComputePipelineState) -> Int {
        min(kernel.maxTotalThreadsPerThreadgroup / kernel.threadExecutionWidth, 4)
    }

    private func encodeNarrowArgs(_ enc: ComputePass, pipelines: Pipelines, which: UInt32) {
        encodeArgs(enc, pipelines: pipelines, list: narrowList, args: narrowArgs, which: which,
                   perGroup: simdPerGroup(pipelines[.physicsFractureNarrow]))
    }

    /// A dispatch of `perGroup`-wide threadgroups over a list (how many, then them: `which` PHYS_NARROW_LISTED, into
    /// args[0...2]) or the colours' pairs (PHYS_NARROW_SOLVED, args[3...5]): MSL physicsNarrowArgsKernel.
    private func encodeArgs(_ enc: ComputePass, pipelines: Pipelines, list: MTLBuffer, args: MTLBuffer,
                            which: UInt32 = PhysicsGPU.narrowListed, perGroup: Int) {
        var w = SIMD2<UInt32>(which, UInt32(perGroup))
        enc.setComputePipelineState(pipelines[.physicsNarrowArgs])
        enc.setBuffer(list, offset: 0, index: 1)
        enc.setBuffer(colouring, offset: 0, index: 2)
        enc.setBuffer(args, offset: 0, index: 3)
        enc.setBytes(&w, length: 8, index: 4)
        dispatch(enc, pipelines[.physicsNarrowArgs], 1)
    }

    // MARK: - Fracture

    /// MSL PhysicsTables: the substeps' tables' addresses, the flags (x = 1: there are fractured objects), the loose joints.
    private struct Tables {
        var tets: UInt64, tetStarts: UInt64, welds: UInt64, fracture: UInt64
        var flags: SIMD4<UInt32>
        var links: UInt64, masks: UInt64, weldStarts: UInt64, weldList: UInt64
        var loose: GPULooseParams
        var kicks: UInt64, strikes: UInt64, touches: UInt64, touchList: UInt64
    }
    /// MSL PHYS_LINK_HEAD: the loose links' words before their welds (each colour's start, the end, how many colours,
    /// how many links, whether a weld went loose since).
    static let linkHead = PhysicsWorld.linkColours + 5

    /// The world's commands the GPU hasn't had yet (a shot, a blast: the CPU adds them between frames, stamped with a
    /// step not yet encoded), then their count. A shared buffer: a frame in flight may see them early, before their step.
    /// (The cars' commands aren't among them: CarsGPU sends each frame's steps' own.)
    package func sendCommands() {
        let all = world.fractureCommands
        guard fractures, all.count > commandsSent else { return }
        let out = commands.contents().bindMemory(to: GPUFractureCommand.self, capacity: PhysicsWorld.maxCommands)
        for c in all[commandsSent...] where c.info.y != PhysicsWorld.FractureCommand.car.rawValue && commandsKept < PhysicsWorld.maxCommands {
            out[commandsKept] = c
            commandsKept += 1
        }
        commandsSent = all.count
        fractureClock.contents().advanced(by: 4).storeBytes(of: UInt32(commandsKept), as: UInt32.self)
    }

    /// The step's commands, ahead of its broad phase.
    private func encodeFractureCommands(_ enc: ComputePass, pipelines: Pipelines) {
        enc.setComputePipelineState(pipelines[.physicsFractureCommand])
        enc.setBuffer(fractureParams, offset: 0, index: 1)
        enc.setBuffer(bodies, offset: 0, index: 2)
        enc.setBuffer(fractureNodes, offset: 0, index: 3)
        enc.setBuffer(fractureState, offset: 0, index: 4)
        enc.setBuffer(commands, offset: 0, index: 5)
        enc.setBuffer(fractureClock, offset: 0, index: 6)
        enc.setBuffer(lastPose, offset: 0, index: 7)
        dispatch(enc, pipelines[.physicsFractureCommand], count)
    }

    /// The step's loose links, a step older, in their colours (one threadgroup: PhysicsWorld.gatherLooseLinks).
    private func encodeLooseGather(_ enc: ComputePass, pipelines: Pipelines) {
        let gather = pipelines[.physicsLooseGather]
        enc.setComputePipelineState(gather)
        enc.setBuffer(fractureParams, offset: 0, index: 1)
        enc.setBuffer(bodies, offset: 0, index: 2)
        enc.setBuffer(tables, offset: 0, index: 3)
        barrier(enc)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(gather.maxTotalThreadsPerThreadgroup, 1024), height: 1, depth: 1))
    }

    /// The step's end: what broke, what came free, what faded (two phases: verdicts, then each body's own).
    private func encodeFractureEnd(_ enc: ComputePass, pipelines: Pipelines) {
        enc.setComputePipelineState(pipelines[.physicsFractureVerdict])
        enc.setBuffer(fractureParams, offset: 0, index: 1)
        enc.setBuffer(bodies, offset: 0, index: 2)
        enc.setBuffer(fractureNodes, offset: 0, index: 3)
        enc.setBuffer(fractureState, offset: 0, index: 4)
        dispatch(enc, pipelines[.physicsFractureVerdict], count)
        enc.setComputePipelineState(pipelines[.physicsFractureApply])
        enc.setBuffer(welds, offset: 0, index: 5)
        enc.setBuffer(weldStarts, offset: 0, index: 6)
        enc.setBuffer(weldList, offset: 0, index: 7)
        enc.setBuffer(fractureClock, offset: 0, index: 8)
        enc.setBuffer(lastPose, offset: 0, index: 9)
        enc.setBuffer(broke, offset: 0, index: 10)
        dispatch(enc, pipelines[.physicsFractureApply], count)
        // The step's breaks into the ring, in body order: one threadgroup.
        let events = pipelines[.physicsFractureEvents]
        enc.setComputePipelineState(events)
        enc.setBuffer(breakRing, offset: 0, index: 11)
        barrier(enc)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(events.maxTotalThreadsPerThreadgroup, 1024), height: 1, depth: 1))
    }

    /// The fracture states and welds as the GPU has them (tests).
    package func readFractureState() -> [GPUFractureState] {
        Array(UnsafeBufferPointer(start: fractureState.contents().bindMemory(to: GPUFractureState.self, capacity: count), count: count))
    }
    /// Each body's pair entries (`maxPairs` each), how many it uses, and their contacts (`maxContacts` an entry): tests.
    package func readPairs() -> (pairs: [GPUPhysicsPair], counts: [UInt32], contacts: [GPUPhysicsContact]) {
        let n = count * PhysicsWorld.maxPairs, m = n * PhysicsWorld.maxContacts
        return (Array(UnsafeBufferPointer(start: pairs.contents().bindMemory(to: GPUPhysicsPair.self, capacity: n), count: n)),
                Array(UnsafeBufferPointer(start: pairCounts.contents().bindMemory(to: UInt32.self, capacity: count), count: count)),
                Array(UnsafeBufferPointer(start: contacts.contents().bindMemory(to: GPUPhysicsContact.self, capacity: m), count: m)))
    }
    package func readWelds() -> [GPUFractureWeld] {
        let n = world.initialWelds.count
        return Array(UnsafeBufferPointer(start: welds.contents().bindMemory(to: GPUFractureWeld.self, capacity: n), count: n))
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
    package func encodeHairCurves(_ enc: ComputePass, pipelines: Pipelines, slot: Int, positions: MTLBuffer) {
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
    package func readHairVertices() -> [GPUHairVertex] {
        let n = world.initialHairVertices.count
        return Array(UnsafeBufferPointer(start: hairVertices.contents().bindMemory(to: GPUHairVertex.self, capacity: n), count: n))
    }

    /// Every owned entry's contacts, where the bodies are now (before `group`; after the first, those of pairs that
    /// move): a SIMD group per entry (its lanes share the samples). With fractured objects, none for a pair that can't move.
    private func encodeNarrow(_ enc: ComputePass, pipelines: Pipelines, group: Int, slot: Int) {
        guard count > 0 else { return }
        let narrow = pipelines[fractures ? .physicsFractureNarrow : .physicsNarrow], simd = narrow.threadExecutionWidth
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
        enc.setBuffer(weldStarts, offset: 0, index: 10)
        enc.setBuffer(weldList, offset: 0, index: 11)
        enc.setBuffer(welds, offset: 0, index: 12)
        let width = MTLSize(width: simdPerGroup(narrow) * simd, height: 1, depth: 1)
        if fractures {   // (who wakes this step, who is held: Physics.metal's physicsFractureNarrowKernel)
            enc.setBuffer(wake, offset: 0, index: 13)
            enc.setBuffer(grabs[slot], offset: 0, index: 14)
            // The step's first over the owned entries; the refreshes, with the colouring across the GPU, over the
            // colours' pairs (the rest: every entry).
            var which = group == 0 ? PhysicsGPU.narrowListed : wide ? PhysicsGPU.narrowSolved : PhysicsGPU.narrowAll
            enc.setBuffer(narrowList, offset: 0, index: 15)
            enc.setBuffer(colouring, offset: 0, index: 16)
            enc.setBuffer(order, offset: 0, index: 17)
            enc.setBuffer(won, offset: 0, index: 18)
            enc.setBytes(&which, length: 4, index: 19)
            if which != PhysicsGPU.narrowAll {
                barrier(enc)
                enc.dispatchThreadgroups(indirectBuffer: narrowArgs, indirectBufferOffset: which == PhysicsGPU.narrowListed ? 0 : 12,
                                         threadsPerThreadgroup: width)
                return
            }
        }
        barrier(enc)
        enc.dispatchThreads(MTLSize(width: count * PhysicsWorld.maxPairs * simd, height: 1, depth: 1), threadsPerThreadgroup: width)
    }

    /// The pairs coloured across the GPU, before the step's first substeps (Physics.metal's physicsColour*Kernel: the
    /// rounds of physColourPairs as dispatches over the live pairs, the same colours).
    private func encodeColours(_ enc: ComputePass, pipelines: Pipelines, slot: Int) {
        let args = (PhysicsWorld.maxRounds + 2 + PhysicsWorld.maxColours) * 4, width = MTLSize(width: 64, height: 1, depth: 1)
        enc.setComputePipelineState(pipelines[.physicsColourReset])
        enc.setBuffer(colourWork, offset: 0, index: 4)   // (buffer 0 stays the params: the kernels after read them there)
        dispatch(enc, pipelines[.physicsColourReset], 128)
        enc.setComputePipelineState(pipelines[.physicsColourStart])
        enc.setBuffer(pairs, offset: 0, index: 1)
        enc.setBuffer(pairCounts, offset: 0, index: 2)
        enc.setBuffer(live, offset: 0, index: 3)
        enc.setBuffer(colourWork, offset: 0, index: 4)
        enc.setBuffer(bodies, offset: 0, index: 5)
        enc.setBuffer(wake, offset: 0, index: 6)
        enc.setBuffer(grabs[slot], offset: 0, index: 7)
        enc.setBuffer(contacts, offset: 0, index: 8)
        enc.setBuffer(colourMarks, offset: 0, index: 9)
        // (With the tail by Jacobi, `flat`: the one-sided pairs coloured with the rest, no extra colours, the leftovers
        // listed as they are.)
        var flat: UInt32 = wideSteps && PhysicsGPU.jacobi ? 1 : 0
        enc.setBytes(&flat, length: 4, index: 10)
        dispatch(enc, pipelines[.physicsColourStart], count * PhysicsWorld.maxPairs)
        enc.setComputePipelineState(pipelines[.physicsColourArgs])
        dispatch(enc, pipelines[.physicsColourArgs], 1)
        enc.setBuffer(won, offset: 0, index: 5)
        enc.setBuffer(colourMarks, offset: 0, index: 9)
        // (By Jacobi the greedy rounds; a colour at a time the CPU's: physicsColourWinKernel, ...TakeKernel.)
        let greedy = flat != 0
        for round in 0..<(greedy ? PhysicsGPU.greedyRounds : PhysicsWorld.maxRounds) {
            var r = UInt32(round)
            for kernel in greedy ? [Kernel.physicsColourPick, .physicsColourCommit] : [.physicsColourWin, .physicsColourTake] {
                enc.setComputePipelineState(pipelines[kernel])
                enc.setBytes(&r, length: 4, index: 6)
                barrier(enc)
                enc.dispatchThreadgroups(indirectBuffer: colourWork, indirectBufferOffset: args, threadsPerThreadgroup: width)
            }
        }
        enc.setComputePipelineState(pipelines[.physicsColourCount])
        barrier(enc)
        enc.dispatchThreadgroups(indirectBuffer: colourWork, indirectBufferOffset: args, threadsPerThreadgroup: width)
        enc.setComputePipelineState(pipelines[.physicsColourStarts])
        enc.setBuffer(colouring, offset: 0, index: 7)
        enc.setBytes(&flat, length: 4, index: 10)
        dispatch(enc, pipelines[.physicsColourStarts], 1)
        enc.setComputePipelineState(pipelines[.physicsColourScatter])
        enc.setBuffer(order, offset: 0, index: 8)
        barrier(enc)
        enc.dispatchThreadgroups(indirectBuffer: colourWork, indirectBufferOffset: args, threadsPerThreadgroup: width)
        guard flat == 0 else { return }
        let extra = pipelines[.physicsColourExtra]
        enc.setComputePipelineState(extra)
        barrier(enc)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(extra.maxTotalThreadsPerThreadgroup, 1024), height: 1, depth: 1))
    }

    /// Run `group` of the step's substeps in one threadgroup (Physics.metal's physicsSubstepsKernel).
    private func encodeSubsteps(_ enc: ComputePass, pipelines: Pipelines, group: Int, slot: Int) {
        if wide && group == 0 {
            part("phys colour")
            encodeColours(enc, pipelines: pipelines, slot: slot)
            encodeNarrowArgs(enc, pipelines: pipelines, which: PhysicsGPU.narrowSolved)   // (the refreshes')
        }
        part("phys substeps")
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
        enc.setBuffer(tables, offset: 0, index: 28)
        enc.setBuffer(flesh, offset: 0, index: 30)
        enc.setBuffer(sleepState, offset: 0, index: 29)
        if wideSteps {
            encodeWideSubsteps(enc, pipelines: pipelines, group: group)
            return
        }
        let lanes = substeps.threadExecutionWidth
        let width = min(substeps.maxTotalThreadsPerThreadgroup / lanes * lanes, (max(count, worldParticles) + lanes - 1) / lanes * lanes)
        barrier(enc)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// The colours encodeWideSubsteps dispatches across the GPU (MSL PHYS_WIDE_COLOURS, PHYS_WIDE_EXTRA).
    package enum PhysicsWideColours { static let rounds = 10, extra = 4 }

    /// `group` of the step's substeps across the GPU (Physics.metal's physicsWide*Kernel; physicsSubstepsKernel's stages,
    /// with the substeps' buffers bound): the step's first poses, each substep's integration, its colours' pushes, the
    /// rest, the velocities, the colours' kicks, the rest; after the last, the settling by the substeps' kernel.
    private func encodeWideSubsteps(_ enc: ComputePass, pipelines: Pipelines, group: Int) {
        let run = runs[group], width = MTLSize(width: 64, height: 1, depth: 1), colours = 2 * PhysicsWorld.maxColours
        let jacobi = PhysicsGPU.jacobi
        if group == 0 {
            enc.setComputePipelineState(pipelines[.physicsWideArgs])
            enc.setBuffer(wideArgs, offset: 0, index: 13)
            dispatch(enc, pipelines[.physicsWideArgs], colours + 3)
            enc.setComputePipelineState(pipelines[.physicsWideStart])
            dispatch(enc, pipelines[.physicsWideStart], count)
            if jacobi { encodeTouches(enc, pipelines: pipelines) }
        }
        // (The big colours across the GPU, the rest and the leftovers by one threadgroup: Physics.metal's PHYS_WIDE_COLOURS.)
        // (By Jacobi, no extra colours: what the rounds leave is the tail's.)
        let wideColours = Array(0..<PhysicsWideColours.rounds) + (jacobi ? [] : Array(PhysicsWorld.maxColours..<(PhysicsWorld.maxColours + PhysicsWideColours.extra)))
        let tail = pipelines[.physicsWideTail]
        func each(_ kernel: Kernel, kicks: UInt32, tail withTail: Bool = true) {
            enc.setComputePipelineState(pipelines[kernel])
            for c in wideColours {
                var colour = UInt32(c)
                enc.setBytes(&colour, length: 4, index: 12)
                barrier(enc)
                enc.dispatchThreadgroups(indirectBuffer: wideArgs, indirectBufferOffset: 12 * c, threadsPerThreadgroup: width)
            }
            guard withTail else { return }
            var which = kicks
            enc.setComputePipelineState(tail)
            enc.setBytes(&which, length: 4, index: 12)
            barrier(enc)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: min(tail.maxTotalThreadsPerThreadgroup / 32 * 32, 1024), height: 1, depth: 1))
        }
        func links(damp: Bool) {   // (the tail's loose links alone: MSL physicsWideTailKernel's `colour` 2, 3)
            var which = UInt32(damp ? 2 : 3)
            enc.setComputePipelineState(tail)
            enc.setBytes(&which, length: 4, index: 12)
            barrier(enc)
            enc.dispatchThreadgroups(indirectBuffer: wideArgs, indirectBufferOffset: 12 * (colours + 2),   // (none: no links)
                                     threadsPerThreadgroup: MTLSize(width: min(tail.maxTotalThreadsPerThreadgroup / 32 * 32, 1024), height: 1, depth: 1))
        }
        func joints(_ damp: UInt32) {
            var which = damp
            enc.setComputePipelineState(pipelines[.physicsWideJoints])
            enc.setBytes(&which, length: 4, index: 12)
            for var range in jointRuns where range.y > range.x {
                enc.setBytes(&range, length: 8, index: 11)
                dispatch(enc, pipelines[.physicsWideJoints], Int(range.y - range.x))
            }
        }
        for s in 0..<Int(run.count) {
            var substep = run.first + UInt32(s)
            enc.setComputePipelineState(pipelines[.physicsWideIntegrate])
            enc.setBytes(&substep, length: 4, index: 8)
            dispatch(enc, pipelines[.physicsWideIntegrate], count)
            for _ in 0..<PhysicsWorld.jointIterations { joints(0) }
            each(.physicsWidePush, kicks: 0, tail: !jacobi)
            if jacobi {
                // (The tail's pushes, and each body's share of them; the links; then the velocities, every pair's
                // kicks from them, each body's share of those it is in; the links' damping.)
                func apply(_ phase: UInt32) {
                    var phase = phase
                    enc.setComputePipelineState(pipelines[.physicsJacobiApply])
                    enc.setBytes(&phase, length: 4, index: 12)
                    dispatch(enc, pipelines[.physicsJacobiApply], count)
                }
                enc.setComputePipelineState(pipelines[.physicsJacobiPush])
                barrier(enc)
                enc.dispatchThreadgroups(indirectBuffer: wideArgs, indirectBufferOffset: 12 * (colours + 1), threadsPerThreadgroup: width)
                apply(0)
                if loose { links(damp: false) }
                enc.setComputePipelineState(pipelines[.physicsJacobiKick])
                barrier(enc)
                enc.dispatchThreadgroups(indirectBuffer: wideArgs, indirectBufferOffset: 12 * colours, threadsPerThreadgroup: width)
                apply(1)
                if loose { links(damp: true) }
            } else {
                enc.setComputePipelineState(pipelines[.physicsWideVelocities])
                dispatch(enc, pipelines[.physicsWideVelocities], count)
                each(.physicsWideKick, kicks: 1)
            }
            joints(1)
        }
        guard run.last != 0 else { return }
        let substeps = pipelines[.physicsSubsteps]
        enc.setComputePipelineState(substeps)
        enc.setBuffer(groups, offset: groupCount * MemoryLayout<Group>.stride, index: 8)
        let lanes = substeps.threadExecutionWidth
        let threads = min(substeps.maxTotalThreadsPerThreadgroup / lanes * lanes, (count + lanes - 1) / lanes * lanes)
        barrier(enc)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
    }

    /// Per body the step's coloured pairs that touch it, in entry order (MSL physicsTouch*Kernel): counted, their runs'
    /// starts, scattered, each run sorted. The kicks' sums then come in one order whatever the GPU's.
    private func encodeTouches(_ enc: ComputePass, pipelines: Pipelines) {
        let width = MTLSize(width: 64, height: 1, depth: 1), solved = 12 * 2 * PhysicsWorld.maxColours
        for kernel in [Kernel.physicsTouchCount, .physicsTouchStarts, .physicsTouchScatter, .physicsTouchSort] {
            let state = pipelines[kernel]
            enc.setComputePipelineState(state)
            switch kernel {
            case .physicsTouchStarts:
                barrier(enc)
                enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: min(state.maxTotalThreadsPerThreadgroup / 32 * 32, 1024), height: 1, depth: 1))
            case .physicsTouchSort:
                dispatch(enc, state, count)
            default:
                barrier(enc)
                enc.dispatchThreadgroups(indirectBuffer: wideArgs, indirectBufferOffset: solved, threadsPerThreadgroup: width)
            }
        }
    }

    /// The frame's instance records (and descriptors, `descriptorStride` > 0) from the bodies, and slot `slot`'s snapshot.
    package func encodePose(_ enc: ComputePass, pipelines: Pipelines, slot: Int, instances: MTLBuffer, descriptors: MTLBuffer?,
                    descriptorStride: Int) {
        guard !empty else { return }
        var p = PoseParams(bodies: UInt32(count), descriptorStride: descriptors == nil ? 0 : UInt32(descriptorStride))
        let pose = pipelines[fractures ? .physicsFracturePose : .physicsPose]
        enc.setComputePipelineState(pose)
        enc.setBytes(&p, length: MemoryLayout<PoseParams>.stride, index: 0)
        enc.setBuffer(bodies, offset: 0, index: 1)
        enc.setBuffer(shapes, offset: 0, index: 2)
        enc.setBuffer(lastPose, offset: 0, index: 3)
        enc.setBuffer(snapshots[slot], offset: 0, index: 4)
        enc.setBuffer(instances, offset: 0, index: 5)
        enc.setBuffer(descriptors ?? instances, offset: 0, index: 6)
        enc.setBuffer(fractureState, offset: 0, index: 7)
        dispatch(enc, pose, count)
        if let cars {
            barrier(enc)
            cars.encodeTelemetry(enc, pipelines: pipelines, slot: slot) { barrier(enc) }
        }
        guard worldParticles > 0 else { return }
        var q = PoseParams(bodies: UInt32(worldParticles), descriptorStride: p.descriptorStride)
        enc.setComputePipelineState(pipelines[.physicsParticlePose])
        enc.setBytes(&q, length: MemoryLayout<PoseParams>.stride, index: 0)
        enc.setBuffer(particles[0], offset: 0, index: 1)
        enc.setBuffer(lastParticle, offset: 0, index: 2)
        enc.setBuffer(instances, offset: 0, index: 3)
        enc.setBuffer(descriptors ?? instances, offset: 0, index: 4)
        dispatch(enc, pipelines[.physicsParticlePose], worldParticles)
    }

    /// The CPU's particles for slot `slot`'s frame (when the CPU steps them): what the cloths are drawn from. And which
    /// cars are still (`stillCars`).
    package func upload(slot: Int, _ drawn: PhysicsStepper.Drawn) {
        if !uploads.isEmpty {
            drawn.particles.withUnsafeBytes { uploads[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            if world.hasCars { noteStillCars(drawn.particles) }
        }
        if !hairUploads.isEmpty {
            drawn.hairVertices.withUnsafeBytes { hairUploads[slot].vertices.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            drawn.bodies.withUnsafeBytes {
                if !$0.isEmpty { hairUploads[slot].bodies.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
        }
        if !bodyUploads.isEmpty {
            drawn.bodies.withUnsafeBytes { bodyUploads[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
    }

    /// The cloths' vertices (and last frame's) and normals into the scene's vertex buffers, ahead of the refits.
    package func encodeClothMesh(_ enc: ComputePass, pipelines: Pipelines, slot: Int, positions: MTLBuffer, normals: MTLBuffer) {
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

    /// The soft bodies' drawn vertices (and last frame's) and normals into the scene's vertex buffers, ahead of the refits;
    /// the cars' vertices' damage into `damage` (one uchar4 a vertex of the scene's: SceneBuffers.damage, there when the
    /// world has cars).
    package func encodeSoftMesh(_ enc: ComputePass, pipelines: Pipelines, slot: Int, positions: MTLBuffer, normals: MTLBuffer, damage: MTLBuffer? = nil) {
        guard hasSoftBodies else { return }
        precondition(damage != nil || !world.hasCars, "a world with cars and no damage buffer")
        // (A still car's vertices are where its last frame put them, a hidden model's wait: only the rest's. A model
        // just shown twice, so that its last frame's positions are its own.)
        var ranges: [SIMD2<UInt32>] = [], next = 0
        for s in carSurfaces {
            let body = Int(s.w), fresh = freshSoftBodies.contains(body)
            guard fresh || stillCars.contains(Int(s.x)) || dormantSoftBodies.contains(body) else { continue }
            if Int(s.y) > next { ranges.append(SIMD2(UInt32(next), UInt32(Int(s.y) - next))) }
            if fresh { ranges += [SIMD2(UInt32(s.y), UInt32(s.z)), SIMD2(UInt32(s.y), UInt32(s.z))] }
            next = Int(s.y + s.z)
        }
        if world.softVertices.count > next { ranges.append(SIMD2(UInt32(next), UInt32(world.softVertices.count - next))) }
        guard !ranges.isEmpty else { return }
        enc.setComputePipelineState(pipelines[.physicsSoftMesh])
        enc.setBuffer(simulates ? particles[0] : uploads[slot], offset: 0, index: 1)
        enc.setBuffer(softVertices, offset: 0, index: 2)
        enc.setBuffer(positions, offset: 0, index: 3)
        enc.setBuffer(softEmbeds, offset: 0, index: 4)
        enc.setBuffer(simulates ? bodies : bodyUploads.isEmpty ? bodies : bodyUploads[slot], offset: 0, index: 5)
        enc.setBuffer(damage ?? positions, offset: 0, index: 6)   // (no car's vertex writes to it without cars)
        for var r in ranges {
            enc.setBytes(&r, length: 8, index: 0)
            dispatch(enc, pipelines[.physicsSoftMesh], Int(r.y))
        }
        enc.setComputePipelineState(pipelines[.physicsSoftNormals])
        enc.setBuffer(softVertices, offset: 0, index: 1)
        enc.setBuffer(softRings, offset: 0, index: 2)
        enc.setBuffer(normals, offset: 0, index: 4)
        for var r in ranges {
            enc.setBytes(&r, length: 8, index: 0)
            dispatch(enc, pipelines[.physicsSoftNormals], Int(r.y))
        }
    }

    /// The cars whose panels stay as they were drawn this frame (their nodes within `stillReach` of where they were
    /// when their panels were last drawn, their damage and breaks the same, for two frames: the second leaves their
    /// last-frame positions where they are, for the motion vectors). The CPU's cars only (`simulates`: none).
    package private(set) var stillCars: Set<Int> = []
    /// The cars' panels (soft bodies) not drawn this frame (each car's other model: Scene.updateCarDetail), and those
    /// just shown.
    package var dormantSoftBodies: Set<Int> = []
    package var freshSoftBodies: Set<Int> = []
    /// The cars' ranges and frame nodes, and their drawn panels (PhysicsWorld.carSurfaces), as the world was finished:
    /// read on the frame's thread while an async step may have the car system lent out (withCarBuffers leaves it
    /// empty meanwhile, and a frame that read it then forgot every car's still state).
    private let carStates: [CarState]
    private let carSurfaces: [SIMD4<Int32>]
    private var carReference: [[SIMD4<Float>]] = [], carSettled: [Int] = []
    package static let stillReach: Float = 2e-4

    /// The soft bodies (Scene.softMeshes' indices) whose structures want building again, one a frame (`nextRebuild`): a
    /// car's panels once it has come apart. Refitted, a structure keeps the tree it was built with, and after a crash
    /// (a door and a wheel flung off, the front folded) its boxes had grown over everything: the brick wall's frame at
    /// 3 s was 58 ms, its rays 33 ms of it; built again every frame they were 9, but a build is 11 ms a car.
    private var rebuildQueue: [Int] = []
    /// Per car the volume of its nodes' box in its own frame when its structures were last built, and the frames since;
    /// at first the size they were built at with the scene (as the world began: a frame that starts later, a still at
    /// 3 s or a jump in time, sees a car already crushed, and taken as its first size it was never built again).
    private var carBuiltSize: [Float] = [], carSinceBuild: [Int] = []
    private let carRestSize: [Float]
    /// How far a car's box (in its own frame: its turning doesn't count) grows or shrinks before its structures are
    /// built again, and how many frames apart at least (a part still flying isn't rebuilt every frame).
    package static let rebuildGrowth: Float = 1.5, rebuildFrames = 30

    /// The soft body whose structure to build again this frame, if any.
    package func nextRebuild() -> Int? {
        while let body = rebuildQueue.first {
            rebuildQueue.removeFirst()
            if !dormantSoftBodies.contains(body) { return body }
        }
        return nil
    }

    private func noteStillCars(_ particles: [GPUPhysicsParticle]) {
        let cars = carStates
        if carReference.count != cars.count {
            carReference = [[SIMD4<Float>]](repeating: [], count: cars.count)
            carSettled = [Int](repeating: 0, count: cars.count)
            carBuiltSize = carRestSize
            carSinceBuild = [Int](repeating: PhysicsGPU.rebuildFrames, count: cars.count)
        }
        stillCars = []
        for (c, car) in cars.enumerated() {
            let first = Int(car.firstNode), n = Int(car.nodeCount)
            // Come apart: its box in its own frame grown or shrunk past `rebuildGrowth` since its last build.
            let size = PhysicsGPU.carSize(car, particles)
            carSinceBuild[c] += 1
            let change = max(size / carBuiltSize[c], carBuiltSize[c] / size)
            if change > PhysicsGPU.rebuildGrowth && carSinceBuild[c] >= PhysicsGPU.rebuildFrames {
                for s in carSurfaces where Int(s.x) == c && !rebuildQueue.contains(Int(s.w)) { rebuildQueue.append(Int(s.w)) }
                carBuiltSize[c] = size
                carSinceBuild[c] = 0
            }
            var moved = carReference[c].count != n
            if !moved {
                for k in 0..<n {
                    let p = particles[first + k], r = carReference[c][k]
                    if p.info.z != r.w.bitPattern || simd_reduce_max(simd_abs(PhysicsMath.xyz(p.position) - PhysicsMath.xyz(r))) > PhysicsGPU.stillReach {
                        moved = true
                        break
                    }
                }
            }
            carSettled[c] = moved ? 0 : carSettled[c] + 1
            if carSettled[c] >= 2 {
                stillCars.insert(c)
            } else {
                carReference[c] = (first..<(first + n)).map { SIMD4(PhysicsMath.xyz(particles[$0].position), Float(bitPattern: particles[$0].info.z)) }
            }
        }
    }

    /// The volume of car `car`'s nodes' box in its own frame (its turning doesn't count; 0.3 m a side at least).
    private static func carSize(_ car: CarState, _ particles: [GPUPhysicsParticle]) -> Float {
        let first = Int(car.firstNode), f = PhysicsWorld.carFrame(car, particles)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for k in first..<(first + Int(car.nodeCount)) {
            let d = PhysicsMath.xyz(particles[k].position) - f.centre, q = SIMD3(dot(d, f.left), dot(d, f.up), dot(d, f.forward))
            lo = simd_min(lo, q)
            hi = simd_max(hi, q)
        }
        let e = simd_max(hi - lo, SIMD3(repeating: 0.3))
        return e.x * e.y * e.z
    }

    /// The soft bodies (Scene.softMeshes' indices) still this frame: the still cars' panels, whose structures stay.
    package var stillSoftBodies: [Int] { carSurfaces.filter { stillCars.contains(Int($0.x)) }.map { Int($0.w) } }

    /// The liquids' surfaces into the scene's vertex and index buffers, ahead of the structures' builds.
    package func encodeFluidSurfaces(_ enc: ComputePass, pipelines: Pipelines, positions: MTLBuffer, normals: MTLBuffer, indices: MTLBuffer) {
        fluid?.encodeSurfaces(enc, pipelines: pipelines, positions: positions, normals: normals, indices: indices)
    }
    package var hasFluid: Bool { fluid != nil }
    /// The frames its liquids' surfaces are still made for (the renderer's count): some more after the last step or
    /// reset, as the structure built over one takes its size from a count read back a few frames late.
    package var liquidFrames = GPUFrames.maxInFlight + 1

    /// The flesh's buffer as the GPU has it (tests: its clock, the muscles' activations).
    package func readFlesh() -> [SIMD4<UInt32>] {
        let n = flesh.length / 16
        return Array(UnsafeBufferPointer(start: flesh.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: n), count: n))
    }

    /// The particles as the GPU has them (tests).
    package func readParticles() -> [GPUPhysicsParticle] {
        Array(UnsafeBufferPointer(start: particles[0].contents().bindMemory(to: GPUPhysicsParticle.self, capacity: particleCount),
                                  count: particleCount))
    }

    // MARK: - Reading back

    /// Slot `slot`'s poses (position, rotation per body), from when its frame was done.
    /// Slot `slot`'s cars as the GPU's steps left them (its frame must be done): the steps it had run, each car's
    /// telemetry. Nil without cars on the GPU.
    package func carTelemetry(slot: Int) -> (step: Int, cars: [CarTelemetry])? { cars?.telemetry(slot: slot) }

    package func snapshot(slot: Int) -> UnsafeBufferPointer<SIMD4<Float>> {
        UnsafeBufferPointer(start: snapshots[slot].contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * count), count: 2 * count)
    }

    /// The bodies as the GPU has them (the work that wrote them must be done): tests and the check.
    package func readBodies() -> [GPUPhysicsBody] {
        Array(UnsafeBufferPointer(start: bodies.contents().bindMemory(to: GPUPhysicsBody.self, capacity: count), count: count))
    }
}
