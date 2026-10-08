import XCTest
import Metal
import simd
@testable import MetalRenderer

/// PhysicsFluid.swift, PhysicsFluidCPU.swift and Shaders/Fluid.metal: the pour, PBF and MLS-MPM against each other
/// (GPU against the CPU, a GPU run against another), liquids that stay in their box and settle, honey that spreads
/// slower than water, and bodies the liquids push: a light box floats.
final class FluidTests: XCTestCase {
    /// A small box of liquid on a floor: 0.3 m across, 0.4 m up, `capacity` particles poured from 0.3 m up.
    private func world(_ kind: LiquidKind, _ solver: PhysicsSettings.Solver, capacity: Int = 1500, start: Float = 0,
                       body: Float? = nil) -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        if let density = body {
            let box = SDFShape(.box(halfExtents: [0.03, 0.03, 0.03], rounding: 0.004))
            w.addBody(sdf: 0, box, transform: translate([0.06, 0.031, 0.05]), instance: 0, density: density, friction: 0.5, restitution: 0.1)
        }
        w.addLiquid(kind, solver: solver, domain: AABB(lo: [-0.15, 0, -0.15], hi: [0.15, 0.4, 0.15]), nozzle: [-0.05, 0.3, -0.05],
                    start: start, capacity: capacity)
        w.finish()
        return w
    }

    private func positions(_ w: PhysicsWorld, _ s: Int = 0) -> [SIMD3<Float>] { w.fluid!.systems[s].particles.map { PhysicsMath.xyz($0.position) } }

    // MARK: The pour

    func testThePourIsAFunctionOfTheClock() {
        let w = world(.water, .pbf, capacity: 6000, start: 0.1)
        let p = w.fluid!.systems[0].params
        var last = 0
        for clock: UInt32 in 0..<1000 {
            let n = FluidSystem.poured(p, clock: clock)
            XCTAssertGreaterThanOrEqual(n, last)
            XCTAssertLessThanOrEqual(n - last, w.fluid!.systems[0].mostPouredInAGroup)
            XCTAssertEqual(n % Int(p.emission.x) == 0 || n == 6000, true)
            last = n
        }
        XCTAssertEqual(FluidSystem.poured(p, clock: UInt32((0.1 / p.extra.w).rounded(.up)) - 1), 0, "nothing before it starts")
        XCTAssertEqual(last, 6000, "it pours to the capacity")
        // A second's pour: the nozzle's area x its speed, at a particle a spacing^3.
        let second = FluidSystem.poured(p, clock: UInt32(1.1 / p.extra.w)) - FluidSystem.poured(p, clock: UInt32(0.1 / p.extra.w))
        let expected = Float.pi * p.nozzle.w * p.nozzle.w * p.direction.w / pow(p.extra.y, 3)
        print("water pours \(second) particles a second (\(p.emission.x) a layer), the nozzle's flow \(expected)")
        XCTAssertEqual(Float(second), expected, accuracy: expected * 0.2)
    }

    func testThePourStartsInTheStream() {
        let w = world(.water, .pbf)
        w.step()
        let p = w.fluid!.systems[0].params
        for x in positions(w) {
            XCTAssertLessThan(length(SIMD2(x.x, x.z) - SIMD2(-0.05, -0.05)), p.nozzle.w + 1e-4)
            XCTAssertLessThanOrEqual(x.y, 0.3 + 1e-4)
        }
        XCTAssertFalse(positions(w).isEmpty)
    }

    // MARK: Behaviour (CPU)

    private func check(_ w: PhysicsWorld, _ label: String) {
        let s = w.fluid!.systems[0], d = s.domain
        for q in s.particles {
            let x = PhysicsMath.xyz(q.position)
            XCTAssertTrue(all(x .>= d.lo - 1e-4) && all(x .<= d.hi + 1e-4) && x.x.isFinite && x.y.isFinite && x.z.isFinite,
                          "\(label): a particle at \(x) outside the box")
        }
    }

    func testPBFWaterStaysInItsBoxAndSettles() {
        let w = world(.water, .pbf)
        w.advance(to: 2.5)
        check(w, "PBF water")
        let speeds = w.fluid!.systems[0].particles.map { length(PhysicsMath.xyz($0.velocity)) }
        let mean = speeds.reduce(0, +) / Float(speeds.count)
        print(String(format: "PBF water at 2.5 s: %d particles, mean speed %.3f m/s, top %.2f m", speeds.count, mean,
                     positions(w).map(\.y).max()!))
        XCTAssertLessThan(mean, 0.15)
        // A layer about as deep as its volume over the floor: no great compression.
        let depth = Float(speeds.count) * pow(0.012, 3) / (0.3 * 0.3)
        XCTAssertLessThan(positions(w).map(\.y).sorted()[speeds.count * 9 / 10], 2.2 * depth + 0.012)
    }

    func testMPMLiquidsStayInTheirBoxAndSettle() {
        for kind in [LiquidKind.water, .honey] {
            let w = world(kind, .mpm)
            w.advance(to: 2.5)
            check(w, "MPM \(kind.name)")
            let s = w.fluid!.systems[0]
            let speeds = s.particles.map { length(PhysicsMath.xyz($0.velocity)) }
            let j = s.particles.map(\.position.w)
            print(String(format: "MPM %@ at 2.5 s: %d particles, mean speed %.3f m/s, J %.3f...%.3f", kind.name, speeds.count,
                         speeds.reduce(0, +) / Float(speeds.count), j.min()!, j.max()!))
            XCTAssertLessThan(speeds.reduce(0, +) / Float(speeds.count), 0.15)
        }
    }

    func testCarreauThinsWithShear() {
        let blood = LiquidKind.blood.physics.viscosity
        XCTAssertEqual(LiquidKind.viscosity(blood, shear: 0), blood.x, accuracy: 1e-6)
        XCTAssertEqual(LiquidKind.viscosity(blood, shear: 1e6), blood.y, accuracy: 1e-3)
        var last = Float.infinity
        for shear: Float in [0, 0.1, 1, 10, 100, 1000] {
            let mu = LiquidKind.viscosity(blood, shear: shear)
            XCTAssertLessThan(mu, last)
            last = mu
        }
        XCTAssertEqual(LiquidKind.viscosity(LiquidKind.honey.physics.viscosity, shear: 50), 10)
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = FluidTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: FluidTests.shaders, lightTypes: 0x3F, stats: false)
        FluidTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The GPU's copy of world `w` (and an empty SDF scene: the colliders here are analytic): `run` encodes steps.
    private func gpu(_ w: PhysicsWorld) throws -> (gpu: PhysicsGPU, run: (Int) -> Void) {
        let m = try metal()
        let sdf = try SDFBuffers(device: m.device, scene: Scene(SceneSettings(kind: .cornell)))
        let gpu = try PhysicsGPU(device: m.device, world: w, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        let run = { (steps: Int) in
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            gpu.encodeSteps(Metal3Pass(enc: enc), pipelines: m.pipelines, steps: steps)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        return (gpu, run)
    }

    /// How far apart two sets of particles are: each of `a`'s from the nearest of `b`'s, at most (or the `share`
    /// quantile of those).
    private func apart(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], share: Float = 1) -> Float {
        let d = a.map { x in b.map { length_squared($0 - x) }.min()!.squareRoot() }.sorted()
        return d[min(Int(Float(d.count - 1) * share), d.count - 1)]
    }

    func testGPUSmoke() throws {
        for solver in [PhysicsSettings.Solver.pbf, .mpm] {
            let w = world(.water, solver, body: 400)
            let (gpu, run) = try gpu(w)
            run(1)
            let state = gpu.fluid!.readState(0)
            print("GPU smoke, \(solver): state \(state), first particle \(gpu.fluid!.readParticles(0).first.map(\.position) ?? .zero)")
            XCTAssertEqual(state.x, UInt32(w.fluidGroups))
            XCTAssertGreaterThan(state.y, 0)
        }
    }

    func testGPUMatchesTheCPU() throws {
        for (kind, solver) in [(LiquidKind.water, PhysicsSettings.Solver.pbf), (.water, .mpm), (.blood, .mpm), (.honey, .pbf)] {
            let w = world(kind, solver)
            let (gpu, run) = try gpu(w)
            // The first steps: the pour's first layers falling, then landing.
            var worst: [Float] = [], most: [Float] = [], centre: Float = 0, spread: Float = 0
            for steps in [1, 3, 30] {
                run(steps - Int(w.stepIndex))
                while w.stepIndex < steps { w.step() }
                let g = gpu.fluid!.readParticles(0).map { PhysicsMath.xyz($0.position) }
                XCTAssertEqual(g.count, w.fluid!.systems[0].particles.count, "\(kind.name) \(solver): as many poured")
                worst.append(max(apart(g, positions(w)), apart(positions(w), g)))
                most.append(apart(g, positions(w), share: 0.9))
                // The whole: its centre of mass and how far it spreads about it (rms).
                func moments(_ x: [SIMD3<Float>]) -> (SIMD3<Float>, Float) {
                    let c = x.reduce(.zero, +) / Float(x.count)
                    return (c, (x.map { length_squared($0 - c) }.reduce(0, +) / Float(x.count)).squareRoot())
                }
                let (cg, sg) = moments(g), (cc, sc) = moments(positions(w))
                centre = length(cg - cc)
                spread = abs(sg - sc)
            }
            print("GPU against CPU, \(kind.name) by \(solver): within \(worst.map { String(format: "%.2g", $0) }) m after 1, 3, "
                  + "30 steps, 90% within \(most.map { String(format: "%.2g", $0) }); at 30 the centres \(centre) m apart, "
                  + "the spreads \(spread)")
            XCTAssertLessThan(worst[0], 1e-5)
            XCTAssertLessThan(worst[1], 1e-4)
            // A liquid's free surface is chaotic: PBF's cohesion and MPM's splash take rounding apart 10 to 50 times a
            // step once the stream lands (water by PBF: 1e-6 m at 3 steps, 6e-5 at 4, 1e-3 at 5, 8e-3 at 6). Particle
            // by particle the two then part by up to a spacing, the liquid as a whole by millimetres.
            XCTAssertLessThan(centre, 1e-2)
            XCTAssertLessThan(spread, 3e-3)
        }
    }

    func testGPURunsAreTheSame() throws {
        for solver in [PhysicsSettings.Solver.pbf, .mpm] {
            let (first, run) = try gpu(world(.water, solver, body: 400))
            run(150)
            let (second, rerun) = try gpu(world(.water, solver, body: 400))
            rerun(150)
            XCTAssertEqual(first.fluid!.readParticles(0).map(\.position), second.fluid!.readParticles(0).map(\.position), "\(solver)")
            XCTAssertEqual(first.readBodies().map(\.position), second.readBodies().map(\.position), "\(solver)")
        }
    }

    // MARK: The surface

    func testGPUSurfaceIsTheCPUs() throws {
        for solver in [PhysicsSettings.Solver.pbf, .mpm] {
            let w = world(.water, solver)
            // The mesh at the start of a buffer of its own, last frame's after it.
            let v = Int(w.fluid!.systems[0].surface.mesh.w), t = Int(w.fluid!.systems[0].surface.triangles.x)
            w.fluid!.systems[0].surface.mesh.x = 0
            w.fluid!.systems[0].surface.mesh.y = 0
            w.fluid!.systems[0].surface.mesh.z = UInt32(v + 1)
            let (gpu, run) = try gpu(w)
            run(60)
            let m = try metal()
            let positions = m.device.makeBuffer(length: 2 * (v + 1) * 16, options: .storageModeShared)!
            let normals = m.device.makeBuffer(length: (v + 1) * 16, options: .storageModeShared)!
            let indices = m.device.makeBuffer(length: 3 * t * 4, options: .storageModeShared)!
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            gpu.encodeFluidSurfaces(Metal3Pass(enc: enc), pipelines: m.pipelines, positions: positions, normals: normals, indices: indices)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
            // The CPU's surface of the GPU's particles.
            var system = w.fluid!.systems[0]
            system.particles = gpu.fluid!.readParticles(0)
            let cpu = system.cpuSurface(system.surface)
            let stats = gpu.fluid!.readSurfaceStats(0)
            print("\(solver) surface at 1 s: \(system.particles.count) particles, \(stats.x) vertices, \(stats.y) triangles (holds \(v), \(t))")
            XCTAssertEqual(Int(stats.x), cpu.positions.count)
            XCTAssertEqual(Int(stats.y), cpu.indices.count / 3)
            XCTAssertEqual(stats.z, 0, "room enough")
            XCTAssertGreaterThan(cpu.positions.count, 100)
            let p = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2 * (v + 1))
            let n = normals.contents().bindMemory(to: SIMD3<Float>.self, capacity: v + 1)
            let ix = Array(UnsafeBufferPointer(start: indices.contents().bindMemory(to: UInt32.self, capacity: 3 * t), count: 3 * t))
            var worst: Float = 0, turn: Float = 1
            for i in cpu.positions.indices {
                worst = max(worst, length(p[i] - cpu.positions[i]), length(p[i + v + 1] - cpu.positions[i]))
                turn = min(turn, dot(n[i], cpu.normals[i]))
            }
            print(String(format: "  GPU's vertices within %.2g m of the CPU's, normals within %.4f", worst, turn))
            XCTAssertLessThan(worst, 1e-5)
            XCTAssertGreaterThan(turn, 0.999)
            XCTAssertEqual(Array(ix[0..<cpu.indices.count]), cpu.indices)
            XCTAssertTrue(ix[cpu.indices.count...].allSatisfy { $0 == UInt32(v) }, "the rest degenerate at the spare vertex")
            // Closed: every edge as often one way as the other (where two blobs touch at a cell, an edge has four
            // triangles); and wound outward (as its vertices' normals face).
            var edges: [SIMD2<UInt32>: Int] = [:]
            var outward = 0
            for f in 0..<(cpu.indices.count / 3) {
                let a = cpu.indices[3 * f], b = cpu.indices[3 * f + 1], c = cpu.indices[3 * f + 2]
                for (x, y) in [(a, b), (b, c), (c, a)] { edges[SIMD2(x, y), default: 0] += 1 }
                let face = cross(cpu.positions[Int(b)] - cpu.positions[Int(a)], cpu.positions[Int(c)] - cpu.positions[Int(a)])
                if dot(face, cpu.normals[Int(a)] + cpu.normals[Int(b)] + cpu.normals[Int(c)]) > 0 { outward += 1 }
            }
            XCTAssertTrue(edges.allSatisfy { edges[SIMD2($0.key.y, $0.key.x)] == $0.value }, "\(solver): a closed surface")
            print("  \(edges.filter { $0.value > 1 }.count) of \(edges.count) edges in more than two triangles")
            XCTAssertGreaterThan(Float(outward), 0.98 * Float(cpu.indices.count / 3), "\(solver): wound outward")
        }
    }

    // MARK: Bodies

    /// A box of `density` held 0.2 m up over a 0.3 m box that `kind` fills (by `solver`) to about 10 cm, dropped at 3 s;
    /// where its bottom is at `seconds`, on the GPU. (Resting on the floor as the liquid rose, nothing got under it to
    /// lift it: a box flat on the floor doesn't float.)
    private func boxBottom(_ kind: LiquidKind, _ solver: PhysicsSettings.Solver, density: Float, seconds: Float) throws -> Float {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        let box = SDFShape(.box(halfExtents: [0.03, 0.03, 0.03], rounding: 0.004))
        w.addBody(sdf: 0, box, transform: translate([0.07, 0.23, 0.07]), instance: 0, density: density, friction: 0.5, restitution: 0.1)
        w.hold(body: 0, until: 3)
        w.addLiquid(kind, solver: solver, domain: AABB(lo: [-0.15, 0, -0.15], hi: [0.15, 0.5, 0.15]), nozzle: [-0.07, 0.3, -0.07],
                    start: 0, capacity: solver == .mpm ? 9000 : 6000)
        w.finish()
        let (gpu, run) = try gpu(w)
        run(Int(seconds / PhysicsWorld.stepLength))
        let b = gpu.readBodies()[0]
        print(String(format: "a %.0f kg/m^3 box in %@ (%@) at %.1f s: its bottom %.3f m up, %d particles", density, kind.name, "\(solver)", seconds,
                     b.position.y - 0.03, gpu.fluid!.readParticles(0).count))
        return b.position.y - 0.03
    }

    func testALightBoxFloats() throws {
        // (MPM water and blood: the box bobs, deeper and deeper, and sinks: see PhysicsSettings.)
        for (kind, solver) in [(LiquidKind.water, PhysicsSettings.Solver.pbf), (.blood, .pbf), (.honey, .mpm), (.honey, .pbf)] {
            XCTAssertGreaterThan(try boxBottom(kind, solver, density: 250, seconds: 6), 0.02, "\(kind.name) by \(solver) holds it up")
        }
    }

    func testAHeavyBoxSinksSlowerInHoney() throws {
        XCTAssertLessThan(try boxBottom(.water, .pbf, density: 2000, seconds: 6), 0.015, "it sinks in water (onto a particle or two)")
        let water = try boxBottom(.water, .mpm, density: 2000, seconds: 3.4), honey = try boxBottom(.honey, .mpm, density: 2000, seconds: 3.4)
        XCTAssertGreaterThan(honey, water + 0.01, "0.4 s after the drop, honey has held it up longer")
    }

    /// The impulses a liquid at rest gives a body hold it up as its weight would: on the CPU, a box held still under
    /// water (no gravity on it: kinematic ones take nothing back, so a body with its own weight cancelled).
    func testTheLiquidPushesBack() {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        let box = SDFShape(.box(halfExtents: [0.03, 0.03, 0.03], rounding: 0.004))
        w.addBody(sdf: 0, box, transform: translate([0.0, 0.2, 0.0]), instance: 0, density: 250, friction: 0.5, restitution: 0.1)
        w.hold(body: 0, until: 2)
        w.addLiquid(.water, solver: .pbf, domain: AABB(lo: [-0.1, 0, -0.1], hi: [0.1, 0.3, 0.1]), nozzle: [-0.06, 0.2, -0.06],
                    start: 0, capacity: 3000)
        w.finish()
        w.advance(to: 1.9)
        XCTAssertEqual(w.bodies[0].position.y, 0.2, accuracy: 1e-6, "held till it is dropped")
        w.advance(to: 3.5)
        // Its bottom off the floor: the water holds it up (3 L in 0.04 m^2: 7 cm, a 6 cm box at a quarter of water's density).
        print(String(format: "a light box dropped into a 20 cm box of water: at 3.5 s its bottom %.3f m up (CPU)", w.bodies[0].position.y - 0.03))
        XCTAssertGreaterThan(w.bodies[0].position.y - 0.03, 0.02)
    }

    func testGPUResetStartsAgain() throws {
        let w = world(.water, .mpm)
        let (gpu, run) = try gpu(w)
        run(40)
        let first = gpu.fluid!.readParticles(0).map(\.position)
        let m = try metal()
        let cmd = m.queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
        gpu.encodeReset(Metal3Pass(enc: enc), pipelines: m.pipelines)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertEqual(gpu.fluid!.readState(0).y, 0)
        run(40)
        XCTAssertEqual(gpu.fluid!.readParticles(0).map(\.position), first)
    }
}
