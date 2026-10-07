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
    /// its cells' counts, starts (n + 1) and cursors, the particles' cells and order, their lambdas. MPM: its grid.
    final class System {
        let system: FluidSystem
        let params: MTLBuffer
        let state: MTLBuffer
        let particles: [MTLBuffer]
        let layer: MTLBuffer
        let statics: MTLBuffer
        let predicted: [MTLBuffer]
        let keys: MTLBuffer?
        let cells: MTLBuffer?
        let counts: MTLBuffer?
        let starts: MTLBuffer?
        let cursor: MTLBuffer?
        let order: MTLBuffer?
        let lambdas: MTLBuffer?
        let grid: MTLBuffer?
        /// The scan's block totals and its size (uint4: x = elements).
        let partials: MTLBuffer?
        let scanSize: MTLBuffer?
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
            keys = pbf ? try buffer(n * 4, "fluidKeys.\(name)") : nil
            cells = pbf ? try buffer(n * 4, "fluidCells.\(name)") : nil
            counts = pbf ? try buffer((cellCount + 1) * 4, "fluidCounts.\(name)") : nil
            starts = pbf ? try buffer((cellCount + 1) * 4, "fluidStarts.\(name)") : nil
            cursor = pbf ? try buffer((cellCount + 1) * 4, "fluidCursor.\(name)") : nil
            order = pbf ? try buffer(n * 4, "fluidOrder.\(name)") : nil
            lambdas = pbf ? try buffer(n * 4, "fluidLambdas.\(name)") : nil
            grid = pbf ? nil : try buffer(cellCount * 16, "fluidGrid.\(name)")
            precondition(cellCount <= 4096 * 1024, "a liquid's grid has more cells than the scan takes")
            partials = pbf ? try buffer((cellCount + 1023) / 1024 * 4, "fluidPartials.\(name)") : nil
            scanSize = pbf ? try buffer(16, "fluidScanSize.\(name)") : nil
            scanSize?.contents().storeBytes(of: SIMD4<UInt32>(UInt32(cellCount), 0, 0, 0), as: SIMD4<UInt32>.self)
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

    private func dispatch(_ enc: ComputePass, _ state: MTLComputePipelineState, _ threads: Int) {
        let width = min(state.threadExecutionWidth, max(threads, 1))
        enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Every liquid back to its start: nothing poured, the clock at 0.
    func encodeReset(_ enc: ComputePass, pipelines: Pipelines) {
        enc.setComputePipelineState(pipelines[.fluidReset])
        for s in systems {
            enc.setBuffer(s.state, offset: 0, index: 1)
            dispatch(enc, pipelines[.fluidReset], 1)
        }
        clock = 0
    }

    private func bindWorld(_ enc: ComputePass, _ s: System) {
        enc.setBuffer(world.params, offset: 0, index: 19)
        enc.setBuffer(world.bodies, offset: 0, index: 20)
        enc.setBuffer(world.statics, offset: 0, index: 21)
        enc.setBuffer(world.staticBounds, offset: 0, index: 22)
        enc.setBuffer(world.shapes, offset: 0, index: 23)
        enc.setBuffer(world.samples, offset: 0, index: 24)
        enc.setBuffer(world.sdfScene, offset: 0, index: 25)
        enc.setBuffer(s.statics, offset: 0, index: 26)
        enc.setBuffer(impulses, offset: 0, index: 27)
    }

    /// One group: every liquid's start, pour and substeps, then the bodies' impulses applied. Leaves buffer 0 as it
    /// found it (the physics' parameters, which its kernels read there).
    func encodeGroup(_ enc: ComputePass, pipelines: Pipelines) {
        for s in systems {
            let p = s.system.params
            // The most there can be by now: what the clock has poured (the GPU counts the same).
            let active = FluidSystem.poured(p, clock: clock)
            enc.setBuffer(s.params, offset: 0, index: 0)
            enc.setBuffer(s.state, offset: 0, index: 1)
            bindWorld(enc, s)
            enc.setComputePipelineState(pipelines[.fluidBegin])
            dispatch(enc, pipelines[.fluidBegin], 1)
            enc.setBuffer(s.particles[0], offset: 0, index: 2)
            enc.setBuffer(s.layer, offset: 0, index: 13)
            enc.setComputePipelineState(pipelines[.fluidPour])
            dispatch(enc, pipelines[.fluidPour], s.system.mostPouredInAGroup)
            guard active > 0 else { continue }
            for _ in 0..<Int(p.counts.y) {
                if s.system.solver == .mpm { encodeMPM(enc, pipelines: pipelines, s, active) } else { encodePBF(enc, pipelines: pipelines, s, active) }
            }
        }
        clock += 1
        guard let first = systems.first, bodyCount > 0 else { return }
        enc.setComputePipelineState(pipelines[.fluidApply])
        enc.setBuffer(first.params, offset: 0, index: 0)
        enc.setBuffer(first.state, offset: 0, index: 1)
        enc.setBuffer(drops, offset: 0, index: 2)
        enc.setBuffer(world.params, offset: 0, index: 19)
        enc.setBuffer(world.bodies, offset: 0, index: 20)
        enc.setBuffer(impulses, offset: 0, index: 27)
        dispatch(enc, pipelines[.fluidApply], bodyCount)
        enc.setBuffer(world.params, offset: 0, index: 0)
    }

    /// An exclusive prefix sum of the system's cell counts into its starts (the total after them).
    private func encodeScan(_ enc: ComputePass, pipelines: Pipelines, _ s: System) {
        encodeScan(enc, pipelines: pipelines, s.counts!, into: s.starts!, partials: s.partials!, size: s.scanSize!,
                   count: Int(s.system.params.dims.w))
    }

    /// An exclusive prefix sum of `count` uints in `input` into `output` (the total at `output[count]`).
    private func encodeScan(_ enc: ComputePass, pipelines: Pipelines, _ input: MTLBuffer, into output: MTLBuffer, partials: MTLBuffer,
                            size: MTLBuffer, count n: Int) {
        let blocks = (n + 1023) / 1024
        enc.setBuffer(size, offset: 0, index: 16)
        enc.setBuffer(input, offset: 0, index: 8)
        enc.setBuffer(output, offset: 0, index: 9)
        enc.setBuffer(partials, offset: 0, index: 15)
        let group = MTLSize(width: 256, height: 1, depth: 1)
        enc.setComputePipelineState(pipelines[.fluidScanBlocks])
        enc.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1), threadsPerThreadgroup: group)
        enc.setComputePipelineState(pipelines[.fluidScanTop])
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: group)
        enc.setComputePipelineState(pipelines[.fluidScanAdd])
        dispatch(enc, pipelines[.fluidScanAdd], n)
    }

    private func encodePBF(_ enc: ComputePass, pipelines: Pipelines, _ s: System, _ active: Int) {
        let cells = Int(s.system.params.dims.w)
        enc.setBuffer(s.particles[0], offset: 0, index: 2)
        enc.setBuffer(s.particles[1], offset: 0, index: 3)
        enc.setBuffer(s.predicted[0], offset: 0, index: 4)
        enc.setBuffer(s.predicted[1], offset: 0, index: 5)
        enc.setBuffer(s.keys, offset: 0, index: 6)
        enc.setBuffer(s.cells, offset: 0, index: 7)
        enc.setBuffer(s.counts, offset: 0, index: 8)
        enc.setBuffer(s.starts, offset: 0, index: 9)
        enc.setBuffer(s.cursor, offset: 0, index: 10)
        enc.setBuffer(s.order, offset: 0, index: 11)
        enc.setBuffer(s.lambdas, offset: 0, index: 12)
        enc.setComputePipelineState(pipelines[.fluidPredict])
        dispatch(enc, pipelines[.fluidPredict], active)
        enc.setComputePipelineState(pipelines[.fluidCellsClear])
        dispatch(enc, pipelines[.fluidCellsClear], cells + 1)
        enc.setComputePipelineState(pipelines[.fluidCellCount])
        dispatch(enc, pipelines[.fluidCellCount], active)
        encodeScan(enc, pipelines: pipelines, s)
        enc.setBuffer(s.counts, offset: 0, index: 8)
        enc.setComputePipelineState(pipelines[.fluidScatter])
        dispatch(enc, pipelines[.fluidScatter], active)
        enc.setComputePipelineState(pipelines[.fluidCellSort])
        dispatch(enc, pipelines[.fluidCellSort], cells)
        enc.setComputePipelineState(pipelines[.fluidReorder])
        dispatch(enc, pipelines[.fluidReorder], active)
        // The iterations, from the sorted predictions (buffer 1) back and forth.
        var current = s.predicted[1], other = s.predicted[0]
        for _ in 0..<Int(s.system.params.emission.w) {
            enc.setBuffer(current, offset: 0, index: 4)
            enc.setBuffer(other, offset: 0, index: 5)
            enc.setComputePipelineState(pipelines[.fluidPbfLambda])
            dispatch(enc, pipelines[.fluidPbfLambda], active)
            enc.setComputePipelineState(pipelines[.fluidPbfDelta])
            dispatch(enc, pipelines[.fluidPbfDelta], active)
            swap(&current, &other)
        }
        enc.setBuffer(current, offset: 0, index: 4)
        enc.setComputePipelineState(pipelines[.fluidPbfVelocity])
        dispatch(enc, pipelines[.fluidPbfVelocity], active)
        enc.setComputePipelineState(pipelines[.fluidPbfVorticity])
        dispatch(enc, pipelines[.fluidPbfVorticity], active)
        enc.setComputePipelineState(pipelines[.fluidPbfViscosity])
        dispatch(enc, pipelines[.fluidPbfViscosity], active)
    }

    private func encodeMPM(_ enc: ComputePass, pipelines: Pipelines, _ s: System, _ active: Int) {
        let nodes = Int(s.system.params.dims.w)
        enc.setBuffer(s.particles[0], offset: 0, index: 2)
        enc.setBuffer(s.grid, offset: 0, index: 14)
        enc.setComputePipelineState(pipelines[.fluidMpmClear])
        dispatch(enc, pipelines[.fluidMpmClear], nodes)
        enc.setComputePipelineState(pipelines[.fluidMpmP2G])
        dispatch(enc, pipelines[.fluidMpmP2G], active)
        enc.setComputePipelineState(pipelines[.fluidMpmGrid])
        dispatch(enc, pipelines[.fluidMpmGrid], nodes)
        enc.setComputePipelineState(pipelines[.fluidMpmG2P])
        dispatch(enc, pipelines[.fluidMpmG2P], active)
    }

    // MARK: - The surfaces

    /// Every liquid's surface from where its particles are now, into the scene's vertex and index buffers (FluidSurface.swift).
    func encodeSurfaces(_ enc: ComputePass, pipelines: Pipelines, positions: MTLBuffer, normals: MTLBuffer, indices: MTLBuffer) {
        for s in systems where s.system.surface.mesh.w > 0 {
            let nodes = Int(s.system.surface.dims.w), active = max(FluidSystem.poured(s.system.params, clock: clock), 1)
            enc.setBuffer(s.surface, offset: 0, index: 0)
            enc.setBuffer(s.state, offset: 0, index: 1)
            enc.setBuffer(s.density, offset: 0, index: 2)
            enc.setBuffer(s.particles[0], offset: 0, index: 4)
            enc.setComputePipelineState(pipelines[.fluidSurfaceClear])
            dispatch(enc, pipelines[.fluidSurfaceClear], nodes)
            enc.setComputePipelineState(pipelines[.fluidSurfaceSplat])
            dispatch(enc, pipelines[.fluidSurfaceSplat], active)
            // The blur: x from the splat into field 0, y into field 1, z back into field 0.
            enc.setComputePipelineState(pipelines[.fluidSurfaceBlur])
            for (axis, from, to) in [(0, 1, 0), (1, 0, 1), (2, 1, 0)] {
                var pass = SIMD4<UInt32>(UInt32(axis), axis == 0 ? 1 : 0, 0, 0)
                enc.setBuffer(s.field[from], offset: 0, index: 3)
                enc.setBuffer(s.field[to], offset: 0, index: 5)
                enc.setBytes(&pass, length: 16, index: 6)
                dispatch(enc, pipelines[.fluidSurfaceBlur], nodes)
            }
            enc.setBuffer(s.field[0], offset: 0, index: 3)
            enc.setBuffer(s.vertexCounts, offset: 0, index: 7)
            enc.setBuffer(s.quadCounts, offset: 0, index: 8)
            enc.setComputePipelineState(pipelines[.fluidSurfaceCount])
            dispatch(enc, pipelines[.fluidSurfaceCount], nodes)
            encodeScan(enc, pipelines: pipelines, s.vertexCounts, into: s.vertexAt, partials: s.surfacePartials, size: s.surfaceSize, count: nodes)
            encodeScan(enc, pipelines: pipelines, s.quadCounts, into: s.quadAt, partials: s.surfacePartials, size: s.surfaceSize, count: nodes)
            enc.setBuffer(s.surface, offset: 0, index: 0)
            enc.setBuffer(s.field[0], offset: 0, index: 3)
            enc.setBuffer(s.vertexAt, offset: 0, index: 9)
            enc.setBuffer(positions, offset: 0, index: 10)
            enc.setBuffer(normals, offset: 0, index: 11)
            enc.setBuffer(s.quadAt, offset: 0, index: 12)
            enc.setBuffer(indices, offset: 0, index: 13)
            enc.setBuffer(s.stats, offset: 0, index: 14)
            enc.setComputePipelineState(pipelines[.fluidSurfaceVertex])
            dispatch(enc, pipelines[.fluidSurfaceVertex], nodes)
            enc.setComputePipelineState(pipelines[.fluidSurfaceQuad])
            dispatch(enc, pipelines[.fluidSurfaceQuad], nodes)
            enc.setComputePipelineState(pipelines[.fluidSurfaceTail])
            dispatch(enc, pipelines[.fluidSurfaceTail], Int(s.system.surface.triangles.x))
        }
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
