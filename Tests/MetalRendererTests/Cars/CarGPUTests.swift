import XCTest
import Metal
import simd
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics

/// The cars on the GPU (CarsGPU.swift, Shaders/PhysicsCars.metal): the car scene stepped by PhysicsGPU, against the
/// same scene stepped by the CPU. Not the same numbers (a colour of beams at a time, not one after another): the same
/// behaviour.
final class CarGPUTests: XCTestCase {
    private static let shaders = SourceTree.packageRoot.appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = CarGPUTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: CarGPUTests.shaders, lightTypes: 0x3F, stats: false)
        CarGPUTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The car scene with `cars`.
    private func scene(_ cars: CarSettings) throws -> Scene {
        guard CarPack.enabled else { throw XCTSkip("models off") }
        var settings = SceneSettings(kind: .cars)
        settings.cars = cars
        settings.physics.backend = .gpu
        return Scene(settings)
    }

    /// The scene's world on the GPU: `step(n)` runs n steps, `telemetry()` reads the cars back.
    private final class GPU {
        let gpu: PhysicsGPU, queue: MTLCommandQueue, pipelines: Pipelines
        init(_ s: Scene, _ m: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)) throws {
            let sdf = try SDFBuffers(device: m.device, scene: s)
            gpu = try PhysicsGPU(device: m.device, world: s.physics!, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
            (queue, pipelines) = (m.queue, m.pipelines)
        }
        func encode(_ body: (ComputePass) -> Void) {
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            body(Metal3Pass(enc: enc))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        func step(_ n: Int, reset: Bool = false) {
            var done = 0
            while done < n {
                let k = min(20, n - done)
                encode {
                    if reset && done == 0 { gpu.encodeReset($0, pipelines: pipelines) }
                    gpu.sendCommands()
                    gpu.encodeSteps($0, pipelines: pipelines, steps: k)
                }
                done += k
            }
        }
        var telemetry: [CarTelemetry] { gpu.cars!.readTelemetry() }
    }

    private func seconds(_ s: Float) -> Int { Int((s / PhysicsWorld.stepLength).rounded()) }

    /// A car let go on the ground settles on its springs, as on the CPU: its floor within 1.5 cm of the CPU's, upright,
    /// nothing bent.
    func testItSettlesAsOnTheCPU() throws {
        let m = try metal()
        let settings = CarSettings(style: .civic, cars: 1, demo: .none)
        let g = try GPU(try scene(settings), m)
        let cpu = try scene(settings).physics!
        for t in 1...3 {
            g.step(seconds(1))
            cpu.advance(to: Float(t) + PhysicsWorld.stepLength / 2)
            let a = g.telemetry[0], b = cpu.carTelemetry(0)
            print(String(format: "%d s: GPU floor %.4f up %.4f speed %.3f bent %d, CPU floor %.4f up %.4f speed %.3f bent %d",
                         t, a.position.y, a.up.y, a.speed, a.bent, b.position.y, b.up.y, b.speed, b.bent))
        }
        let a = g.telemetry[0], b = cpu.carTelemetry(0)
        XCTAssertEqual(a.position.y, b.position.y, accuracy: 0.015)
        XCTAssertGreaterThan(a.up.y, 0.999)
        XCTAssertEqual(a.bent, 0)
        XCTAssertLessThan(abs(a.speed), 0.05)
    }

    /// Full throttle from a standstill down the run-up (the wall ahead at 4.5 s): the speed each second within 5% of the
    /// CPU's, the same gear, straight.
    func testItAcceleratesAsOnTheCPU() throws {
        let m = try metal()
        let settings = CarSettings(style: .civic, cars: 1, demo: .none)
        let s = try scene(settings), c = try scene(settings)
        var input = CarInput()
        input.accelerate = 1
        let at = seconds(1)
        s.physics!.add(PhysicsWorld.carCommand(0, input, at: UInt32(at)))
        c.physics!.add(PhysicsWorld.carCommand(0, input, at: UInt32(at)))
        let g = try GPU(s, m), cpu = c.physics!
        g.step(at)
        for t in 1...4 {
            g.step(seconds(1))
            cpu.advance(to: Float(1 + t) + PhysicsWorld.stepLength / 2)
            let a = g.telemetry[0], b = cpu.carTelemetry(0)
            print(String(format: "%d s: GPU %.2f m/s gear %d rpm %.0f heading x %.3f, CPU %.2f m/s gear %d rpm %.0f heading x %.3f",
                         t, a.speed, a.gear, a.rpm, a.forward.x, b.speed, b.gear, b.rpm, b.forward.x))
            XCTAssertEqual(a.speed, b.speed, accuracy: 0.05 * b.speed + 0.1, "\(t) s")
            XCTAssertEqual(a.gear, b.gear, "\(t) s")
            XCTAssertGreaterThan(a.forward.z, 0.995, "\(t) s")
        }
    }

    // MARK: Damage

    /// The cars' events (CarEvent's slots) in the GPU's ring of breaks for the steps after `from` (the ring holds 64
    /// steps: read every 20).
    private func ringEvents(_ gpu: PhysicsGPU, after from: Int) -> (events: [GPUBreakEvent], last: Int) {
        let raw = gpu.breakRing.contents(), slots = PhysicsWorld.ringSlots, per = PhysicsWorld.ringEvents
        let all = raw.advanced(by: 16 * slots).bindMemory(to: GPUBreakEvent.self, capacity: slots * per)
        var out: [GPUBreakEvent] = [], last = from
        for slot in 0..<slots {
            let header = raw.advanced(by: 16 * slot).load(as: SIMD4<UInt32>.self)
            let step = Int(header.x) - 1
            guard step > from else { continue }
            last = max(last, step)
            out += (0..<Int(header.y)).map { all[slot * per + $0] }.filter { $0.velocity.w >= Float(CarEvent.firstSlot) }
        }
        return (out, last)
    }

    /// Into the wall at 50 and 100 km/h on the GPU, as on the CPU (CarDamageTests.testAWallBreaksTheGlassAndTheEngine):
    /// the front crushed and bent for good, the car stopped, the front bumper off and the rear's parts on, glass
    /// broken, the radiator leaking; at 50 the engine runs (steam), at 100 it has seized (smoke); the nodes crushed (the
    /// look's bytes), the events in the ring for the dust.
    func testAWallBreaksTheCarAsOnTheCPU() throws {
        let m = try metal()
        for kmh: Float in [50, 100] {
            let settings = CarSettings(style: .civic, cars: 1, demo: .wall, demoSpeed: kmh)
            let g = try GPU(try scene(settings), m), cpu = try scene(settings).physics!
            var events: [GPUBreakEvent] = [], seen = -1
            for _ in 0..<(seconds(4) / 20) {
                g.step(20)
                let r = ringEvents(g.gpu, after: seen)
                events += r.events
                seen = r.last
            }
            cpu.advance(to: Float(seconds(4) / 20 * 20) * PhysicsWorld.stepLength + PhysicsWorld.stepLength / 2)
            let a = g.telemetry[0], b = cpu.carTelemetry(0)
            let s = cpu.carSystem.cars[0]
            let parts = g.gpu.cars!.readParts(cpu.carSystem.parts.count)
            func off(_ list: [CarPart]) -> [String] {
                list[Int(s.firstPart)..<Int(s.firstPart + s.partCount)].filter { $0.flags & CarPart.off != 0 }.map { CarPartKind(rawValue: $0.kind)!.title }
            }
            let nodes = g.gpu.readParticles()
            let crushed = (Int(s.firstNode)..<Int(s.firstNode + s.nodeCount)).filter { nodes[$0].info.z & 0xFF > 128 }.count
            let cpuCrushed = (Int(s.firstNode)..<Int(s.firstNode + s.nodeCount)).filter { cpu.particles[$0].info.z & 0xFF > 128 }.count
            func kind(_ k: CarEvent, _ list: [GPUBreakEvent]) -> Int { list.filter { UInt32($0.velocity.w) == k.slot }.count }
            let cpuEvents = cpu.breakLog
            for (name, t, o, c, e) in [("GPU", a, off(parts), crushed, events), ("CPU", b, off(cpu.carSystem.parts), cpuCrushed, cpuEvents)] {
                print(String(format: "%.0f km/h %@: speed %.2f, front crushed %.2f m, bent %d, broken %d, coolant %.2f, engine %.2f, running %@, panes %d, wheels off %d, parts off %d (%@); %d nodes crushed; events %d glass, %d steam, %d smoke, %d debris",
                             kmh, name, t.speed, t.frontCrush, t.bent, t.broken, t.coolant, t.engineDamage, t.running ? "yes" : "no", t.panesBroken, t.wheelsOff,
                             t.partsOff, o.joined(separator: ", "), c, kind(.glass, e), kind(.steam, e), kind(.smoke, e), kind(.debris, e)))
            }
            // A wheel off its axle is a body of the world's again: its mass, no wheel's flag.
            let bodies = g.gpu.readBodies()
            for w in g.gpu.cars!.readWheels(cpu.carSystem.wheels.count) where w.flags & CarWheel.off != 0 {
                let o = bodies[Int(w.body)]
                XCTAssertEqual(o.info.y & (PhysicsWorld.wheelBit | PhysicsWorld.kinematicBit), 0, "\(kmh): a wheel off")
                XCTAssertGreaterThan(o.position.w, 0, "\(kmh): a wheel off has its mass")
                XCTAssertGreaterThan(o.position.y, 0, "\(kmh): a wheel off on the ground")
            }
            if kmh == 100 { XCTAssertEqual(a.wheelsOff, b.wheelsOff, "100: wheels off") }
            XCTAssertLessThan(abs(a.speed), 1, "\(kmh): stopped")
            XCTAssertGreaterThan(a.bent, 20, "\(kmh)")
            XCTAssertEqual(a.frontCrush, b.frontCrush, accuracy: max(0.1, 0.25 * b.frontCrush), "\(kmh): front crush")
            XCTAssertGreaterThan(crushed, 10, "\(kmh)")
            XCTAssertGreaterThan(a.panesBroken, 0, "\(kmh)")
            XCTAssertGreaterThan(kind(.glass, events), 0, "\(kmh)")
            XCTAssertLessThan(a.coolant, 1, "\(kmh)")
            XCTAssert(off(parts).contains(CarPartKind.frontBumper.title), "\(kmh): the front bumper")
            XCTAssertFalse(off(parts).contains(CarPartKind.rearBumper.title) || off(parts).contains(CarPartKind.trunk.title), "\(kmh): the rear's parts")
            XCTAssertEqual(a.running, b.running, "\(kmh): the engine")
            XCTAssertGreaterThan(kind(a.running ? .steam : .smoke, events), 0, "\(kmh)")
        }
    }

    // MARK: Bodies

    /// How far each body moved from where it began, and the pieces that came free (a fractured object's, enabled, of
    /// some mass).
    private func moved(_ start: [GPUPhysicsBody], _ now: [GPUPhysicsBody], _ which: (GPUPhysicsBody) -> Bool) -> (count: Int, most: Float) {
        let d = start.indices.filter { which(start[$0]) }.map { simd_distance(PhysicsMath.xyz(now[$0].position), PhysicsMath.xyz(start[$0].position)) }
        return (d.filter { $0 > 0.1 }.count, d.max() ?? 0)
    }

    /// Into the crates at 40 km/h (the props demo), then through the brick wall at 50 (the breakables'): on the GPU as
    /// on the CPU, the crates shoved aside, the wall broken and the car through it (its knocks broke the bricks, and it
    /// got back what breaking them didn't take).
    func testBodiesGiveWayAsOnTheCPU() throws {
        let m = try metal()
        for (demo, kmh) in [(CarSettings.Demo.props, Float(40)), (.breakables, 50)] {
            let settings = CarSettings(style: .civic, cars: 1, demo: demo, demoSpeed: kmh)
            let s = try scene(settings), g = try GPU(s, m), cpu = try scene(settings).physics!
            let start = s.physics!.initialBodies
            g.step(seconds(3))
            cpu.advance(to: 3 + PhysicsWorld.stepLength / 2)
            let a = g.telemetry[0], b = cpu.carTelemetry(0)
            let props = { (o: GPUPhysicsBody) in o.info.y & (PhysicsWorld.pieceBit | PhysicsWorld.wheelBit | PhysicsWorld.kinematicBit) == 0 && o.position.w > 0 }
            let pieces = { (o: GPUPhysicsBody) in o.info.y & PhysicsWorld.pieceBit != 0 }
            let gpuBodies = g.gpu.readBodies()
            let gp = moved(start, gpuBodies, props), cp = moved(start, cpu.bodies, props)
            let gb = moved(start, gpuBodies, pieces), cb = moved(start, cpu.bodies, pieces)
            for (name, t, p, q) in [("GPU", a, gp, gb), ("CPU", b, cp, cb)] {
                print(String(format: "%@ %.0f km/h %@: car at z %.2f speed %.2f, front crushed %.2f, bent %d; props moved %d (most %.2f m), pieces moved %d (most %.2f m)",
                             "\(demo)", kmh, name, t.position.z, t.speed, t.frontCrush, t.bent, p.count, p.most, q.count, q.most))
            }
            if demo == .props {
                XCTAssertGreaterThan(gp.count, 0, "the crates moved")
                XCTAssertEqual(a.position.z, b.position.z, accuracy: 3, "the car where the CPU's is")
            } else {
                XCTAssertGreaterThan(gb.count, 20, "the bricks scattered")
                XCTAssertGreaterThan(a.position.z, 34.5, "the car through the wall (at z 34)")
                XCTAssertEqual(a.position.z, b.position.z, accuracy: 4, "the car near where the CPU's is (past breakables it varies)")
            }
        }
    }

    // MARK: Cars against cars

    /// Head on at 50 km/h each (the demo): on the GPU as on the CPU, both fronts crushed alike, the cars stopped together,
    /// neither through the other (the first's front still behind the second's).
    func testHeadOnAsOnTheCPU() throws {
        let m = try metal()
        let settings = CarSettings(style: .civic, cars: 2, demo: .headOn, demoSpeed: 50)
        let g = try GPU(try scene(settings), m), cpu = try scene(settings).physics!
        g.step(seconds(3))
        cpu.advance(to: 3 + PhysicsWorld.stepLength / 2)
        let a = g.telemetry, b = [cpu.carTelemetry(0), cpu.carTelemetry(1)]
        for (name, t) in [("GPU", a), ("CPU", b)] {
            print(String(format: "head on %@: car 0 z %.2f speed %.2f crushed %.2f bent %d parts off %d; car 1 z %.2f speed %.2f crushed %.2f bent %d parts off %d",
                         name, t[0].position.z, t[0].speed, t[0].frontCrush, t[0].bent, t[0].partsOff, t[1].position.z, t[1].speed, t[1].frontCrush,
                         t[1].bent, t[1].partsOff))
        }
        let s = cpu.carSystem.cars
        let nodes = g.gpu.readParticles()
        let front0 = (Int(s[0].firstNode)..<Int(s[0].firstNode + s[0].nodeCount)).map { nodes[$0].position.z }.max()!
        let front1 = (Int(s[1].firstNode)..<Int(s[1].firstNode + s[1].nodeCount)).map { nodes[$0].position.z }.min()!
        print(String(format: "GPU: car 0's front at z %.2f, car 1's at %.2f", front0, front1))
        XCTAssertLessThan(abs(a[0].speed - a[1].speed), 1.5, "they go on together")
        XCTAssertGreaterThan(a[0].frontCrush, 0.1)
        XCTAssertGreaterThan(a[1].frontCrush, 0.1)
        XCTAssertEqual(a[0].frontCrush, b[0].frontCrush, accuracy: max(0.15, 0.3 * b[0].frontCrush))
        XCTAssertEqual(a[1].frontCrush, b[1].frontCrush, accuracy: max(0.15, 0.3 * b[1].frontCrush))
        XCTAssertLessThan(front0, front1 + 0.3, "neither through the other")
    }

    /// Each style's beams in colours: how many a pass takes (its barriers), the corners' too.
    func testColourCounts() throws {
        let m = try metal()
        for style in CarStyle.allCases {
            let g = try GPU(try scene(CarSettings(style: style, cars: 1, demo: .none)), m)
            let s = g.gpu.world.carSystem.cars[0]
            print("\(style): \(s.nodeCount) nodes, \(s.beamCount) beams (\(s.beamCount - (s.firstCorner - s.firstBeam)) corner), colours \(g.gpu.cars!.colourCounts[0])")
            // The corners' beams in islands of shared nodes.
            let beams = g.gpu.world.carSystem.beams
            var parent: [UInt32: UInt32] = [:]
            func find(_ x: UInt32) -> UInt32 { var x = x; while let p = parent[x], p != x { x = p }; return x }
            for k in Int(s.firstCorner)..<Int(s.firstBeam + s.beamCount) {
                let n = beams[k].nodes
                let a = find(n.x), b = find(n.y)
                parent[a] = parent[a] ?? a
                parent[b] = parent[b] ?? b
                if a != b { parent[a] = b }
            }
            var sizes: [UInt32: Int] = [:]
            for k in Int(s.firstCorner)..<Int(s.firstBeam + s.beamCount) { sizes[find(beams[k].nodes.x), default: 0] += 1 }
            print("   corner islands: \(sizes.values.sorted())")
        }
    }

    /// Laps on autopilot: every car round its circle at its speed (15 m/s), upright, after 6 s.
    func testLapsOnTheGPU() throws {
        let m = try metal()
        let g = try GPU(try scene(CarSettings(style: .civic, cars: 4, demo: .laps)), m)
        g.step(seconds(6))
        print("candidates: \(g.gpu.cars!.readCars().map(\.candidateCount))")
        for (k, t) in g.telemetry.enumerated() {
            let r = simd_distance(SIMD2(t.position.x, t.position.z), Scene.carLapCentre)
            print(String(format: "car %d: speed %.2f, radius %.2f (lap %.1f), up %.3f, bent %d", k, t.speed, r,
                         Scene.carLap(k, of: 4), t.up.y, t.bent))
            XCTAssertEqual(t.speed, 15, accuracy: 2)
            XCTAssertEqual(r, Scene.carLap(k, of: 4), accuracy: 3)
            XCTAssertGreaterThan(t.up.y, 0.98)
        }
    }

    /// Sixteen cars on laps round a field of 24 breakable walls: each on its circle at its speed, upright; the walls
    /// standing (the cars never reach them).
    func testManyCarsOnTheGPU() throws {
        let m = try metal()
        let s = try scene(CarSettings(style: .civic, cars: 16, demo: .laps, walls: 24))
        let start = s.physics!.initialBodies
        let pieces = start.indices.filter { start[$0].info.y & PhysicsWorld.pieceBit != 0 }
        let g = try GPU(s, m)
        g.step(seconds(6))
        let now = g.gpu.readBodies()
        let moved = pieces.filter { simd_distance(PhysicsMath.xyz(now[$0].position), PhysicsMath.xyz(start[$0].position)) > 0.05 }.count
        print("\(pieces.count) pieces, \(moved) of them moved more than 5 cm")
        XCTAssertGreaterThan(pieces.count, 500)
        XCTAssertEqual(moved, 0, "the walls stand")
        for (k, t) in g.telemetry.enumerated() {
            let r = simd_distance(SIMD2(t.position.x, t.position.z), Scene.carLapsCentre(16))
            XCTAssertEqual(t.speed, 15, accuracy: 2, "car \(k)")
            XCTAssertEqual(r, Scene.carLap(k, of: 16), accuracy: 3, "car \(k)")
            XCTAssertGreaterThan(t.up.y, 0.98, "car \(k)")
        }
    }
}
