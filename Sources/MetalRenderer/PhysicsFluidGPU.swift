import Metal
import simd

/// The liquids on the GPU (Shaders/Fluid.metal): each liquid's buffers, its group of substeps encoded before each of
/// the bodies' groups (PhysicsGPU.encodeSteps), and the impulses the liquids gave the bodies applied after them. Written
/// once, like the physics' own buffers: a group sets no bytes. The CPU counts the groups too (the GPU's clock is its
/// own), only to size the dispatches to what is poured.
final class FluidGPU {
    /// The physics' buffers the liquids read: its parameters, bodies, statics and their boxes, shapes and the SDF scene.
    struct World {
        var params: MTLBuffer
        var bodies: MTLBuffer
        var statics: MTLBuffer
        var staticBounds: MTLBuffer
        var shapes: MTLBuffer
        var samples: MTLBuffer
        var sdfScene: MTLBuffer
    }

    /// A liquid's buffers. PBF: two of its particles and predicted positions (the sort reads one and writes the other),
    /// its cells' counts, starts (n + 1) and cursors, the particles' cells, order, neighbours (FLUID_NEIGHBOURS_MOST
    /// each, the first of every particle's then the second ...) and how many, their lambdas. MPM: its grid, and
    /// its blocks' counts, starts and cursors and the particles' blocks and order (fluidMpmP2GKernel).
    final class System {
        let system: FluidSystem
        let params: MTLBuffer
        let state: MTLBuffer
        let particles: [MTLBuffer]
        let layer: MTLBuffer
        let statics: MTLBuffer
        let predicted: [MTLBuffer]
        let keys: MTLBuffer
        let cells: MTLBuffer?
        let counts: MTLBuffer
        let starts: MTLBuffer
        let cursor: MTLBuffer
        let order: MTLBuffer
        let neighbours: MTLBuffer?
        let neighbourCounts: MTLBuffer?
        let lambdas: MTLBuffer?
        let grid: MTLBuffer?
        /// What the sort puts the particles in (PBF: cells; MPM: blocks), the scan's block totals and its size (uint4:
        /// x = elements).
        let bins: Int
        let partials: MTLBuffer
        let scanSize: MTLBuffer
        /// The surface (FluidSurface.swift): its parameters, the splat (ints), the field (twice: the blur goes back and
        /// forth), per node its cell's vertex and its edges' quads, their scans, the scan's block totals and size, and
        /// what the last surface needed (uint4: vertices, triangles, whether it ran out).
        let surface: MTLBuffer
        let density: MTLBuffer
        let field: [MTLBuffer]
        let vertexCounts: MTLBuffer
        let quadCounts: MTLBuffer
        let vertexAt: MTLBuffer
        let quadAt: MTLBuffer
        let surfacePartials: MTLBuffer
        let surfaceSize: MTLBuffer
        let stats: MTLBuffer

        init(_ s: FluidSystem, buffer: (Int, String) throws -> MTLBuffer) throws {
            system = s
            let n = s.capacity, cellCount = Int(s.params.dims.w), name = s.kind.name
            params = try buffer(MemoryLayout<GPUFluidParams>.stride, "fluidParams.\(name)")
            params.contents().storeBytes(of: s.params, as: GPUFluidParams.self)
            state = try buffer(16 + 4 * FluidWorld.maxBodies, "fluidState.\(name)")
            let pbf = s.solver == .pbf
            particles = try (0..<(pbf ? 2 : 1)).map { try buffer(n * MemoryLayout<GPUFluidParticle>.stride, "fluidParticles\($0).\(name)") }
            let layer = try buffer(s.layer.count * 16, "fluidLayer.\(name)")
            s.layer.withUnsafeBytes { layer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            self.layer = layer
            let statics = try buffer(max(s.statics.count, 1) * 4, "fluidStatics.\(name)")
            s.statics.withUnsafeBytes { if !$0.isEmpty { statics.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
            self.statics = statics
            predicted = pbf ? try (0..<2).map { try buffer(n * 16, "fluidPredicted\($0).\(name)") } : []
            let blocks = s.mpmBlocks
            bins = pbf ? cellCount : blocks.x * blocks.y * blocks.z
            keys = try buffer(n * 4, "fluidKeys.\(name)")
            cells = pbf ? try buffer(n * 4, "fluidCells.\(name)") : nil
            counts = try buffer((bins + 1) * 4, "fluidCounts.\(name)")
            starts = try buffer((bins + 1) * 4, "fluidStarts.\(name)")
            cursor = try buffer((bins + 1) * 4, "fluidCursor.\(name)")
            order = try buffer(n * 4, "fluidOrder.\(name)")
            neighbours = pbf ? try buffer(n * PhysicsWorld.fluidNeighboursMost * 4, "fluidNeighbours.\(name)") : nil
            neighbourCounts = pbf ? try buffer(n * 4, "fluidNeighbourCounts.\(name)") : nil
            lambdas = pbf ? try buffer(n * 4, "fluidLambdas.\(name)") : nil
            grid = pbf ? nil : try buffer(cellCount * 16, "fluidGrid.\(name)")
            precondition(bins <= 4096 * 1024, "a liquid's grid has more cells than the scan takes")
            partials = try buffer((bins + 1023) / 1024 * 4, "fluidPartials.\(name)")
            scanSize = try buffer(16, "fluidScanSize.\(name)")
            scanSize.contents().storeBytes(of: SIMD4<UInt32>(UInt32(bins), 0, 0, 0), as: SIMD4<UInt32>.self)
            let nodes = Int(s.surface.dims.w)
            precondition(nodes <= 4096 * 1024, "a liquid's surface grid has more nodes than the scan takes")
            surface = try buffer(MemoryLayout<GPUFluidSurface>.stride, "fluidSurface.\(name)")
            surface.contents().storeBytes(of: s.surface, as: GPUFluidSurface.self)
            density = try buffer(nodes * 4, "fluidDensity.\(name)")
            field = try (0..<2).map { try buffer(nodes * 4, "fluidField\($0).\(name)") }
            vertexCounts = try buffer(nodes * 4, "fluidVertexCounts.\(name)")
            quadCounts = try buffer(nodes * 4, "fluidQuadCounts.\(name)")
            vertexAt = try buffer((nodes + 1) * 4, "fluidVertexAt.\(name)")
            quadAt = try buffer((nodes + 1) * 4, "fluidQuadAt.\(name)")
            surfacePartials = try buffer((nodes + 1023) / 1024 * 4, "fluidSurfacePartials.\(name)")
            surfaceSize = try buffer(16, "fluidSurfaceSize.\(name)")
            surfaceSize.contents().storeBytes(of: SIMD4<UInt32>(UInt32(nodes), 0, 0, 0), as: SIMD4<UInt32>.self)
            stats = try buffer(16, "fluidSurfaceStats.\(name)")
        }
    }

    let systems: [System]
    /// Per body, the liquids' impulses this group (8 ints: linear, angular).
    let impulses: MTLBuffer
    /// FluidWorld.drops: a uint4 (x = how many), then (body, tick) pairs.
    private let drops: MTLBuffer
    private let world: World
    private let bodyCount: Int
    /// The groups encoded since the start (the GPU's clock as the CPU counts it): what is poured by each.
    private var clock: UInt32 = 0

    init(device: MTLDevice, fluid: FluidWorld, bodies: Int, world: World) throws {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 256), options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            memset(b.contents(), 0, b.length)
            b.label = label
            return b
        }
        systems = try fluid.systems.map { try System($0, buffer: buffer) }
        impulses = try buffer(bodies * 32, "fluidImpulses")
        let drops = try buffer(16 + fluid.drops.count * 8, "fluidDrops")
        drops.contents().storeBytes(of: SIMD4<UInt32>(UInt32(fluid.drops.count), 0, 0, 0), as: SIMD4<UInt32>.self)
        fluid.drops.withUnsafeBytes { if !$0.isEmpty { (drops.contents() + 16).copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        self.drops = drops
        self.world = world
        bodyCount = bodies
    }

    /// The pass runs its dispatches together (PhysicsGPU.concurrent): the liquids' steps go side by side, a barrier
    /// between each and the next.
    var concurrent = false

    /// One of a liquid's dispatches: it binds what its kernel reads (the encoder holds the last liquid's), then dispatches.
    private typealias Step = (ComputePass) -> Void

    private func dispatch(_ enc: ComputePass, _ state: MTLComputePipelineState, _ threads: Int) {
        let width = min(state.threadExecutionWidth, max(threads, 1))
        enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Each liquid's steps in turn, the liquids side by side: every liquid's first, a barrier, every liquid's second, ...
    /// A liquid's run in order (in a serial pass too), and the liquids share only the bodies' impulses, which they add
    /// as integers: the same in any order. On the M1 Max a step is 20 µs however few particles, mostly waiting for the
    /// one before it; side by side, three liquids take little more than one.
    private func run(_ enc: ComputePass, _ lists: [[Step]]) {
        for k in 0..<(lists.map(\.count).max() ?? 0) {
            if concurrent { enc.memoryBarrier(scope: .buffers) }
            for list in lists where k < list.count { list[k](enc) }
        }
    }

    /// A liquid's steps from its bindings: `add` appends a kernel's dispatch over `count` threads (or `count`
    /// threadgroups of `group` threads), with what `set` binds over the bindings.
    private struct Steps {
        let pipelines: Pipelines
        let bind: Step
        let dispatch: (ComputePass, MTLComputePipelineState, Int) -> Void
        var list: [Step] = []

        mutating func add(_ kernel: Kernel, _ count: Int, group: Int = 0, _ set: Step? = nil) {
            let state = pipelines[kernel], bind = bind, dispatch = dispatch
            list.append { enc in
                bind(enc)
                set?(enc)
                enc.setComputePipelineState(state)
                if group > 0 {
                    enc.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: group, height: 1, depth: 1))
                } else {
                    dispatch(enc, state, count)
                }
            }
        }

        /// An exclusive prefix sum of the `count` uints bound at 8 into 9 (the total after them), with the block
        /// totals at 15 and the size at 16.
        mutating func scan(_ count: Int, _ set: Step? = nil) {
            add(.fluidScanBlocks, (count + 1023) / 1024, group: 256, set)
            add(.fluidScanTop, 1, group: 256, set)
            add(.fluidScanAdd, count, set)
        }
    }

    /// Every liquid back to its start: nothing poured, the clock at 0.
    func encodeReset(_ enc: ComputePass, pipelines: Pipelines) {
        let reset = pipelines[.fluidReset]
        run(enc, systems.map { s in
            [{ enc in
                enc.setBuffer(s.state, offset: 0, index: 1)
                enc.setComputePipelineState(reset)
                self.dispatch(enc, reset, 1)
            }]
        })
        clock = 0
    }

    /// One group: every liquid's start, pour and substeps, then the bodies' impulses applied. Leaves buffer 0 as it
    /// found it (the physics' parameters, which its kernels read there).
    func encodeGroup(_ enc: ComputePass, pipelines: Pipelines) {
        run(enc, systems.map { groupSteps($0, pipelines: pipelines) })
        clock += 1
        if let first = systems.first, bodyCount > 0 {
            if concurrent { enc.memoryBarrier(scope: .buffers) }
            enc.setComputePipelineState(pipelines[.fluidApply])
            enc.setBuffer(first.params, offset: 0, index: 0)
            enc.setBuffer(first.state, offset: 0, index: 1)
            enc.setBuffer(drops, offset: 0, index: 2)
            enc.setBuffer(world.params, offset: 0, index: 19)
            enc.setBuffer(world.bodies, offset: 0, index: 20)
            enc.setBuffer(impulses, offset: 0, index: 27)
            dispatch(enc, pipelines[.fluidApply], bodyCount)
        }
        enc.setBuffer(world.params, offset: 0, index: 0)
    }

    /// Liquid `s`'s steps in a group: its start, its pour, its substeps.
    private func groupSteps(_ s: System, pipelines: Pipelines) -> [Step] {
        let p = s.system.params, pbf = s.system.solver == .pbf
        // The most there can be by now: what the clock has poured (the GPU counts the same).
        let active = FluidSystem.poured(p, clock: clock)
        let world = world, impulses = impulses
        var steps = Steps(pipelines: pipelines, bind: { enc in
            enc.setBuffer(s.params, offset: 0, index: 0)
            enc.setBuffer(s.state, offset: 0, index: 1)
            enc.setBuffer(s.particles[0], offset: 0, index: 2)
            enc.setBuffer(s.keys, offset: 0, index: 6)
            enc.setBuffer(s.counts, offset: 0, index: 8)
            enc.setBuffer(s.starts, offset: 0, index: 9)
            enc.setBuffer(s.cursor, offset: 0, index: 10)
            enc.setBuffer(s.order, offset: 0, index: 11)
            enc.setBuffer(s.partials, offset: 0, index: 15)
            enc.setBuffer(s.scanSize, offset: 0, index: 16)
            if pbf {
                enc.setBuffer(s.particles[1], offset: 0, index: 3)
                enc.setBuffer(s.predicted[0], offset: 0, index: 4)
                enc.setBuffer(s.predicted[1], offset: 0, index: 5)
                enc.setBuffer(s.cells, offset: 0, index: 7)
                enc.setBuffer(s.lambdas, offset: 0, index: 12)
                enc.setBuffer(s.neighbours, offset: 0, index: 13)
                enc.setBuffer(s.neighbourCounts, offset: 0, index: 17)
            } else {
                enc.setBuffer(s.grid, offset: 0, index: 14)
            }
            enc.setBuffer(world.params, offset: 0, index: 19)
            enc.setBuffer(world.bodies, offset: 0, index: 20)
            enc.setBuffer(world.statics, offset: 0, index: 21)
            enc.setBuffer(world.staticBounds, offset: 0, index: 22)
            enc.setBuffer(world.shapes, offset: 0, index: 23)
            enc.setBuffer(world.samples, offset: 0, index: 24)
            enc.setBuffer(world.sdfScene, offset: 0, index: 25)
            enc.setBuffer(s.statics, offset: 0, index: 26)
            enc.setBuffer(impulses, offset: 0, index: 27)
        }, dispatch: dispatch)
        steps.add(.fluidBegin, 1)
        steps.add(.fluidPour, s.system.mostPouredInAGroup) { $0.setBuffer(s.layer, offset: 0, index: 13) }
        guard active > 0 else { return steps.list }
        // The particles sorted by the cell (PBF) or block (MPM) their key says, into `order`: counted, the counts'
        // exclusive prefix sum (the starts), then scattered (in any order within one).
        func sort() {
            steps.add(.fluidCellsClear, s.bins + 1)
            steps.add(.fluidCellCount, active)
            steps.scan(s.bins)
            steps.add(.fluidScatter, active)
        }
        let nodes = Int(p.dims.w)
        for _ in 0..<Int(p.counts.y) {
            if !pbf {
                steps.add(.fluidMpmClear, nodes)
                steps.add(.fluidMpmKeys, active)
                sort()
                steps.add(.fluidMpmP2G, s.bins, group: 64)
                steps.add(.fluidMpmGrid, nodes)
                steps.add(.fluidMpmG2P, active)
                continue
            }
            steps.add(.fluidPredict, active)
            sort()
            steps.add(.fluidCellSort, nodes)
            steps.add(.fluidReorder, active)
            // The neighbours, then the iterations, from the sorted predictions (buffer 1) back and forth.
            steps.add(.fluidPbfNeighbours, active) { $0.setBuffer(s.predicted[1], offset: 0, index: 4) }
            var current = 1
            for _ in 0..<Int(p.emission.w) {
                let from = s.predicted[current], to = s.predicted[1 - current]
                let set: Step = { enc in
                    enc.setBuffer(from, offset: 0, index: 4)
                    enc.setBuffer(to, offset: 0, index: 5)
                }
                steps.add(.fluidPbfLambda, active, set)
                steps.add(.fluidPbfDelta, active, set)
                current = 1 - current
            }
            let last = s.predicted[current]
            steps.add(.fluidPbfVelocity, active) { $0.setBuffer(last, offset: 0, index: 4) }
            steps.add(.fluidPbfVorticity, active)
            steps.add(.fluidPbfViscosity, active)
        }
        return steps.list
    }

    // MARK: - The surfaces

    /// Every liquid's surface from where its particles are now, into the scene's vertex and index buffers (FluidSurface.swift).
    func encodeSurfaces(_ enc: ComputePass, pipelines: Pipelines, positions: MTLBuffer, normals: MTLBuffer, indices: MTLBuffer) {
        run(enc, systems.filter { $0.system.surface.mesh.w > 0 }.map {
            surfaceSteps($0, pipelines: pipelines, positions: positions, normals: normals, indices: indices)
        })
    }

    private func surfaceSteps(_ s: System, pipelines: Pipelines, positions: MTLBuffer, normals: MTLBuffer, indices: MTLBuffer) -> [Step] {
        let nodes = Int(s.system.surface.dims.w), active = max(FluidSystem.poured(s.system.params, clock: clock), 1)
        var steps = Steps(pipelines: pipelines, bind: { enc in
            enc.setBuffer(s.surface, offset: 0, index: 0)
            enc.setBuffer(s.state, offset: 0, index: 1)
            enc.setBuffer(s.density, offset: 0, index: 2)
            enc.setBuffer(s.field[0], offset: 0, index: 3)
            enc.setBuffer(s.particles[0], offset: 0, index: 4)
            enc.setBuffer(s.vertexCounts, offset: 0, index: 7)
            enc.setBuffer(s.quadCounts, offset: 0, index: 8)
            enc.setBuffer(s.vertexAt, offset: 0, index: 9)
            enc.setBuffer(positions, offset: 0, index: 10)
            enc.setBuffer(normals, offset: 0, index: 11)
            enc.setBuffer(s.quadAt, offset: 0, index: 12)
            enc.setBuffer(indices, offset: 0, index: 13)
            enc.setBuffer(s.stats, offset: 0, index: 14)
            enc.setBuffer(s.surfacePartials, offset: 0, index: 15)
            enc.setBuffer(s.surfaceSize, offset: 0, index: 16)
        }, dispatch: dispatch)
        steps.add(.fluidSurfaceClear, nodes)
        steps.add(.fluidSurfaceSplat, active)
        // The blur: x from the splat into field 0, y into field 1, z back into field 0.
        for (axis, from, to) in [(0, 1, 0), (1, 0, 1), (2, 1, 0)] {
            let a = s.field[from], b = s.field[to]
            steps.add(.fluidSurfaceBlur, nodes) { enc in
                var pass = SIMD4<UInt32>(UInt32(axis), axis == 0 ? 1 : 0, 0, 0)
                enc.setBuffer(a, offset: 0, index: 3)
                enc.setBuffer(b, offset: 0, index: 5)
                enc.setBytes(&pass, length: 16, index: 6)
            }
        }
        steps.add(.fluidSurfaceCount, nodes)
        // Where each cell's vertex and each node's quads go: the scans of their counts (sharing the block totals).
        steps.scan(nodes) { $0.setBuffer(s.vertexCounts, offset: 0, index: 8) }
        steps.scan(nodes) { enc in
            enc.setBuffer(s.quadCounts, offset: 0, index: 8)
            enc.setBuffer(s.quadAt, offset: 0, index: 9)
        }
        steps.add(.fluidSurfaceVertex, nodes)
        steps.add(.fluidSurfaceQuad, nodes)
        steps.add(.fluidSurfaceTail, Int(s.system.surface.triangles.x))
        return steps.list
    }

    /// Per liquid (as its last frames left it): particles poured, how high they are (median, top), how fast, its surface.
    var summary: String {
        systems.indices.map { s in
            let q = readParticles(s), st = readSurfaceStats(s)
            guard !q.isEmpty else { return "\(systems[s].system.kind.name) none yet" }
            let y = q.map(\.position.y).sorted(), speed = q.map { length(PhysicsMath.xyz($0.velocity)) }.reduce(0, +) / Float(q.count)
            return String(format: "%@ %@ %d, height %.3f (top %.3f), %.2f m/s, surface %d vertices %d triangles%@", systems[s].system.kind.name,
                          systems[s].system.solver == .mpm ? "MPM" : "PBF", q.count, y[y.count / 2], y.last!, speed, st.x, st.y,
                          st.z != 0 ? " (ran out of room)" : "")
        }.joined(separator: "; ")
    }

    /// System `s`'s last surface: its vertices, its triangles, whether it ran out of room (tests, the bench's line).
    func readSurfaceStats(_ s: Int) -> SIMD4<UInt32> { systems[s].stats.contents().load(as: SIMD4<UInt32>.self) }

    // MARK: - Reading back (tests)

    /// System `s`'s state: x = groups run, y = particles poured, z = poured before the last group, w = bodies near.
    func readState(_ s: Int) -> SIMD4<UInt32> { systems[s].state.contents().load(as: SIMD4<UInt32>.self) }

    /// System `s`'s particles poured so far.
    func readParticles(_ s: Int) -> [GPUFluidParticle] {
        let n = Int(readState(s).y)
        return Array(UnsafeBufferPointer(start: systems[s].particles[0].contents().bindMemory(to: GPUFluidParticle.self, capacity: n), count: n))
    }

    /// The bodies' impulse accumulators (8 ints a body).
    func readImpulses() -> [Int32] {
        Array(UnsafeBufferPointer(start: impulses.contents().bindMemory(to: Int32.self, capacity: bodyCount * 8), count: bodyCount * 8))
    }
}
