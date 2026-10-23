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

/// CarDamage.swift and what it reads: parts that come off, wheels off their axles, panes that shatter, an engine that
/// leaks, overheats and seizes, the nodes' crush, scrapes and dirt, and the events the dust is made of.
final class CarDamageTests: XCTestCase {
    /// A world with a floor and one car of `spec` placed by `place` moving at `velocity`, with a windshield pane (the
    /// body's top between the roof's front and the windshield's base) and `statics` added first.
    private func world(_ spec: CarSpec = .preset(.sedan), place: float4x4 = matrix_identity_float4x4, velocity: SIMD3<Float> = .zero,
                       statics: (PhysicsWorld) -> Void = { _ in }) -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        statics(w)
        let b = CarBlueprint(spec)
        w.addCar(b, transform: place, rimSDF: 100, wheelInstances: [0, 0, 0, 0], velocity: velocity, panes: [windshield(b)])
        w.finish()
        return w
    }

    /// The windshield's triangles of `b`'s hull (the body's top from the roof's front to the windshield's base).
    private func windshield(_ b: CarBlueprint) -> CarSurface.Pane {
        let s = b.spec
        let hull = b.hull.indices.filter { k in
            let t = b.hull[k], c = (b.nodes[Int(t.x)] + b.nodes[Int(t.y)] + b.nodes[Int(t.z)]) / 3
            return b.hullPart[k] == 0 && c.z > s.roofFront && c.z < s.windshieldBase + 0.1 && c.y > s.belt + 0.05
        }
        return CarSurface.Pane(lamp: false, part: 0, hull: hull)
    }

    private func wall(_ z: Float) -> (PhysicsWorld) -> Void {
        { w in w.addStatic(sdf: 90, SDFShape(.box(halfExtents: [6, 1.5, 0.5])), transform: translate([0, 1.5, z + 0.5]), friction: 0.6, restitution: 0.1) }
    }

    private func pole(_ x: Float, _ z: Float) -> (PhysicsWorld) -> Void {
        { w in w.addStatic(sdf: 91, SDFShape(.cylinder(halfHeight: 1.5, radius: 0.15)), transform: translate([x, 1.5, z]), friction: 0.5, restitution: 0.1) }
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) { w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2) }

    private func parts(_ w: PhysicsWorld, _ kind: CarPartKind) -> [CarPart] {
        let s = w.carSystem.cars[0]
        return w.carSystem.parts[Int(s.firstPart)..<Int(s.firstPart + s.partCount)].filter { $0.kind == kind.rawValue }
    }

    private func events(_ w: PhysicsWorld, _ kind: CarEvent) -> Int { w.breakLog.filter { UInt32($0.velocity.w) == kind.rawValue }.count }

    // MARK: Building

    /// Every style's parts: both bumpers and the hood, two or four doors, each held on by attachments, its nodes outside
    /// the body's by `partGap`; the parts' mass is in the car's.
    func testEveryStyleHasItsParts() {
        for style in CarStyle.allCases {
            let b = CarBlueprint(.preset(style))
            let kinds = b.parts.map(\.kind)
            print("\(style): \(b.parts.map { "\($0.kind.title) \($0.nodeCount)" }.joined(separator: ", ")); \(b.nodes.count) nodes, \(b.beams.count) beams")
            for kind in [CarPartKind.frontBumper, .rearBumper, .hood] { XCTAssertEqual(kinds.filter { $0 == kind }.count, 1, "\(style): \(kind)") }
            let doors = kinds.filter { $0 == .frontDoor || $0 == .rearDoor }.count
            XCTAssert(doors == 2 || doors == 4, "\(style): \(doors) doors")
            for (p, part) in b.parts.enumerated() {
                let holds = b.beams.filter { $0.attach && $0.part == p + 1 }.count
                XCTAssertGreaterThan(holds, 0, "\(style): \(part.kind) is held by nothing")
                XCTAssertEqual(part.triangles.count, part.under.count, "\(style): \(part.kind)")
            }
            XCTAssertFalse(b.radiator.isEmpty, "\(style)")
        }
    }

    // MARK: Crashes

    /// Into a wall at 50 km/h: the windshield shatters (its shards logged), the radiator leaks (steam, coolant going),
    /// the engine still runs; the front's nodes are crushed, the front bumper comes off and the rear's parts stay on.
    /// At 100 km/h the engine seizes (smoke).
    func testAWallBreaksTheGlassAndTheEngine() {
        for kmh: Float in [50, 100] {
            let w = world(velocity: [0, 0, kmh / 3.6], statics: wall(4))
            run(w, 4)
            let off = w.carSystem.parts.filter { $0.flags & CarPart.off != 0 }.map { CarPartKind(rawValue: $0.kind)!.title }
            let t = w.carTelemetry(0), s = w.carSystem.cars[0]
            let crushed = (Int(s.firstNode)..<Int(s.firstNode + s.nodeCount)).filter { w.particles[$0].info.z & 0xFF > 128 }.count
            print(String(format: "%.0f km/h: front crushed %.2f m, coolant %.2f, heat %.2f, engine damage %.2f, running %@, panes broken %d, parts off %d (%@), wheels off %d; %d nodes crushed; events: %d glass, %d steam, %d smoke, %d debris",
                         kmh, t.frontCrush, t.coolant, t.heat, t.engineDamage, t.running ? "yes" : "no", t.panesBroken, t.partsOff, off.joined(separator: ", "), t.wheelsOff, crushed,
                         events(w, .glass), events(w, .steam), events(w, .smoke), events(w, .debris)))
            XCTAssertEqual(t.panesBroken, 1, "\(kmh) km/h: the windshield")
            XCTAssertGreaterThan(events(w, .glass), 0)
            XCTAssertGreaterThan(crushed, 10)
            XCTAssertLessThan(t.coolant, 1)
            XCTAssert(off.contains(CarPartKind.frontBumper.title))
            XCTAssertFalse(off.contains(CarPartKind.rearBumper.title) || off.contains(CarPartKind.trunk.title), "a front crash took the rear's parts off")
            if kmh == 50 {
                XCTAssertTrue(t.running)
                XCTAssertGreaterThan(events(w, .steam), 0)
            } else {
                XCTAssertFalse(t.running)
                XCTAssertGreaterThan(events(w, .smoke), 0)
            }
        }
    }

    /// A pole at 40 km/h in the middle of the front: the front bumper's clips break and it comes off; lying still it
    /// is frozen within 3 s.
    func testAPoleTakesTheBumperOff() {
        let w = world(velocity: [0, 0, 40 / 3.6], statics: pole(0, 5))
        run(w, 1.5)
        let bumper = parts(w, .frontBumper)[0]
        print("bumper: holding \(bumper.holding), flags \(bumper.flags); parts off \(w.carTelemetry(0).partsOff), crush \(w.carTelemetry(0).frontCrush)")
        XCTAssertNotEqual(bumper.flags & CarPart.off, 0, "the bumper stayed on")
        run(w, 3)
        print("then: flags \(parts(w, .frontBumper)[0].flags), still \(parts(w, .frontBumper)[0].still)")
        XCTAssertGreaterThan(events(w, .debris), 0)
    }

    /// Sliding sideways into a pole, at 40 km/h at the front door's middle or at 60 km/h at its hinges: the body its
    /// hinges and latch are fixed to is crushed, they break, and it comes off.
    func testASidePoleTakesTheDoorOff() {
        let spec = CarSpec.preset(.sedan), b = CarBlueprint(spec)
        let door = b.parts.first { $0.kind == .frontDoor && $0.side < 0 }!
        for (name, z, kmh) in [("middle", (door.span.x + door.span.y) / 2, Float(40)), ("hinge", door.span.y, 60)] {
            let w = world(velocity: [-kmh / 3.6, 0, 0], statics: pole(-spec.width / 2 - 1.2, z))
            run(w, 2)
            let right = parts(w, .frontDoor).first { $0.firstNode == Int32(door.firstNode) }!
            print("\(name) \(kmh) km/h: the door holding \(right.holding)/\(right.attachments), flags \(right.flags); parts off \(w.carTelemetry(0).partsOff), bent \(w.carTelemetry(0).bent)")
            XCTAssertNotEqual(right.flags & CarPart.off, 0, "\(name) \(kmh) km/h")
        }
    }

    /// At 60 km/h into a curb in front of the front left wheel: its axle breaks and it comes off (a body of its own:
    /// no longer a car's wheel, its friction back).
    func testACurbTakesAWheelOff() {
        let spec = CarSpec.preset(.sedan)
        let curb: (PhysicsWorld) -> Void = { w in
            w.addStatic(sdf: 92, SDFShape(.box(halfExtents: [0.4, 0.15, 0.3])), transform: translate([spec.track / 2, 0.15, 6]), friction: 0.7, restitution: 0.05)
        }
        let w = world(spec, velocity: [0, 0, 60 / 3.6], statics: curb)
        run(w, 2)
        let t = w.carTelemetry(0)
        let wheel = w.carSystem.wheels[0], body = w.bodies[Int(wheel.body)]
        print("wheels off \(t.wheelsOff), front left flags \(wheel.flags), knocks \(w.carSystem.wheels.map(\.knockPeak)), bent \(t.bent), broken \(t.broken)")
        XCTAssertGreaterThanOrEqual(t.wheelsOff, 1)
        XCTAssertNotEqual(wheel.flags & CarWheel.off, 0)
        XCTAssertEqual(body.info.y & PhysicsWorld.wheelBit, 0)
        XCTAssertGreaterThan(body.velocity.w, 0)
    }

    /// Over a speed bump (8 cm high) at 60 km/h: no wheel comes off.
    func testABumpKeepsTheWheels() {
        let bump: (PhysicsWorld) -> Void = { w in
            w.addStatic(sdf: 93, SDFShape(.cylinder(halfHeight: 2, radius: 0.3)), transform: translate([0, -0.22, 6]) * float4x4(simd_quatf(angle: .pi / 2, axis: [0, 0, 1])),
                        friction: 0.7, restitution: 0.05)
        }
        let w = world(velocity: [0, 0, 60 / 3.6], statics: bump)
        run(w, 2)
        print("bump: knocks \(w.carSystem.wheels.map(\.knockPeak)), bent \(w.carTelemetry(0).bent)")
        XCTAssertEqual(w.carTelemetry(0).wheelsOff, 0)
        XCTAssertEqual(w.carTelemetry(0).partsOff, 0)
    }

    /// Steering to full lock and back at a standstill, then pulling away: the tie rods don't bend, the front wheels
    /// point where the steering does (each wheel's yaw against the body's), straight again when it is.
    func testSteeringLeavesTheTieRodsStraight() throws {
        var specs = [CarSpec.preset(.offroad), CarSpec.preset(.sedan)]
        if let pack = CarPack.shared, let model = pack.models[.offroad] { specs.append(CarSpec.preset(.offroad).fitted(to: model)) }
        for spec in specs {
            let w = world(spec)
            func yaw(_ k: Int) -> Float {
                let wheel = w.carSystem.wheels[k], body = w.bodies[Int(wheel.body)], f = w.carTelemetry(0)
                let axle = PhysicsMath.qrot(body.rotation, wheel.axle)
                return atan2(dot(axle, f.forward), dot(axle, cross(f.up, f.forward))) * 180 / .pi
            }
            func drive(_ steer: Float, _ accelerate: Float = 0) {
                var input = CarInput()
                input.steer = steer
                input.accelerate = accelerate
                w.add(PhysicsWorld.carCommand(0, input))
            }
            var log: [String] = []
            func note(_ name: String) {
                let ties = w.carSystem.wheels.filter { $0.tie >= 0 }.map { w.carSystem.limits[Int($0.tie)].bend * 1000 }
                log.append(String(format: "%@: yaw %.1f / %.1f, tie bend %.1f / %.1f mm, %.0f km/h", name, yaw(0), yaw(1), ties[0], ties[1],
                                  w.carTelemetry(0).speed * 3.6))
            }
            run(w, 1)
            note("start")
            drive(1); run(w, 1.5); note("full left")
            drive(-1); run(w, 1.5); note("full right")
            drive(0); run(w, 1.5); note("centred")
            drive(0, 1); run(w, 2); note("pulling away")
            drive(1, 0.3); run(w, 1); note("turning")
            drive(0, 0.3); run(w, 1.5); note("straight")
            print("\(spec.style)\(spec.profile == nil ? "" : " (model)"):\n   " + log.joined(separator: "\n   "))
            let ties = w.carSystem.wheels.filter { $0.tie >= 0 }.map { w.carSystem.limits[Int($0.tie)].bend }
            XCTAssertLessThan(ties.map(abs).max()!, 0.002, "\(spec.style): a tie rod bent")
            XCTAssertLessThan(max(abs(yaw(0)), abs(yaw(1))), 1.5, "\(spec.style): a front wheel toed")
        }
    }

    /// A car on its roof sliding at 12 m/s: its roof's nodes scraped and dirty, its sides not.
    func testSlidingScrapesTheRoof() {
        let roof = float4x4(simd_quatf(angle: .pi, axis: [0, 0, 1]))
        let spec = CarSpec.preset(.sedan)
        let w = world(spec, place: translate([0, spec.roof + 0.08, 0]) * roof, velocity: [0, 0, 12])
        run(w, 2)
        let s = w.carSystem.cars[0]
        let nodes = (Int(s.firstNode)..<Int(s.firstNode + s.nodeCount))
        let scraped = nodes.filter { (w.particles[$0].info.z >> 8) & 0xFF > 32 }
        let dirty = nodes.filter { (w.particles[$0].info.z >> 16) & 0xFF > 16 }
        let low = scraped.filter { PhysicsMath.xyz(w.particles[$0].position).y < 0.6 }
        print("scraped \(scraped.count) (\(low.count) low), dirty \(dirty.count)")
        XCTAssertGreaterThan(scraped.count, 5)
        XCTAssertEqual(low.count, scraped.count, "a node scraped away from the ground")
        XCTAssertGreaterThan(dirty.count, 5)
    }

    /// The damage replays: a crash run again from the start leaves the same nodes, damage and parts, bit for bit.
    func testDamageReplays() {
        let w = world(velocity: [0, 0, 60 / 3.6], statics: pole(0.4, 5))
        run(w, 2)
        let particles = w.particles, parts = w.carSystem.parts.map(\.flags), log = w.breakLog.count
        w.advance(to: 0)
        w.advance(to: 2 + PhysicsWorld.stepLength / 2)
        XCTAssertEqual(w.particles.map(\.position), particles.map(\.position))
        XCTAssertEqual(w.particles.map(\.info), particles.map(\.info))
        XCTAssertEqual(w.carSystem.parts.map(\.flags), parts)
        XCTAssertEqual(w.breakLog.count, log)
    }

    // MARK: Drawing

    /// The car pack's sedan into the wall at 50 km/h: its drawn panes fold away when they break (each broken pane's
    /// vertices at its car's first node) and its panels near the front take its crush.
    func testDrawnDamage() throws {
        guard let pack = CarPack.shared, let model = pack.models[.sedan] else { throw XCTSkip("no car pack in Assets/Cars") }
        let b = CarBlueprint(CarSpec.preset(.sedan).fitted(to: model)), surface = CarSurface(b, model: model)
        print("panes: \(surface.panes.map { "\($0.lamp ? "lamp" : "pane") on \($0.part), \($0.hull.count) triangles" })")
        XCTAssertGreaterThan(surface.panes.filter(\.lamp).count, 1)
        XCTAssertGreaterThan(surface.panes.filter { !$0.lamp }.count, 2)
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        w.addStatic(sdf: 90, SDFShape(.box(halfExtents: [6, 1.5, 0.5])), transform: translate([0, 1.5, 4.5]), friction: 0.6, restitution: 0.1)
        let car = w.addCar(b, transform: matrix_identity_float4x4, rimSDF: 100, wheelInstances: [0, 0, 0, 0], velocity: [0, 0, 50 / 3.6],
                           panes: surface.panes)
        w.addCarSurface(surface.body, car: car, hull: b.hull, vertexBase: 0)
        let glassBase = surface.body.mesh.positions.count
        w.addCarSurface(surface.glass, car: car, hull: b.hull, vertexBase: glassBase)
        w.finish()
        run(w, 3)
        let s = w.carSystem.cars[0], first = PhysicsMath.xyz(w.particles[Int(s.firstNode)].position)
        let broken = (0..<Int(s.paneCount)).filter { w.carSystem.panes[Int(s.firstPane) + $0].broken }
        var folded = 0, crushed = 0
        for v in w.softVertices.indices {
            let vertex = w.softVertices[v], pane = Int(vertex.embeds.z & 0xFF)
            if pane > 0 && broken.contains(pane - 1) && vertex.embeds.z & PhysicsWorld.lampBit == 0 {
                XCTAssertEqual(simd_distance(w.drawnSoftVertex(v), first), 0, accuracy: 1e-5)
                folded += 1
            }
            if w.drawnCarDamage(v).x > 100 { crushed += 1 }
        }
        print("broken \(broken), \(folded) vertices folded, \(crushed) crushed")
        XCTAssertGreaterThan(folded, 0)
        XCTAssertGreaterThan(crushed, 0)
    }
}
