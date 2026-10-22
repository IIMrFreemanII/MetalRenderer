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

/// Physics+Cars.swift and the files beside it: node-beam cars that stand on their springs, drive, brake, turn, and
/// keep their dents.
final class CarTests: XCTestCase {
    /// A world with a floor and car(s) of `styles` side by side (4 m apart), facing +z, `speed` m/s.
    private func world(_ styles: [CarStyle] = [.sedan], speed: Float = 0, wall: Float? = nil) -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        if let wall {
            let shape = SDFShape(.box(halfExtents: [6, 1.5, 0.5]))
            w.addStatic(sdf: 90, shape, transform: translate([0, 1.5, wall + 0.5]), friction: 0.6, restitution: 0.1)
        }
        for (k, style) in styles.enumerated() {
            let b = CarBlueprint(CarSpec.preset(style))
            w.addCar(b, transform: translate([Float(k) * 4, 0, 0]), rimSDF: 100 + k, wheelInstances: [0, 0, 0, 0], velocity: [0, 0, speed])
        }
        w.finish()
        return w
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) { w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2) }

    private func drive(_ w: PhysicsWorld, car: Int = 0, accelerate: Float = 0, decelerate: Float = 0, steer: Float = 0, handbrake: Float = 0) {
        var input = CarInput()
        input.accelerate = accelerate
        input.decelerate = decelerate
        input.steer = steer
        input.handbrake = handbrake
        w.add(PhysicsWorld.carCommand(car, input))
    }

    private func frame(_ w: PhysicsWorld, _ car: Int = 0) -> CarTelemetry { w.carTelemetry(car) }

    private func length(_ w: PhysicsWorld, car: Int = 0) -> Float {
        let s = w.carSystem.cars[car]
        let nodes = (Int(s.firstNode)..<Int(s.firstNode + s.nodeCount)).map { PhysicsMath.xyz(w.particles[$0].position) }
        let f = frame(w, car)
        let along = nodes.map { dot($0, f.forward) }
        return along.max()! - along.min()!
    }

    // MARK: The blueprint

    /// Every style's blueprint: about 200 to 330 nodes, every node in three beams or more, no beam of zero length, its
    /// mass the spec's.
    func testBlueprintsAreWellFormed() {
        for style in CarStyle.allCases {
            let spec = CarSpec.preset(style), b = CarBlueprint(spec)
            XCTAssert((180...330).contains(b.nodes.count), "\(style): \(b.nodes.count) nodes")
            var degree = [Int](repeating: 0, count: b.nodes.count)
            for beam in b.beams {
                degree[beam.a] += 1
                degree[beam.b] += 1
                XCTAssertGreaterThan(simd_distance(b.nodes[beam.a], b.nodes[beam.b]), 0.01, "\(style): a beam of no length")
            }
            XCTAssertGreaterThanOrEqual(degree.min()!, 3, "\(style): a node in fewer than 3 beams")
            let mass = b.bodyMass + 4 * spec.wheelMass
            XCTAssertEqual(mass, spec.mass, accuracy: spec.mass * 0.02, "\(style)")
            print("\(style): \(b.nodes.count) nodes, \(b.beams.count) beams, \(b.hull.count) hull triangles")
        }
    }

    // MARK: Standing and driving

    /// A car let go at its ride height settles on its springs within 3 s, its floor within 1.5 cm of where it began, no
    /// beam bent.
    func testItSettlesAtRideHeight() {
        for style in CarStyle.allCases {
            let w = world([style])
            let start = frame(w).position.y
            run(w, 3)
            let t = frame(w)
            print("\(style): floor \(start) -> \(t.position.y), up \(t.up), speed \(t.speed), bent \(t.bent)")
            XCTAssertEqual(t.position.y, start, accuracy: 0.015, "\(style)")
            XCTAssertEqual(t.bent, 0, "\(style)")
            XCTAssertGreaterThan(t.up.y, 0.999, "\(style)")
        }
    }

    /// Full throttle from a stop: 100 km/h in each style's time, the car keeping straight.
    func testItAccelerates() {
        let windows: [CarStyle: ClosedRange<Float>] = [.sedan: 5.5...10, .hatchback: 7...13, .pickup: 6...12, .coupe: 4...8]
        for style in CarStyle.allCases {
            let w = world([style])
            run(w, 1)
            drive(w, accelerate: 1)
            var reached: Float?
            var t: Float = 0
            while t < 20 && reached == nil {
                run(w, 0.25)
                t += 0.25
                if frame(w).speed >= 100 / 3.6 { reached = t }
            }
            let f = frame(w)
            print("\(style): 0-100 \(reached ?? -1) s, gear \(f.gear), rpm \(f.rpm), heading \(f.forward)")
            XCTAssert(reached.map { windows[style]!.contains($0) } ?? false, "\(style): \(reached ?? -1) s")
            XCTAssertGreaterThan(f.forward.z, 0.995, "\(style) went off line")
        }
    }

    /// Braking from 100 km/h: stopped in 36 to 47 m (about 0.85 g or more with ABS, the pedal's ramp included), straight.
    func testItBrakes() {
        let w = world([.sedan], speed: 100 / 3.6)
        run(w, 0.1)
        drive(w, decelerate: 1)
        let start = frame(w).position.z
        var t: Float = 0
        while frame(w).speed > 0.3 && t < 8 {
            run(w, 0.05)
            t += 0.05
        }
        let f = frame(w)
        print("stopped in \(f.position.z - start) m, \(t) s, heading \(f.forward)")
        XCTAssert((36...47).contains(f.position.z - start), "\(f.position.z - start) m")
        XCTAssertGreaterThan(f.forward.z, 0.99, "it slewed")
    }

    /// Steering left at 40 km/h turns the car left (toward +x), and it grips: 0.5 g or more round the turn.
    func testItTurns() {
        let w = world([.sedan], speed: 40 / 3.6)
        run(w, 0.1)
        var input = CarInput()
        input.autopilot = false
        drive(w, accelerate: 0.3, steer: 1)
        run(w, 2)
        let f = frame(w)
        let omega = atan2(f.forward.x, f.forward.z) / 2
        print("heading \(f.forward), speed \(f.speed), lateral \(abs(f.speed * omega) / 9.81) g")
        XCTAssertGreaterThan(f.forward.x, 0.3)
        XCTAssertGreaterThan(abs(f.speed * omega) / 9.81, 0.5)
    }

    /// Into a wall at 50 km/h: the front crushed 0.3 to 0.6 m and bent for good, the cabin (its floor between the axles)
    /// within 5 cm of its length, the car stopped. At 100 km/h, more crushed.
    func testAWallCrushesTheFront() {
        var crushed: [Float] = []
        for kmh: Float in [50, 100] {
            let w = world([.sedan], speed: kmh / 3.6, wall: 4)
            let s = w.carSystem.cars[0]
            func cabin() -> Float { simd_distance(PhysicsMath.xyz(w.particles[Int(s.frame.x)].position), PhysicsMath.xyz(w.particles[Int(s.frame.y)].position)) }
            let before = length(w), cabin0 = cabin()
            run(w, 2)
            let f = frame(w), after = length(w)
            print("\(kmh) km/h: length \(before) -> \(after), cabin \(cabin0) -> \(cabin()), bent \(f.bent), broken \(f.broken), speed \(f.speed)")
            crushed.append(before - after)
            XCTAssertLessThan(abs(f.speed), 1)
            XCTAssertGreaterThan(f.bent, 20)
            if kmh == 50 {
                XCTAssert((0.3...0.6).contains(before - after), "crushed \(before - after) m")
                XCTAssertEqual(cabin(), cabin0, accuracy: 0.05)
            }
        }
        XCTAssertGreaterThan(crushed[1], crushed[0] + 0.15)
    }

    /// A plastic beam: a car dropped onto its wheels from 5 cm bends nothing; dropped on its roof from 1 m it keeps a
    /// dent; a replay from the start is the same, bit for bit.
    func testDentsStayAndReplay() {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        w.addCar(CarBlueprint(CarSpec.preset(.hatchback)), transform: translate([0, 0.05, 0]), rimSDF: 100, wheelInstances: [0, 0, 0, 0])
        let roof = float4x4(simd_quatf(angle: .pi, axis: [0, 0, 1]))
        w.addCar(CarBlueprint(CarSpec.preset(.hatchback)), transform: translate([5, 2.5, 0]) * roof, rimSDF: 101, wheelInstances: [0, 0, 0, 0])
        w.finish()
        run(w, 2)
        let dropped = w.carTelemetry(0), flipped = w.carTelemetry(1)
        print("dropped bent \(dropped.bent), flipped bent \(flipped.bent) broken \(flipped.broken)")
        XCTAssertEqual(dropped.bent, 0)
        XCTAssertGreaterThan(flipped.bent, 5)
        let nodes = w.particles
        w.advance(to: 0)
        w.advance(to: 2 + PhysicsWorld.stepLength / 2)
        XCTAssertEqual(w.particles.map(\.position), nodes.map(\.position))
    }

    /// The steps are the same on one core as on all of them, with a car's input commands.
    func testThreadsAgree() {
        func run(everyCore: Bool) -> [SIMD4<Float>] {
            let w = world([.sedan, .coupe, .pickup])
            PhysicsPool.shared.enabled = everyCore
            defer { PhysicsPool.shared.enabled = true }
            var input = CarInput()
            input.accelerate = 1
            input.steer = 0.5
            w.add(PhysicsWorld.carCommand(1, input, at: 30))
            w.advance(to: 2)
            return w.particles.map(\.position) + w.bodies.map(\.position)
        }
        XCTAssertEqual(run(everyCore: false), run(everyCore: true))
    }

    /// The panels follow the nodes: each drawn vertex where the kernel puts it (PhysicsWorld.drawnSoftVertex, the
    /// CPU's copy of MSL physicsSoftMeshKernel) starts where the loft put it.
    func testPanelsStartOnTheBody() {
        let spec = CarSpec.preset(.sedan), b = CarBlueprint(spec), surface = CarSurface(b)
        let w = PhysicsWorld(substeps: 16)
        let car = w.addCar(b, transform: translate([3, 0, -2]), rimSDF: 100, wheelInstances: [0, 0, 0, 0])
        w.addCarSurface(surface.body, car: car, hull: b.hull, vertexBase: 0)
        w.finish()
        var worst: Float = 0
        for (v, p) in surface.body.mesh.positions.enumerated() {
            worst = max(worst, simd_distance(w.drawnSoftVertex(v), p + SIMD3(3, 0, -2)))
        }
        print("panels: \(surface.body.mesh.positions.count) + \(surface.glass.mesh.positions.count) vertices, worst \(worst) m")
        XCTAssertLessThan(worst, 0.005)
        XCTAssertFalse(surface.glass.mesh.indices.isEmpty)
    }
}
