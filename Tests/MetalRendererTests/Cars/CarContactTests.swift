import XCTest
import Metal
import simd
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// CarContacts.swift and the cars' knocks on what they meet: cars against cars (head on, side on), a part that came
/// off against its own car, loose props pushed, a fractured wall broken.
final class CarContactTests: XCTestCase {
    private func run(_ w: PhysicsWorld, _ seconds: Float) { w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2) }

    /// A scene with nothing of its own and a floor, its world at the cars' 16 substeps (for fractured objects and
    /// bodies drawn as a scene's).
    private func scene() -> Scene {
        var settings = SceneSettings(kind: .cornell)
        settings.physics.substeps = 16
        let s = Scene(settings)
        s.addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        return s
    }

    /// A world with a floor and cars of `spec`, each placed by its transform and moving at its velocity.
    private func world(_ cars: [(float4x4, SIMD3<Float>)], spec: CarSpec = .preset(.panamera)) -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        for (k, (place, velocity)) in cars.enumerated() {
            w.addCar(CarBlueprint(spec), transform: place, rimSDF: 100 + k, wheelInstances: [0, 0, 0, 0], velocity: velocity)
        }
        w.finish()
        return w
    }

    /// The cars' momentum (their nodes' and wheels'), kg m/s.
    private func momentum(_ w: PhysicsWorld) -> SIMD3<Float> {
        var p = SIMD3<Float>()
        for s in w.carSystem.cars {
            for i in Int(s.firstNode)..<Int(s.firstNode + s.nodeCount) where w.particles[i].prevPosition.w > 0 {
                p += PhysicsMath.xyz(w.particles[i].velocity) / w.particles[i].prevPosition.w
            }
            for k in Int(s.firstWheel)..<Int(s.firstWheel + s.wheelCount) {
                let o = w.bodies[Int(w.carSystem.wheels[k].body)]
                p += PhysicsMath.xyz(o.velocity) / o.position.w
            }
        }
        return p
    }

    /// The nodes of car `c`'s body (its parts' left out) furthest along `axis`, and least.
    private func extent(_ w: PhysicsWorld, _ c: Int, _ axis: SIMD3<Float>) -> (lo: Float, hi: Float) {
        let s = w.carSystem.cars[c]
        let along = (Int(s.firstNode)..<Int(s.firstNode + s.ringNodes)).map { dot(PhysicsMath.xyz(w.particles[$0].position), axis) }
        return (along.min()!, along.max()!)
    }

    /// Two sedans head on at 50 km/h each: both fronts crushed and about as many beams bent (within 15%: how far each
    /// front is pushed back depends on how it buckles, which the least difference between the two tips one way or the
    /// other), neither through the other, the two stopped, their momentum kept (within 5% of one car's).
    func testHeadOnIsSymmetric() {
        let v: Float = 50 / 3.6
        let turn = float4x4(simd_quatf(angle: .pi, axis: [0, 1, 0]))
        let w = world([(translate([0, 0, -3]), [0, 0, v]), (translate([0, 0, 3]) * turn, [0, 0, -v])])
        let before = momentum(w), one = w.carSystem.cars[0].mass * v
        run(w, 2)
        let a = w.carTelemetry(0), b = w.carTelemetry(1), after = momentum(w)
        let gap = extent(w, 1, [0, 0, 1]).lo - extent(w, 0, [0, 0, 1]).hi
        print(String(format: "head on: front crushed %.2f / %.2f m, bent %d / %d, speeds %.2f / %.2f, momentum %.0f -> %.0f (one car %.0f), the fronts' gap %.2f m",
                     a.frontCrush, b.frontCrush, a.bent, b.bent, a.speed, b.speed, length(before), length(after), one, gap))
        XCTAssertGreaterThan(min(a.frontCrush, b.frontCrush), 0.3)
        XCTAssertEqual(Float(a.bent), Float(b.bent), accuracy: 0.15 * Float(max(a.bent, b.bent)))
        XCTAssertLessThan(length(after - before), 0.05 * one)
        XCTAssertGreaterThan(gap, -0.15, "a car went into the other")
        XCTAssertLessThan(abs(a.speed) + abs(b.speed), 2)
    }

    /// A sedan into another's side at 40 km/h: the struck car is shoved sideways and dented, the striking car's front
    /// crushed, and it doesn't go through.
    func testSideImpact() {
        let v: Float = 40 / 3.6
        let across = float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))   // (its front toward +x)
        let w = world([(translate([-5, 0, 0]) * across, [v, 0, 0]), (matrix_identity_float4x4, .zero)])
        let start = w.carTelemetry(1).position
        run(w, 2)
        let a = w.carTelemetry(0), b = w.carTelemetry(1)
        let gap = extent(w, 1, [1, 0, 0]).lo - extent(w, 0, [1, 0, 0]).hi
        print(String(format: "side: striker crushed %.2f m, bent %d; struck moved %.2f m, bent %d; gap %.2f m", a.frontCrush, a.bent,
                     b.position.x - start.x, b.bent, gap))
        XCTAssertGreaterThan(b.position.x - start.x, 0.3)
        XCTAssertGreaterThan(b.bent, 10)
        XCTAssertGreaterThan(gap, -0.2, "the striker went into the other")
    }

    /// A hood come off (its attachments broken at the start) lies on its car: it neither falls through it nor slides
    /// off a car standing still.
    func testAPartLiesOnItsCar() {
        let w = world([(matrix_identity_float4x4, .zero)])
        let s = w.carSystem.cars[0]
        let hood = (Int(s.firstPart)..<Int(s.firstPart + s.partCount)).first { w.carSystem.parts[$0].kind == CarPartKind.hood.rawValue }!
        for k in Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount) where w.carSystem.beams[k].part == hood - Int(s.firstPart) + 1
            && w.carSystem.beams[k].info & CarBeam.attachBit != 0 {
            w.carSystem.beams[k].info |= CarBeam.brokenBit
        }
        let part = w.carSystem.parts[hood]
        func height() -> Float {
            (Int(part.firstNode)..<Int(part.firstNode + part.nodeCount)).map { w.particles[$0].position.y }.reduce(0, +) / Float(part.nodeCount)
        }
        let start = height()
        run(w, 3)
        print(String(format: "hood: flags %d, height %.2f -> %.2f m", w.carSystem.parts[hood].flags, start, height()))
        XCTAssertNotEqual(w.carSystem.parts[hood].flags & CarPart.off, 0)
        XCTAssertEqual(height(), start, accuracy: 0.12)
    }

    /// Into a stack of loose crates at 30 km/h: they're shoved on; the car isn't stopped dead.
    func testPropsArePushed() {
        let s = scene()
        let w = s.physicsWorld()
        let crate = s.addSDFShape(SDFShape(.box(halfExtents: [0.4, 0.4, 0.4], rounding: 0.02)))
        let first = w.bodies.count
        for k in 0..<3 { s.addBody(sdf: crate, 0, translate([Float(k) * 0.82 - 0.82, 0.4, 6]), density: 300, friction: 0.6, restitution: 0.05) }
        w.addCar(CarBlueprint(.preset(.civic)), transform: matrix_identity_float4x4, rimSDF: 100, wheelInstances: [0, 0, 0, 0], velocity: [0, 0, 30 / 3.6])
        w.finish()
        run(w, 2)
        let moved = (first..<first + 3).map { w.bodies[$0].position.z - 6 }
        print("crates moved \(moved) m, the car at \(w.carTelemetry(0).speed * 3.6) km/h")
        XCTAssertGreaterThan(moved.max()!, 1)
        XCTAssertGreaterThan(w.carTelemetry(0).speed, 1)
    }

    /// A car standing on a loose platform (a body) pulls away: its tyres carry it there (their loads the car's weight,
    /// not its rims'), and push the platform back as they drive it forward.
    func testTyresStandOnBodies() {
        let s = scene()
        let w = s.physicsWorld()
        let deck = w.bodies.count
        s.addBody(sdf: s.addSDFShape(SDFShape(.box(halfExtents: [1.5, 0.1, 4]))), 0, translate([0, 0.1, 1]), density: 150, friction: 0.9, restitution: 0)
        w.addCar(CarBlueprint(.preset(.civic)), transform: translate([0, 0.2, 0]), rimSDF: 100, wheelInstances: [0, 0, 0, 0])
        w.finish()
        run(w, 1)
        let loads = w.carSystem.wheels.map(\.load).reduce(0, +), weight = w.carSystem.cars[0].mass * 9.81
        var input = CarInput()
        input.accelerate = 1
        w.add(PhysicsWorld.carCommand(0, input))
        run(w, 1)
        print(String(format: "on the platform: tyre loads %.0f N (weight %.0f), the platform at %.2f m/s, the car at %.2f m/s", loads, weight,
                     w.bodies[deck].velocity.z, w.carTelemetry(0).speed))
        XCTAssertEqual(loads, weight, accuracy: 0.25 * weight)
        XCTAssertLessThan(w.bodies[deck].velocity.z, -0.1)
        XCTAssertGreaterThan(w.carTelemetry(0).speed, 1)
    }

    /// Into a brick wall standing on the ground at 40 km/h: it breaks (its pieces come free, their breaks logged) and
    /// the car goes on through what is left, slowed.
    func testABrickWallBreaks() {
        let s = scene()
        var r = FractureRecipe.defaults(.brick)
        r.brick = [0.4, 0.16, 0.22]
        r.seed = 21
        let f = s.addFractured("bricks", shape: SDFShape(.box(halfExtents: [1.6, 0.88, 0.11])), recipe: r, transform: translate([0, 0.88, 7]),
                               material: 0, interior: 0, anchor: .ground(0))
        let w = s.physicsWorld()
        w.addCar(CarBlueprint(.preset(.civic)), transform: matrix_identity_float4x4, rimSDF: 100, wheelInstances: [0, 0, 0, 0], velocity: [0, 0, 40 / 3.6])
        w.finish()
        run(w, 2.5)
        var free = 0
        for k in f.tree.nodes.indices {
            let o = w.bodies[f.firstBody + k]
            if o.info.y & PhysicsWorld.disabledBit == 0 && o.position.w > 0 { free += 1 }
        }
        let t = w.carTelemetry(0), bricks = w.breakLog.filter { UInt32($0.velocity.w) == UInt32(FractureMaterial.brick.rawValue) }.count
        print(String(format: "brick wall: %d pieces free, %d breaks logged; the car at %.1f km/h, z %.2f, bent %d", free, bricks, t.speed * 3.6, t.position.z, t.bent))
        XCTAssertGreaterThan(free, 5)
        XCTAssertGreaterThan(bricks, 0)
        XCTAssertLessThan(t.speed, 40 / 3.6)
    }

    /// The head-on crash on one core as on all of them, and a replay from the start the same, bit for bit.
    func testContactsAreDeterministic() {
        let v: Float = 50 / 3.6
        let turn = float4x4(simd_quatf(angle: .pi, axis: [0, 1, 0]))
        func crash(everyCore: Bool) -> [SIMD4<Float>] {
            let w = world([(translate([0, 0, -3]), [0, 0, v]), (translate([0, 0, 3]) * turn, [0, 0, -v])])
            PhysicsPool.shared.enabled = everyCore
            defer { PhysicsPool.shared.enabled = true }
            run(w, 1)
            let first = w.particles.map(\.position)
            w.advance(to: 0)
            run(w, 1)
            XCTAssertEqual(w.particles.map(\.position), first, "the replay")
            return first
        }
        XCTAssertEqual(crash(everyCore: false), crash(everyCore: true))
    }
}
