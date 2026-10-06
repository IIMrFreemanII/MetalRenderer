import XCTest
import Metal
import simd
@testable import MetalRenderer

/// PhysicsSoft.swift, the soft bodies' stages of PhysicsCPU.swift and Shaders/Physics.metal, and the soft body scene:
/// the lattice and its embedded surface, jellies that keep their volume, rest, sag by their compliance and don't pass
/// through each other or the floor, and the GPU's steps and drawn surface against the CPU's.
final class SoftBodyTests: XCTestCase {
    private let sphere = SDFShape(.sphere(radius: 0.24))
    private let cube = SDFShape(.box(halfExtents: [0.2, 0.2, 0.2], rounding: 0.06))

    private func world() -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        return w
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) {
        w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2)
    }

    private func particles(_ w: PhysicsWorld, _ body: Int) -> ArraySlice<GPUPhysicsParticle> {
        let first = Int(w.softBodies[body].x)
        return w.particles[first..<(first + Int(w.softBodies[body].y))]
    }

    private func restVolume(_ w: PhysicsWorld, _ body: Int) -> Float {
        let range = w.softBodies[body].x..<(w.softBodies[body].x + w.softBodies[body].y)
        return w.tets.filter { range.contains($0.ids.x) }.reduce(0) { $0 + $1.rest } / 6
    }

    /// How fast body `body`'s particles go over the next step, at most (m/s): a step's moves, not a substep's speed,
    /// which a resting jelly's contacts keep stirring by a fraction of a millimetre.
    private func fastest(_ w: PhysicsWorld, _ body: Int) -> Float {
        let before = particles(w, body).map { PhysicsMath.xyz($0.position) }
        w.step()
        return zip(particles(w, body), before).map { length(PhysicsMath.xyz($0.position) - $1) }.max()! / PhysicsWorld.stepLength
    }

    // MARK: The lattice

    func testTheLatticeFillsTheShape() {
        for shape in [sphere, cube, SDFShape(.capsule(halfLength: 0.16, radius: 0.15))] {
            let model = SoftModel(shape, cells: 6)
            XCTAssertTrue(model.tets.allSatisfy { SoftModel.sixVolume(model.points, $0) > 0 }, "every tet the right way out")
            XCTAssertEqual(Set(model.edges).count, model.edges.count, "each link once")
            // Each particle's ball reaches no further out than the surface (the corners outside moved onto it), and
            // the lattice's outside reaches it.
            let reach = model.points.map { shape.distance($0).d + model.radius }
            XCTAssertLessThan(reach.max()!, 0.05 * model.spacing)
            XCTAssertGreaterThan(reach.filter { $0 > -0.05 * model.spacing }.count, model.points.count / 3)
            let volume = model.tets.reduce(0) { $0 + SoftModel.sixVolume(model.points, $1) } / 6
            XCTAssertEqual(model.shares.reduce(0, +), volume, accuracy: volume * 1e-4)
            print("soft model: \(model.points.count) particles, \(model.tets.count) tets, \(model.edges.count) links, "
                  + "\(model.surface.positions.count) drawn vertices; lattice volume \(volume) m^3")
        }
    }

    func testColoursShareNoParticle() {
        let w = world()
        let model = SoftModel(sphere, cells: 6)
        for k in 0..<3 { w.addSoftBody(model, transform: translate([Float(k) * 0.6, 0.5, 0]), vertexBase: 0) }
        w.finish()
        for c in 0..<(w.tetStarts.count - 1) {
            var seen = Set<UInt32>()
            for t in w.tets[Int(w.tetStarts[c])..<Int(w.tetStarts[c + 1])] {
                for id in [t.ids.x, t.ids.y, t.ids.z, t.ids.w] { XCTAssertTrue(seen.insert(id).inserted, "colour \(c) shares a particle") }
            }
        }
        for c in 0..<(w.colourStarts.count - 1) {
            var seen = Set<UInt32>()
            for k in w.constraints[Int(w.colourStarts[c])..<Int(w.colourStarts[c + 1])] {
                XCTAssertTrue(seen.insert(k.a).inserted && seen.insert(k.b).inserted, "colour \(c) shares a particle")
            }
        }
        print("tets in \(w.tetStarts.count - 1) colours, links in \(w.colourStarts.count - 1)")
    }

    func testTheSurfaceIsEmbeddedAtRest() {
        let w = world()
        let model = SoftModel(cube, cells: 6)
        let place = translate([0.3, 0.8, -0.2]) * rotate(0.7, normalize(SIMD3<Float>(1, 2, 0.5)))
        w.addSoftBody(model, transform: place, vertexBase: 0)
        w.finish()
        let drawn = model.surface.positions.indices.map { w.drawnSoftVertex($0) }
        var worst: Float = 0, turns: [Float] = []
        for v in drawn.indices {
            worst = max(worst, length(drawn[v] - PhysicsMath.xyz(place * SIMD4(model.surface.positions[v], 1))))
            turns.append(dot(w.drawnSoftNormal(v) { drawn[$0] }, PhysicsMath.xyz(place * SIMD4(model.surface.normals[v], 0))))
        }
        XCTAssertLessThan(worst, 1e-5)
        // The rings' normals against the shape's own (its gradient).
        XCTAssertGreaterThan(turns.reduce(0, +) / Float(turns.count), 0.995)
        XCTAssertGreaterThan(turns.min()!, 0.8)
    }

    // MARK: Jellies

    func testAJellyComesToRestOnTheFloor() {
        let w = world()
        let model = SoftModel(cube, cells: 6)
        w.addSoftBody(model, transform: translate([0, 0.6, 0]) * rotate(0.3, [1, 0, 0]), vertexBase: 0)
        w.finish()
        let rest = restVolume(w, 0)
        run(w, 8)
        let volume = w.softVolume(0)
        let lowest = particles(w, 0).map { $0.position.y - $0.position.w }.min()!
        let drawn = model.surface.positions.indices.map { w.drawnSoftVertex($0).y }.min()!
        let speed = fastest(w, 0)
        print(String(format: "jelly at rest: volume %.4f of rest, lowest ball %.2g m, drawn surface %.2g m (a ball %.3f), fastest %.3g m/s",
                     volume / rest, lowest, drawn, model.radius, speed))
        XCTAssertEqual(volume / rest, 1, accuracy: 0.02)
        XCTAssertGreaterThan(lowest, -1e-3, "no particle in the floor")
        XCTAssertGreaterThan(drawn, -0.5 * model.radius, "the drawn surface on the floor")
        XCTAssertLessThan(speed, 0.05, "at rest")
    }

    func testASoftJellySagsMoreThanARubberOne() {
        func height(edge: Float) -> Float {
            let w = world()
            w.addSoftBody(SoftModel(sphere, cells: 6), transform: translate([0, 0.3, 0]), vertexBase: 0, edge: edge)
            w.finish()
            run(w, 3)
            let ys = particles(w, 0).map(\.position.y)
            return ys.max()! - ys.min()!
        }
        let jelly = height(edge: 1e-3), rubber = height(edge: 2e-5)
        print(String(format: "a jelly ball stands %.3f m, a rubber one %.3f m", jelly, rubber))
        XCTAssertLessThan(jelly, rubber * 0.95)
    }

    func testJelliesDontPassThroughEachOther() {
        // One jelly dropped onto another: it lands on it (and, heavy and soft, slides off it), and their balls never
        // pass into each other's; both come to rest.
        let w = world()
        let model = SoftModel(cube, cells: 6)
        w.addSoftBody(model, transform: translate([0, 0.25, 0]), vertexBase: 0)
        w.addSoftBody(model, transform: translate([0.02, 0.75, 0]), vertexBase: 0)
        w.finish()
        func closest() -> Float {
            var d = Float.infinity
            for a in particles(w, 0) {
                for b in particles(w, 1) { d = min(d, length(PhysicsMath.xyz(a.position - b.position)) - a.position.w - b.position.w) }
            }
            return d
        }
        let centre = { (ps: ArraySlice<GPUPhysicsParticle>) in ps.reduce(SIMD3<Float>()) { $0 + PhysicsMath.xyz($1.position) } / Float(ps.count) }
        run(w, 0.75)
        let landed = closest(), above = centre(particles(w, 1)).y - centre(particles(w, 0)).y
        run(w, 11.25)
        let after = closest(), speed = max(fastest(w, 0), fastest(w, 1))
        print(String(format: "two jellies: landed %.2f m above, balls %.2g m apart at the closest; at 12 s %.2g m apart, fastest %.3g m/s",
                     above, landed, after, speed))
        XCTAssertGreaterThan(above, 0.3, "the one dropped lands on the other")
        XCTAssertGreaterThan(landed, -3e-3)
        XCTAssertGreaterThan(after, -3e-3)
        XCTAssertLessThan(speed, 0.05)
    }

    func testABodyPushesAJellyAside() {
        // A heavy box slid into a jelly shoves it along the floor, and is not slowed by it (one-way). (A body lower than
        // a jelly goes through it: the jelly can't lift it, and its particles squeeze round it.)
        let w = world()
        w.addSoftBody(SoftModel(cube, cells: 6), transform: translate([0, 0.2, 0]), vertexBase: 0)
        let box = SDFShape(.box(halfExtents: [0.15, 0.3, 0.4], rounding: 0.02))
        w.addBody(sdf: 0, box, transform: translate([-1.0, 0.3, 0]), instance: 0, density: 3000, friction: 0.05, velocity: [3, 0, 0])
        w.finish()
        let rest = restVolume(w, 0)
        let centre = { (ps: ArraySlice<GPUPhysicsParticle>) in ps.reduce(SIMD3<Float>()) { $0 + PhysicsMath.xyz($1.position) } / Float(ps.count) }
        let start = centre(particles(w, 0))
        var deepest: Float = 0
        for _ in 0..<60 {
            w.step()
            let b = w.bodies[0], x = PhysicsMath.xyz(b.position)
            for q in particles(w, 0) {
                let local = PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), PhysicsMath.xyz(q.position) - x)
                deepest = min(deepest, w.distance(shape: Int(b.info.x), local) - q.position.w)
            }
        }
        let moved = centre(particles(w, 0)).x - start.x
        print(String(format: "a box slid into a jelly: it shoved it %.3f m, the jelly's balls %.2g m into it at most, volume %.3f of rest",
                     moved, deepest, w.softVolume(0) / rest))
        XCTAssertGreaterThan(moved, 1, "the jelly is shoved along")
        XCTAssertGreaterThan(deepest, -0.01, "and kept out of the box")
        XCTAssertEqual(w.softVolume(0) / rest, 1, accuracy: 0.05)
    }

    func testACrushedJellyRecovers() {
        let w = world()
        w.addSoftBody(SoftModel(cube, cells: 6), transform: translate([0, 0.3, 0]), vertexBase: 0)
        for i in w.particles.indices { w.particles[i].position.y = 0.05 + (w.particles[i].position.y - 0.1) * 0.4 }
        for i in w.particles.indices { w.particles[i].prevPosition = SIMD4(PhysicsMath.xyz(w.particles[i].position), w.particles[i].prevPosition.w) }
        w.finish()
        let rest = restVolume(w, 0)
        let crushed = w.softVolume(0)
        run(w, 2)
        print(String(format: "a jelly crushed to %.2f of its volume is back to %.4f", crushed / rest, w.softVolume(0) / rest))
        XCTAssertEqual(w.softVolume(0) / rest, 1, accuracy: 0.03)
    }

    // MARK: The scene

    private func softScene(bodies: Int = 8) -> Scene {
        var settings = SceneSettings(kind: .softBodies)
        settings.physics.softBodies = bodies
        settings.physics.backend = .cpu
        return Scene(settings)
    }

    func testTheSceneDrawsItsSoftBodies() {
        let scene = softScene(bodies: 16)
        let world = scene.physics!
        XCTAssertEqual(scene.softMeshes.count, 16)
        XCTAssertEqual(world.softBodies.count, 16)
        // Each drawn vertex knows where last frame's copy of it is.
        for v in world.softVertices {
            XCTAssertEqual(v.info.y, scene.meshes[scene.softMeshes[Int(v.info.z)]].prevOffset)
        }
        print("soft body scene: \(world.particles.count) particles, \(world.tets.count) tets in \(world.tetStarts.count - 1) colours, "
              + "\(world.constraints.count) links, \(world.softVertices.count) drawn vertices")
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = SoftBodyTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: SoftBodyTests.shaders, kind: .metal, lightTypes: 0x3F, stats: false)
        SoftBodyTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The soft body scene, its world stepped by the CPU, and the GPU's copy of it: `run` encodes steps, `encode` anything.
    private func gpuScene(bodies: Int = 8) throws
        -> (scene: Scene, gpu: PhysicsGPU, run: (Int) -> Void, encode: ((ComputePass) -> Void) -> Void) {
        let m = try metal()
        let scene = softScene(bodies: bodies)
        let sdf = try SDFBuffers(device: m.device, scene: scene)
        let gpu = try PhysicsGPU(device: m.device, world: scene.physics!, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        let encode = { (body: (ComputePass) -> Void) in
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            body(Metal3Pass(enc: enc))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        let run = { (steps: Int) in encode { gpu.encodeSteps($0, pipelines: m.pipelines, steps: steps) } }
        return (scene, gpu, run, encode)
    }

    func testGPUSoftBodiesMatchTheCPU() throws {
        // Falling and the first landings on the landing.
        let (scene, gpu, run, _) = try gpuScene()
        let world = scene.physics!
        // (The two part as their rounding does once the jellies land: 1 µm after a step, 0.2 mm at 20, 1.3 mm at 40.)
        run(20)
        for _ in 0..<20 { world.step() }
        let worst = zip(gpu.readParticles(), world.particles).map { length(PhysicsMath.xyz($0.position - $1.position)) }.max()!
        print(String(format: "GPU against CPU, soft bodies after 20 steps: within %.2g m", worst))
        XCTAssertLessThan(worst, 2e-3)
    }

    func testGPUSoftBodyRunsAreTheSame() throws {
        let (_, gpu, run, _) = try gpuScene()
        run(240)
        let first = gpu.readParticles().map(\.position)
        let (_, again, rerun, _) = try gpuScene()
        rerun(240)
        XCTAssertEqual(first, again.readParticles().map(\.position))
    }

    func testGPUDrawsTheSurfacesTheCPUDoes() throws {
        let (scene, gpu, run, encode) = try gpuScene()
        let m = try metal(), world = scene.physics!
        run(60)
        let particles = gpu.readParticles()
        let positions = m.device.makeBuffer(length: (scene.positions.count + 16) * 16, options: .storageModeShared)!
        let normals = m.device.makeBuffer(length: (scene.positions.count + 16) * 16, options: .storageModeShared)!
        encode { gpu.encodeSoftMesh($0, pipelines: m.pipelines, slot: 0, positions: positions, normals: normals) }
        let p = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: scene.positions.count)
        let n = normals.contents().bindMemory(to: SIMD3<Float>.self, capacity: scene.positions.count)
        var worst: Float = 0, worstTurn: Float = 1
        for v in world.softVertices.indices {
            let at = Int(world.softVertices[v].info.x)
            worst = max(worst, length(p[at] - world.drawnSoftVertex(v, particles: particles)))
            worstTurn = min(worstTurn, dot(n[at], world.drawnSoftNormal(v) { p[$0] }))
        }
        print(String(format: "GPU's drawn soft bodies within %.2g m of the CPU's", worst))
        XCTAssertLessThan(worst, 1e-5)
        XCTAssertGreaterThan(worstTurn, 0.9999)
    }

    func testGPUSoftBodiesComeToRest() throws {
        let (_, gpu, run, _) = try gpuScene(bodies: 16)
        run(900)
        let before = gpu.readParticles()
        run(1)
        let speeds = zip(gpu.readParticles(), before).map { length(PhysicsMath.xyz($0.position - $1.position)) / PhysicsWorld.stepLength }
        let moving = speeds.filter { $0 > 0.02 }.count
        print(String(format: "the soft body scene at 15 s: %d of %d particles faster than 2 cm/s, the fastest %.3g m/s",
                     moving, speeds.count, speeds.max()!))
        XCTAssertLessThan(speeds.max()!, 0.05)
        XCTAssertTrue(gpu.readParticles().allSatisfy { $0.position.y - $0.position.w > -2e-3 }, "nothing in the floor")
    }
}
