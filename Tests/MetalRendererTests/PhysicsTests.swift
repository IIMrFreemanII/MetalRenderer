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

    // MARK: At rest

    /// Over `seconds` from now: how far each body strays from where it is now at most, and how often bodies wake.
    private func stillness(_ w: PhysicsWorld, _ seconds: Float) -> (strays: [Float], wakes: Int) {
        let start = w.bodies.map { PhysicsMath.xyz($0.position) }
        var strays = [Float](repeating: 0, count: w.bodies.count), wakes = 0
        for _ in 0..<Int(seconds / PhysicsWorld.stepLength) {
            let asleep = w.bodies.map { $0.info.y & PhysicsWorld.asleep != 0 }
            w.step()
            for (i, b) in w.bodies.enumerated() {
                strays[i] = max(strays[i], length(PhysicsMath.xyz(b.position) - start[i]))
                if asleep[i] && b.info.y & PhysicsWorld.asleep == 0 { wakes += 1 }
            }
        }
        return (strays, wakes)
    }

    private func percentile(_ values: [Float], _ p: Float) -> Float {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(Int(Float(sorted.count) * p), sorted.count - 1)]
    }

    private func asleep(_ w: PhysicsWorld) -> Int { w.bodies.filter { $0.info.y & PhysicsWorld.asleep != 0 }.count }

    func testThePileComesToRest() {
        // The physics scene's 96 bodies (no particles, no cloth): after 10 s they lie still, and asleep.
        var settings = SceneSettings(kind: .physics)
        settings.physics.particles = 0
        settings.physics.cloth = 0
        settings.physics.backend = .cpu
        let w = Scene(settings).physics!
        run(w, 10)
        let (strays, wakes) = stillness(w, 2)
        print(String(format: "pile from 10 s to 12 s: %d of %d asleep, strays p50 %.2g p95 %.2g max %.2g m, %d wakes",
                     asleep(w), w.bodies.count, percentile(strays, 0.5), percentile(strays, 0.95), strays.max()!, wakes))
        XCTAssertGreaterThanOrEqual(asleep(w), w.bodies.count * 95 / 100, "the pile should be asleep")
        XCTAssertLessThan(percentile(strays, 0.95), 1e-3, "resting bodies moved")
        XCTAssertLessThanOrEqual(wakes, 2)
    }

    /// The physics scene's body shapes.
    private static let sceneShapes: [SDFShape] = [
        SDFShape(.sphere(radius: 0.22)),
        SDFShape(.box(halfExtents: [0.2, 0.2, 0.2], rounding: 0.02)),
        SDFShape(.capsule(halfLength: 0.18, radius: 0.12)),
        SDFShape(.cylinder(halfHeight: 0.16, radius: 0.2, rounding: 0.03)),
        SDFShape(.cone(halfHeight: 0.2, bottom: 0.22, top: 0.06)),
        SDFShape(.torus(major: 0.18, minor: 0.07)),
        SDFShape([SDFShape.Node(.box(halfExtents: [0.21, 0.21, 0.21], rounding: 0.02)), SDFShape.Node(.sphere(radius: 0.27), .subtract)]),
        SDFShape([SDFShape.Node(.sphere(radius: 0.17), at: [-0.08, 0, 0]),
                  SDFShape.Node(.sphere(radius: 0.13), smooth: 0.12, at: [0.14, 0.05, 0]),
                  SDFShape.Node(.sphere(radius: 0.1), smooth: 0.1, at: [0, 0.17, 0.04])]),
    ]

    func testEveryShapeSettles() {
        // Each of the scene's shapes, in a few turns, dropped 5 cm onto the floor and onto a box: each comes to rest
        // and sleeps, rather than rocking on.
        let w = world()
        var random = SplitMix(seed: 3)
        let shapes = PhysicsTests.sceneShapes
        var dropped: [Int] = []
        for (s, shape) in shapes.enumerated() {
            for turn in 0..<4 {
                let axis = normalize(SIMD3<Float>(random.float() - 0.5, random.float() - 0.5, random.float() - 0.5) + 1e-3)
                let at = SIMD3<Float>(Float(s) * 1.2 - 4, 0, Float(turn) * 2.4 - 4)
                dropped.append(w.addBody(sdf: s, shape, transform: translate(at + [0, 0.45 + 0.05, 0]) * rotate(random.float() * 6, axis),
                                         instance: dropped.count, friction: 0.45, restitution: 0.25))
                // On a box, a little further back.
                w.addBody(sdf: shapes.count, SDFShape(.box(halfExtents: [0.3, 0.2, 0.3], rounding: 0.02)),
                          transform: translate(at + [0, 0.2, 1.2]), instance: 1000 + dropped.count, density: 600, friction: 0.45, restitution: 0.05)
                dropped.append(w.addBody(sdf: s, shape, transform: translate(at + [0, 0.4 + 0.45 + 0.05, 1.2]) * rotate(random.float() * 6, axis),
                                         instance: dropped.count, friction: 0.45, restitution: 0.25))
            }
        }
        w.finish()
        var sleptAt = [Float?](repeating: nil, count: w.bodies.count)
        var late = [Float](repeating: 0, count: w.bodies.count)   // fastest after 3 s
        for _ in 0..<Int(6 / PhysicsWorld.stepLength) {
            w.step()
            for (i, b) in w.bodies.enumerated() {
                let asleep = b.info.y & PhysicsWorld.asleep != 0
                if asleep && sleptAt[i] == nil { sleptAt[i] = w.time }
                if !asleep { sleptAt[i] = nil }
                if w.time > 3 { late[i] = max(late[i], length(PhysicsMath.xyz(b.velocity))) }
            }
        }
        for s in shapes.indices {
            let mine = dropped.indices.filter { $0 / 8 == s }.map { dropped[$0] }
            let times = mine.map { sleptAt[$0].map { String(format: "%.1f", $0) } ?? "-" }
            print(String(format: "shape %d: asleep at %@; fastest after 3 s %.3f m/s", s, times.joined(separator: " "),
                         mine.map { late[$0] }.max()!))
            XCTAssertGreaterThanOrEqual(mine.filter { sleptAt[$0] != nil }.count, 7, "shape \(s) doesn't settle")
        }
    }

    /// The scene's tower: 8 layers of 3 blocks, crossed (bodies 0...23, SDF shape 0).
    private func addTower(_ w: PhysicsWorld) {
        let block = SDFShape(.box(halfExtents: [0.36, 0.12, 0.12], rounding: 0.015))
        for layer in 0..<8 {
            for k in 0..<3 {
                let offset = (Float(k) - 1) * 0.25, along = layer % 2 == 0
                let p = SIMD3<Float>(along ? 0 : offset, 0.12 + 0.24 * Float(layer), along ? offset : 0)
                w.addBody(sdf: 0, block, transform: translate(p) * rotate(along ? 0 : .pi / 2, [0, 1, 0]), instance: layer * 3 + k,
                          density: 600, friction: 0.6, restitution: 0.05)
            }
        }
    }

    func testTowerStandsStill() {
        let w = world()
        addTower(w)
        w.finish()
        run(w, 3)
        let top = w.bodies.count - 2, rotation = w.bodies[top].rotation
        var sleptAt: Float?
        let start = position(w, top)
        for _ in 0..<Int(7 / PhysicsWorld.stepLength) {
            w.step()
            if sleptAt == nil && asleep(w) == w.bodies.count { sleptAt = w.time }
        }
        let drift = length(position(w, top) - start), turn = 2 * acos(min(abs(dot(w.bodies[top].rotation, rotation)), 1))
        print(String(format: "tower from 3 s to 10 s: top drifted %.2g m, turned %.2g rad; all asleep at %@", drift, turn,
                     sleptAt.map { String(format: "%.2f s", $0) } ?? "never"))
        XCTAssertLessThan(drift, 1e-3)
        XCTAssertLessThan(turn, 1e-3)
        XCTAssertNotNil(sleptAt, "the tower never fell asleep")
    }

    func testABoxOnARampDoesNotCreep() {
        // A box on a 20 degree slope with friction 0.6 (tan 20 = 0.36): once it has landed it doesn't move.
        let w = PhysicsWorld(substeps: 16)
        let angle: Float = 20 * .pi / 180
        let normal = SIMD3<Float>(sin(angle), cos(angle), 0)
        w.addPlane(point: .zero, normal: normal, friction: 0.6)
        w.addBody(sdf: 0, SDFShape(.box(halfExtents: [0.3, 0.2, 0.3])), transform: translate(normal * 0.2) * rotate(-angle, [0, 0, 1]),
                  instance: 0, friction: 0.6, restitution: 0)
        w.finish()
        run(w, 0.5)
        let start = position(w, 0)
        run(w, 5)
        let crept = length(position(w, 0) - start)
        print(String(format: "box on a ramp from 0.5 s to 5.5 s: crept %.2g m, asleep: %@", crept, asleep(w) == 1 ? "yes" : "no"))
        XCTAssertLessThan(crept, 1e-3)
        XCTAssertEqual(asleep(w), 1, "the box never fell asleep")
    }

    func testAParticleHeapComesToRest() {
        let w = world()
        pour(w, count: 512, radius: 0.05)
        w.finish()
        run(w, 6)
        let speeds = w.particles.map { length(PhysicsMath.xyz($0.velocity)) }
        print(String(format: "particle heap at 6 s: speed p50 %.2g p95 %.2g max %.2g m/s", percentile(speeds, 0.5),
                     percentile(speeds, 0.95), speeds.max()!))
        XCTAssertLessThan(percentile(speeds, 0.95), 0.05, "the heap fizzes")
    }

    // MARK: Grabbing

    /// Body `i`'s grab anchor in the world.
    private func anchor(_ w: PhysicsWorld, _ i: Int) -> SIMD3<Float> {
        position(w, i) + PhysicsMath.qrot(w.bodies[i].rotation, PhysicsMath.xyz(w.grab.anchor))
    }

    func testPickingFindsTheBodyUnderTheRay() {
        let w = world()
        w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.3)), transform: translate([0, 0.5, 0]), instance: 0)
        w.addBody(sdf: 1, SDFShape(.box(halfExtents: [0.4, 0.2, 0.3])), transform: translate([2, 0.5, 0]) * rotate(0.5, [0, 1, 0]),
                  instance: 1)
        w.finish()
        let down = SIMD3<Float>(0, -1, 0)
        let ball = try! XCTUnwrap(w.pick(origin: [0, 5, 0], direction: down))
        XCTAssertEqual(ball.body, 0)
        XCTAssertEqual(ball.distance, 5 - 0.8, accuracy: 1e-3)
        XCTAssertEqual(ball.anchor.y, 0.3, accuracy: 1e-3)
        let box = try! XCTUnwrap(w.pick(origin: [2.1, 5, 0.1], direction: down))
        XCTAssertEqual(box.body, 1)
        XCTAssertEqual(box.distance, 5 - 0.7, accuracy: 1e-3)
        XCTAssertEqual(box.anchor.y, 0.2, accuracy: 1e-3)
        // From the side, the box hides nothing; past both, nothing.
        XCTAssertEqual(w.pick(origin: [-3, 0.5, 0], direction: [1, 0, 0])?.body, 0)
        XCTAssertNil(w.pick(origin: [5, 5, 0], direction: down))
    }

    func testAGrabLiftsABodyAndLetsGo() {
        let w = world()
        w.addBody(sdf: 0, SDFShape(.box(halfExtents: [0.3, 0.2, 0.25])), transform: translate([0, 0.2, 0]), instance: 0, restitution: 0)
        w.finish()
        run(w, 1)
        XCTAssertNotEqual(w.bodies[0].info.y & PhysicsWorld.asleep, 0, "it should rest before it is grabbed")
        // By its top face, 1 m up.
        w.grab = GPUPhysicsGrab(target: SIMD4(0, 1.4, 0, 1), anchor: SIMD4(0, 0.2, 0, 0), body: 0)
        run(w, 1)
        XCTAssertLessThan(length(anchor(w, 0) - [0, 1.4, 0]), 0.03, "it doesn't follow: anchor at \(anchor(w, 0))")
        XCTAssertEqual(w.bodies[0].info.y & PhysicsWorld.asleep, 0)
        // Let go: it falls back flat (held by its top face's middle, it hangs level) and sleeps.
        w.grab.target.w = 0
        run(w, 3)
        XCTAssertEqual(position(w, 0).y, 0.2, accuracy: 3e-3)
        XCTAssertNotEqual(w.bodies[0].info.y & PhysicsWorld.asleep, 0, "it never fell asleep again")
    }

    func testDraggingABodyIntoTheTowerKnocksItOver() {
        let w = world()
        addTower(w)
        let box = w.addBody(sdf: 1, SDFShape(.box(halfExtents: [0.2, 0.2, 0.2])), transform: translate([-1.5, 0.2, 0]), instance: 100,
                            density: 800)
        w.finish()
        run(w, 3)
        let before = (0..<24).map { position(w, $0) }
        // Lifted to the middle of the tower and swept through it, 2 m in 1.5 s.
        w.grab = GPUPhysicsGrab(target: SIMD4(-1.5, 0.9, 0, 1), anchor: SIMD4(0, 0, 0, 0), body: UInt32(box))
        run(w, 0.5)
        for step in 0..<90 {
            w.grab.target = SIMD4(-1.5 + 3 * Float(step + 1) / 90, 0.9, 0, 1)
            w.step()
        }
        w.grab.target.w = 0
        run(w, 1)
        let moved = (0..<24).map { length(position(w, $0) - before[$0]) }.max()!
        XCTAssertGreaterThan(moved, 0.3, "the tower stood: its blocks moved \(moved) m at most")
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
        let pipelines = try Pipelines(device: device, source: PhysicsTests.shaders, lightTypes: 0x3F, stats: false)
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
        // The tower's blocks, placed touching, settle by a few mm, and the two differ by 0.08 mm after the first step
        // (float rounding); as each body keeps its nearest partners, that much can change which, and the towers part
        // by 2.4 mm in 30 steps (0.5 mm when the lowest-numbered were kept).
        XCTAssertLessThan(worst, 5e-3)
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

    func testGPUPileComesToRest() throws {
        // The pile and what falls off the ramp later (a body rolling into it at 15 s) settle by 20 s.
        let (_, gpu, run) = try gpuScene(bodies: 96)
        run(1200, false)
        let before = gpu.readBodies()
        run(120, false)
        let after = gpu.readBodies()
        let asleep = after.filter { $0.info.y & PhysicsWorld.asleep != 0 }.count
        var strays: [Float] = []
        for (a, b) in zip(before, after) { strays.append(length(PhysicsMath.xyz(a.position) - PhysicsMath.xyz(b.position))) }
        print(String(format: "GPU pile from 20 s to 22 s: %d of %d asleep, strays p95 %.2g max %.2g m", asleep, after.count,
                     percentile(strays, 0.95), strays.max()!))
        XCTAssertGreaterThanOrEqual(asleep, after.count * 95 / 100, "the pile should be asleep")
        XCTAssertLessThan(percentile(strays, 0.95), 1e-3, "resting bodies moved")
    }

    func testGPUHoldMatchesTheCPU() throws {
        let (scene, gpu, run) = try gpuScene(bodies: 48)
        let world = scene.physics!
        // The heavy ball (body 12, after the 4 layers' blocks), rolling at the tower, then held by a point off its
        // centre and lifted.
        let ball = 12, grab = GPUPhysicsGrab(target: SIMD4(-1.5, 1.6, -0.6, 1), anchor: SIMD4(0.1, 0.2, 0, 0), body: UInt32(ball))
        func runGPU(reset: Bool) -> GPUPhysicsBody {
            gpu.setGrab(slot: 0, GPUPhysicsGrab())
            run(20, reset)
            gpu.setGrab(slot: 0, grab)
            run(30, false)
            return gpu.readBodies()[ball]
        }
        let g = runGPU(reset: false)
        for _ in 0..<20 { world.step() }
        world.grab = grab
        for _ in 0..<30 { world.step() }
        let c = world.bodies[ball]
        XCTAssertLessThan(length(PhysicsMath.xyz(g.position) - PhysicsMath.xyz(c.position)), 1e-3)
        XCTAssertLessThan(1 - abs(dot(g.rotation, c.rotation)), 1e-4)
        XCTAssertGreaterThan(c.position.y, 0.6, "the ball isn't lifted")
        // The same again from the start: the same bits.
        let again = runGPU(reset: true)
        XCTAssertEqual(again.position, g.position)
        XCTAssertEqual(again.rotation, g.rotation)
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



