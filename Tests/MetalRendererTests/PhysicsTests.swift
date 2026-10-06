import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Physics.swift, PhysicsCollide.swift, PhysicsCPU.swift, PhysicsGPU.swift and Shaders/Physics.metal: shapes' mass
/// properties, contacts, bodies that rest, stack, bounce and slide as they should, and the GPU's steps against the CPU's.
final class PhysicsTests: XCTestCase {
    private let identity = matrix_identity_float4x4

    private func world(substeps: Int = 16, floor: Bool = true) -> PhysicsWorld {
        let w = PhysicsWorld(substeps: substeps)
        if floor { w.addPlane(point: .zero, normal: [0, 1, 0]) }
        return w
    }

    /// Steps `seconds` of simulation.
    private func run(_ w: PhysicsWorld, _ seconds: Float) {
        w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2)
    }

    private func position(_ w: PhysicsWorld, _ i: Int) -> SIMD3<Float> { PhysicsMath.xyz(w.bodies[i].position) }

    // MARK: Shapes

    func testEigenDiagonalisesASymmetricMatrix() {
        let m = simd_double3x3(rows: [SIMD3(4, 1, 0.5), SIMD3(1, 3, 0.2), SIMD3(0.5, 0.2, 2)])
        let (values, vectors) = PhysicsWorld.eigen(m)
        let d = vectors.transpose * m * vectors
        XCTAssertEqual(d[1][0], 0, accuracy: 1e-9)
        XCTAssertEqual(d[2][0], 0, accuracy: 1e-9)
        XCTAssertEqual(d[2][1], 0, accuracy: 1e-9)
        XCTAssertEqual(values.x + values.y + values.z, 9, accuracy: 1e-9)
        XCTAssertEqual(simd_determinant(vectors), 1, accuracy: 1e-9)
    }

    func testSampledShapeMassMatchesTheFormula() {
        // A box made of two nodes (so it is sampled, not a formula): its volume, centre and moments.
        let shape = SDFShape([SDFShape.Node(.box(halfExtents: [0.5, 0.25, 0.25]), at: [0.25, 0, 0]),
                              SDFShape.Node(.box(halfExtents: [0.5, 0.25, 0.25]), at: [0.75, 0, 0])])
        let build = PhysicsWorld.buildShape(shape, index: 0, volumes: [])
        XCTAssertEqual(build.volume, 0.375, accuracy: 0.01)   // they overlap: 1.5 x 0.5 x 0.5 in all
        XCTAssertEqual(build.shape.comPosition.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(build.shape.comPosition.y, 0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(build.samples.count, PhysicsWorld.maxSamples)
        // Principal moments of a 1.5 x 0.5 x 0.5 box per unit density: the smallest about its long axis.
        let v: Float = 1.5 * 0.5 * 0.5
        let expected = [v * (0.25 + 0.25) / 12, v * (2.25 + 0.25) / 12, v * (2.25 + 0.25) / 12]
        let moments = [build.moments.x, build.moments.y, build.moments.z].sorted()
        for (m, e) in zip(moments, expected) { XCTAssertEqual(m, e, accuracy: e * 0.06) }
    }

    func testSphereAgainstCapsuleIsExact() {
        let w = world(floor: false)
        w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.3)), transform: translate([0, 0.45, 0]), instance: 0)
        w.addBody(sdf: 1, SDFShape(.capsule(halfLength: 0.5, radius: 0.2)), transform: rotate(.pi / 2, [0, 0, 1]), instance: 1)
        w.finish()
        let m = w.collide(w.bodies[0], w.bodies[1], margin: 0.1)
        let deepest = try! XCTUnwrap(m.points.min { $0.separation < $1.separation })
        XCTAssertEqual(deepest.separation, -0.05, accuracy: 1e-3)
        XCTAssertEqual(deepest.normal.y, 1, accuracy: 1e-3)
    }

    func testBoxEdgeAcrossBoxEdgeIsFound() {
        // Two long bars on edge, crossed, one on the other: no corner of either is inside the other. (A field's
        // deepest point is short of an edge-to-edge overlap, 10 cm here, and its normal is a face's: see the README.)
        let w = world(floor: false)
        let bar = SDFShape(.box(halfExtents: [1, 0.1, 0.1]))
        w.addBody(sdf: 0, bar, transform: translate([0, 0.18, 0]) * rotate(.pi / 2, [0, 1, 0]) * rotate(.pi / 4, [1, 0, 0]), instance: 0)
        // The other a sampled shape (a speck cut out of it), so that both sides' fields are stepped down.
        w.addBody(sdf: 1, SDFShape([SDFShape.Node(.box(halfExtents: [1, 0.1, 0.1])), SDFShape.Node(.sphere(radius: 0.002), .subtract, at: [0.9, 0, 0])]),
                  transform: rotate(.pi / 4, [1, 0, 0]), instance: 1)
        w.finish()
        let m = w.collide(w.bodies[0], w.bodies[1], margin: 0.01)
        let deepest = try! XCTUnwrap(m.points.min { $0.separation < $1.separation }, "no contact between crossed bars")
        // Their edges are 0.1 x sqrt(2) from each centre: 0.103 into each other; the deepest point of one's edge in
        // the other is (0.103 / sqrt(2)) from the other's faces.
        XCTAssertEqual(deepest.separation, -(0.2 * sqrt(2) - 0.18) / sqrt(2), accuracy: 0.01)
        XCTAssertGreaterThan(deepest.normal.y, 0.65)
    }

    // MARK: Bodies

    func testSphereComesToRestOnTheFloor() {
        let w = world()
        w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.25)), transform: translate([0, 2, 0]), instance: 0, restitution: 0)
        w.finish()
        run(w, 3)
        let p = position(w, 0)
        XCTAssertEqual(p.y, 0.25, accuracy: 1e-3)
        XCTAssertEqual(p.x, 0, accuracy: 1e-4)
        XCTAssertLessThan(length(PhysicsMath.xyz(w.bodies[0].velocity)), 0.05)
    }

    func testBoxLandsFlatAndSleeps() {
        let w = world()
        w.addBody(sdf: 0, SDFShape(.box(halfExtents: [0.3, 0.2, 0.25])), transform: translate([0, 1, 0]) * rotate(0.3, [1, 0.5, 0]),
                  instance: 0)
        w.finish()
        run(w, 4)
        let b = w.bodies[0]
        // One of its faces on the floor: its centre at one of its half extents.
        let y = b.position.y
        XCTAssertTrue([0.3, 0.2, 0.25].contains { abs(y - $0) < 3e-3 }, "box centre at \(y)")
        XCTAssertNotEqual(b.info.y & PhysicsWorld.asleep, 0, "the box never fell asleep")
    }

    func testBoxStackStands() {
        let w = world()
        let box = SDFShape(.box(halfExtents: [0.25, 0.25, 0.25]))
        for i in 0..<5 {
            w.addBody(sdf: 0, box, transform: translate([0.01 * Float(i % 2), 0.25 + 0.5 * Float(i), 0]), instance: i, restitution: 0)
        }
        w.finish()
        run(w, 10)
        for i in 0..<5 {
            let p = position(w, i)
            XCTAssertEqual(p.y, 0.25 + 0.5 * Float(i), accuracy: 0.02, "box \(i) at \(p)")
            XCTAssertEqual(p.x, 0.01 * Float(i % 2), accuracy: 0.03, "box \(i) slid to \(p)")
        }
    }

    func testRestitutionSetsTheBounce() {
        // Dropped from 1 m onto a floor, restitution e (both): the first bounce rises to about e^2 m.
        for e: Float in [0.5, 0.8] {
            let w = PhysicsWorld(substeps: 8)
            w.addPlane(point: .zero, normal: [0, 1, 0], restitution: e)
            w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.1)), transform: translate([0, 1.1, 0]), instance: 0, restitution: e)
            w.finish()
            var bounced = false, top: Float = 0
            for _ in 0..<120 {
                w.step()
                let b = w.bodies[0]
                if b.velocity.y > 0 { bounced = true }
                if bounced { top = max(top, b.position.y - 0.1) }
                if bounced && b.velocity.y < 0 { break }
            }
            XCTAssertEqual(top, e * e, accuracy: 0.06, "restitution \(e)")
        }
    }

    func testFrictionHoldsOrLetsGoOnASlope() {
        // A box on a 20 degree slope: it stays when friction is above tan 20 = 0.36, and slides below.
        for (friction, holds) in [(Float(0.8), true), (Float(0.1), false)] {
            let w = PhysicsWorld(substeps: 8)
            let angle: Float = 20 * .pi / 180
            let normal = SIMD3<Float>(sin(angle), cos(angle), 0)
            w.addPlane(point: .zero, normal: normal, friction: friction)
            let place = translate(normal * 0.2) * rotate(-angle, [0, 0, 1])
            w.addBody(sdf: 0, SDFShape(.box(halfExtents: [0.3, 0.2, 0.3])), transform: place, instance: 0, friction: friction, restitution: 0)
            w.finish()
            let start = position(w, 0)
            run(w, 2)
            let moved = length(position(w, 0) - start)
            if holds { XCTAssertLessThan(moved, 0.02, "friction \(friction) let it slide \(moved) m") }
            else { XCTAssertGreaterThan(moved, 1, "friction \(friction) held it (\(moved) m)") }
        }
    }

    func testReplayingIsTheSameAsSteppingOn() {
        func scene() -> PhysicsWorld {
            let w = world()
            for i in 0..<6 {
                w.addBody(sdf: i % 2, i % 2 == 0 ? SDFShape(.sphere(radius: 0.2)) : SDFShape(.box(halfExtents: [0.2, 0.15, 0.1])),
                          transform: translate([0.13 * Float(i), 0.4 + 0.45 * Float(i), 0]) * rotate(Float(i), [0, 1, 1]), instance: i)
            }
            w.finish()
            return w
        }
        let a = scene(), b = scene()
        a.advance(to: 1.5)
        b.advance(to: 0.7)
        b.advance(to: 1.5)
        a.advance(to: 0.2)      // back: replays from the start
        a.advance(to: 1.5)
        for i in a.bodies.indices {
            XCTAssertEqual(a.bodies[i].position, b.bodies[i].position)
            XCTAssertEqual(a.bodies[i].rotation, b.bodies[i].rotation)
        }
    }

    func testTransformPlacesTheShapeAsAdded() {
        // An off-centre compound: its instance transform round-trips through the body's pose.
        let w = world(floor: false)
        let shape = SDFShape([SDFShape.Node(.box(halfExtents: [0.4, 0.1, 0.1])), SDFShape.Node(.sphere(radius: 0.2), at: [0.4, 0.1, 0])])
        let place = translate([1, 2, 3]) * rotate(0.7, [0.3, 1, 0.2])
        w.addBody(sdf: 0, shape, transform: place, instance: 0)
        w.finish()
        let m = w.transform(0)
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(m[c][r], place[c][r], accuracy: 1e-4) } }
    }

    // MARK: Particles

    /// `count` particles of `radius` in a column of 6 x 6 layers over the origin, a little apart.
    private func pour(_ w: PhysicsWorld, count: Int, radius: Float, height: Float = 0.3, friction: Float = 0.5) {
        for i in 0..<count {
            let layer = i / 36, cell = i % 36
            let p = SIMD3<Float>(Float(cell % 6) - 2.5, 0, Float(cell / 6) - 2.5) * (2.2 * radius) + SIMD3(0, height + Float(layer) * 2.2 * radius, 0)
            w.addParticle(at: p, radius: radius, instance: i, friction: friction)
        }
    }

    func testParticlesPileUpOnTheFloor() {
        let w = world()
        pour(w, count: 360, radius: 0.05)
        w.finish()
        run(w, 4)
        var top: Float = 0, lowest = Float.infinity
        for q in w.particles {
            XCTAssertFalse(q.position.x.isNaN)
            lowest = min(lowest, q.position.y)
            top = max(top, q.position.y)
        }
        XCTAssertEqual(w.particles.count, 360)
        XCTAssertGreaterThan(lowest, 0.05 - 0.005, "a particle sank into the floor")
        // 360 balls on a 0.66 m square: with friction they stand as a heap, several deep, rather than spread one deep.
        XCTAssertGreaterThan(top, 0.05 + 4 * 0.1, "they spread out flat: top \(top)")
    }

    func testABodyPushesParticlesAside() {
        let w = world()
        w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.3)), transform: translate([-2, 0.3, 0]), instance: 1000, density: 3000,
                  velocity: [4, 0, 0])
        pour(w, count: 72, radius: 0.05, height: 0.05)
        w.finish()
        run(w, 1.5)
        let ball = PhysicsMath.xyz(w.bodies[0].position)
        XCTAssertGreaterThan(ball.x, 0.5, "the ball stopped in the particles")
        for q in w.particles {
            XCTAssertGreaterThan(length(PhysicsMath.xyz(q.position) - ball), 0.3 + 0.05 - 0.01, "a particle is inside the ball")
        }
    }

    // MARK: Cloth

    /// How far the cloth's stretch constraints are from their rest lengths, at most (a fraction of them).
    private func worstStretch(_ w: PhysicsWorld) -> Float {
        var worst: Float = 0
        for k in w.constraints where k.compliance == 0 {
            let l = length(PhysicsMath.xyz(w.particles[Int(k.a)].position) - PhysicsMath.xyz(w.particles[Int(k.b)].position))
            worst = max(worst, abs(l - k.rest) / k.rest)
        }
        return worst
    }

    func testClothHangsFromTwoCornersWithoutStretching() {
        let w = world()
        let n = 16
        w.addCloth(origin: [-0.5, 2, 0], across: [1, 0, 0], down: [0, 0, 1], columns: n, rows: n, pinned: [0, n - 1],
                   thickness: 0.01, vertexBase: 0)
        w.finish()
        XCTAssertGreaterThan(w.colourStarts.count - 1, 1)
        // No two constraints of a colour share a vertex.
        for c in 0..<(w.colourStarts.count - 1) {
            var seen = Set<UInt32>()
            for k in w.constraints[Int(w.colourStarts[c])..<Int(w.colourStarts[c + 1])] {
                XCTAssertTrue(seen.insert(k.a).inserted && seen.insert(k.b).inserted, "colour \(c) shares a vertex")
            }
        }
        run(w, 3)
        XCTAssertEqual(PhysicsMath.xyz(w.particles[0].position), [-0.5, 2, 0], "a pinned corner moved")
        let lowest = w.particles.map(\.position.y).min()!
        XCTAssertLessThan(lowest, 2 - 0.8, "it doesn't hang down: lowest at \(lowest)")
        XCTAssertLessThan(worstStretch(w), 0.05, "it stretched")
    }

    func testClothDrapesOverASphere() {
        let w = world()
        let ball = SDFShape(.sphere(radius: 0.4))
        w.addStatic(sdf: 0, ball, transform: translate([0, 0.4, 0]))
        let n = 20
        w.addCloth(origin: [-0.7, 1.2, -0.7], across: [1.4, 0, 0], down: [0, 0, 1.4], columns: n, rows: n, pinned: [],
                   thickness: 0.01, vertexBase: 0)
        w.finish()
        run(w, 3)
        let centre = SIMD3<Float>(0, 0.4, 0)
        for q in w.particles {
            XCTAssertGreaterThan(length(PhysicsMath.xyz(q.position) - centre), 0.4 + 0.01 - 0.005, "a vertex is inside the ball")
            XCTAssertGreaterThan(q.position.y, 0.01 - 0.005, "a vertex is under the floor")
        }
        // The middle rests on the top; the corners hang down past the ball's equator.
        let middle = w.particles[(n / 2) * n + n / 2].position.y
        XCTAssertEqual(middle, 0.8 + 0.01, accuracy: 0.02)
        XCTAssertLessThan(w.particles[0].position.y, 0.4)
        XCTAssertLessThan(worstStretch(w), 0.08)
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = PhysicsTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: PhysicsTests.shaders, kind: .metal, lightTypes: 0x3F, stats: false)
        PhysicsTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The physics scene with `bodies` bodies (and no particles), its world stepped by the CPU, and the GPU's copy of it.
    private func gpuScene(bodies: Int) throws -> (scene: Scene, gpu: PhysicsGPU, run: (Int, Bool) -> Void) {
        try gpuScene(bodies: bodies, particles: 0)
    }

    /// `particles`: the scene's bin's, fewer than it has (the CPU steps them too).
    private func gpuScene(bodies: Int, particles: Int) throws -> (scene: Scene, gpu: PhysicsGPU, run: (Int, Bool) -> Void) {
        let m = try metal()
        var settings = SceneSettings(kind: .physics)
        settings.physics.bodies = bodies
        settings.physics.particles = particles
        settings.physics.backend = .cpu
        let scene = Scene(settings)
        let sdf = try SDFBuffers(device: m.device, scene: scene)
        let gpu = try PhysicsGPU(device: m.device, world: scene.physics!, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        let run = { (steps: Int, reset: Bool) in
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            let pass = Metal3Pass(enc: enc)
            if reset { gpu.encodeReset(pass, pipelines: m.pipelines) }
            gpu.encodeSteps(pass, pipelines: m.pipelines, steps: steps)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        return (scene, gpu, run)
    }

    func testGPUStepsMatchTheCPU() throws {
        let (scene, gpu, run) = try gpuScene(bodies: 48, particles: 400)
        let world = scene.physics!
        // A third of a second: falling, the particles' first touches of the bin's rim and of each other. (Further on
        // a pile tells float rounding apart: two particles 0.1 mm apart at 26 steps are 2 cm apart at 30, the bin's floor
        // having taken one a substep before the other.)
        run(20, false)
        for _ in 0..<20 { world.step() }
        var worstParticle: Float = 0
        for (g, c) in zip(gpu.readParticles(), world.particles) {
            worstParticle = max(worstParticle, length(PhysicsMath.xyz(g.position) - PhysicsMath.xyz(c.position)))
        }
        // Half a second for the bodies: their first landings and the heavy ball's roll into the tower.
        run(10, false)
        for _ in 0..<10 { world.step() }
        var worst: Float = 0, worstTurn: Float = 0
        for (g, c) in zip(gpu.readBodies(), world.bodies) {
            worst = max(worst, length(PhysicsMath.xyz(g.position) - PhysicsMath.xyz(c.position)))
            worstTurn = max(worstTurn, 1 - abs(dot(g.rotation, c.rotation)))
            XCTAssertEqual(g.info.y, c.info.y, "asleep on one, not the other")
        }
        print(String(format: "GPU against CPU: bodies after 30 steps within %.2g m, rotations within %.2g; %d particles after 20 within %.2g m",
                     worst, worstTurn, world.particles.count, worstParticle))
        XCTAssertLessThan(worst, 2e-3)
        XCTAssertLessThan(worstTurn, 1e-4)
        XCTAssertLessThan(worstParticle, 1e-3)
    }

    func testGPUParticlesSettleInTheBinAndTheClothDrapes() throws {
        let (scene, gpu, run) = try gpuScene(bodies: 0, particles: 2048)
        run(240, false)
        let all = gpu.readParticles()
        let particles = all.filter { $0.info.y & PhysicsWorld.clothBit == 0 }
        XCTAssertEqual(particles.count, 2048)
        var inBin = 0, fastest: Float = 0
        for q in all {
            let p = PhysicsMath.xyz(q.position)
            XCTAssertFalse(p.x.isNaN)
            XCTAssertGreaterThan(p.y, q.position.w - 0.005, "a particle sank into the floor")
            XCTAssertLessThan(simd_reduce_max(abs(p)), 7, "a particle left the room")
            fastest = max(fastest, length(PhysicsMath.xyz(q.velocity)))
        }
        for q in particles where abs(q.position.x + 2.4) < 0.6 && abs(q.position.z - 2.3) < 0.6 { inBin += 1 }
        print("GPU particles after 4 s: \(inBin) of 2048 in the bin, the fastest particle or cloth vertex at \(fastest) m/s")
        XCTAssertGreaterThan(inBin, 1024, "most of them should land in the bin")
        XCTAssertLessThan(fastest, 1, "they should have come to rest")
        // The cloth: over the ball, not through it, and not stretched.
        let ball = SIMD3<Float>(0.9, 0.42, 2.25)
        let world = scene.physics!
        for q in all where q.info.y & PhysicsWorld.clothBit != 0 {
            XCTAssertGreaterThan(length(PhysicsMath.xyz(q.position) - ball), 0.42 + q.position.w - 0.005, "a cloth vertex is in the ball")
        }
        var stretch: Float = 0
        for k in world.constraints where k.compliance == 0 {
            let l = length(PhysicsMath.xyz(all[Int(k.a)].position) - PhysicsMath.xyz(all[Int(k.b)].position))
            stretch = max(stretch, abs(l - k.rest) / k.rest)
        }
        XCTAssertLessThan(stretch, 0.1, "the cloth stretched")
    }

    func testGPURunsAreTheSame() throws {
        let (_, gpu, run) = try gpuScene(bodies: 96, particles: 2048)
        run(120, false)
        let first = gpu.readBodies(), firstParticles = gpu.readParticles()
        run(120, true)
        for (a, b) in zip(first, gpu.readBodies()) {
            XCTAssertEqual(a.position, b.position)
            XCTAssertEqual(a.rotation, b.rotation)
            XCTAssertEqual(a.velocity, b.velocity)
        }
        for (a, b) in zip(firstParticles, gpu.readParticles()) {
            XCTAssertEqual(a.position, b.position)
            XCTAssertEqual(a.velocity, b.velocity)
        }
    }
}
