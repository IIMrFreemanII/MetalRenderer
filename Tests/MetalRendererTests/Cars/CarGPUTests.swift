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
                         Scene.carLapRadius + Float(k) * Scene.carLapSpacing, t.up.y, t.bent))
            XCTAssertEqual(t.speed, 15, accuracy: 2)
            XCTAssertEqual(r, Scene.carLapRadius + Float(k) * Scene.carLapSpacing, accuracy: 3)
            XCTAssertGreaterThan(t.up.y, 0.98)
        }
    }
}
