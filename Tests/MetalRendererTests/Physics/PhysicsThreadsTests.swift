import XCTest
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Plants

/// The CPU step on PhysicsThreads' workers (PhysicsCPU.swift): the same numbers, bit for bit, on one thread and on all
/// of them, and the same as the single-threaded step before it (the digests).
final class PhysicsThreadsTests: XCTestCase {
    /// A world's state as a 64-bit FNV-1a hash of its bytes: bodies, particles, hair, fracture state, welds, liquids.
    static func digest(_ w: PhysicsWorld) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func add<T>(_ a: [T]) {
            a.withUnsafeBytes { raw in
                for b in raw { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            }
        }
        add(w.bodies)
        add(w.particles)
        add(w.hairVertices)
        add(w.fractureState)
        add(w.welds)
        for s in w.fluid?.systems ?? [] { add(s.particles) }
        return h
    }

    /// The scenes whose worlds the digests step, on the CPU, and how far.
    static let worlds: [(name: String, seconds: Float, settings: SceneSettings)] = {
        func scene(_ kind: SceneKind, _ change: (inout SceneSettings) -> Void = { _ in }) -> SceneSettings {
            var s = SceneSettings(kind: kind)
            s.physics.backend = .cpu
            change(&s)
            return s
        }
        return [
            ("physics", 4, scene(.physics)),
            ("ragdolls", 4, scene(.ragdolls)),
            ("hair", 3, scene(.hair)),
            ("soft bodies", 3, scene(.softBodies)),
            ("muscles", 2, scene(.muscles)),
            ("fluids", 2, scene(.fluids)),
            ("destruction", 10, scene(.destruction)),
            ("massive", 8, scene(.destruction) { $0.destruction.massive = true; $0.destruction.statues = false }),
            ("demolition", 12, scene(.demolition) { $0.demolition.demo = true; $0.demolition.dust = false }),
            ("3 buildings", 7, scene(.destruction) {
                $0.destruction.massive = true; $0.destruction.statues = false; $0.destruction.buildings = 3
            }),
        ]
    }()

    /// Each physics scene's world stepped on one thread and on all of them: the same state, bit for bit.
    func testOneThreadAndAllAgree() throws {
        let short: [String: Float] = ["physics": 1.5, "ragdolls": 1.5, "hair": 1, "soft bodies": 1, "muscles": 0.5,
                                      "fluids": 0.5, "destruction": 5, "massive": 6.5, "3 buildings": 4, "demolition": 8]
        for world in PhysicsThreadsTests.worlds {
            let seconds = short[world.name] ?? 1
            var digests: [UInt64] = []
            for threads in [false, true] {
                PhysicsPool.shared.enabled = threads
                defer { PhysicsPool.shared.enabled = true }
                let w = try XCTUnwrap(Scene(world.settings).physics)
                let start = Date()
                w.advance(to: seconds + PhysicsWorld.stepLength / 2)
                digests.append(PhysicsThreadsTests.digest(w))
                print(String(format: "%@ to %.1f s on %@: %016llx, %.2f s", world.name, seconds,
                             threads ? "\(PhysicsPool.shared.workers + 1) threads" : "1 thread", digests.last!, Date().timeIntervalSince(start)))
            }
            XCTAssertEqual(digests[0], digests[1], "\(world.name): one thread and all")
        }
    }

    /// The background stepper (PhysicsStepper) against stepping in the frame: frames of uneven lengths, a grab held
    /// for a while, a blast in between: the same state, bit for bit.
    func testTheStepperStepsAsTheFrameDoes() throws {
        var settings = SceneSettings(kind: .destruction)
        settings.physics.backend = .cpu
        settings.destruction.statues = false
        let frames = (1...150).map { k in Float(k) / 60 * (1 + 0.5 * sin(Float(k))) }.reduce(into: [Float]()) { $0.append(($0.last ?? 0) + $1 / Float(150) * 2) }
        let grab = GPUPhysicsGrab(target: SIMD4(0, 3, 0, 1), anchor: .zero, body: 3)
        func act(_ w: PhysicsWorld, _ k: Int) {
            if k == 40 { w.command(.blast, origin: [0, 1, -2], radius: 2, magnitude: 12, steps: 6) }
        }
        let a = try XCTUnwrap(Scene(settings).physics)
        for (k, t) in frames.enumerated() {
            act(a, k)
            a.grab = k >= 20 && k < 70 ? grab : GPUPhysicsGrab()
            a.advance(to: t)
        }
        let b = try XCTUnwrap(Scene(settings).physics)
        let stepper = PhysicsStepper(world: b)
        for (k, t) in frames.enumerated() {
            stepper.sync { act($0, k) }
            stepper.grab = k >= 20 && k < 70 ? grab : GPUPhysicsGrab()
            stepper.request(to: t)
        }
        stepper.waitIdle()
        stepper.stop()
        print(String(format: "stepper against the frame: %016llx, %016llx", PhysicsThreadsTests.digest(a), PhysicsThreadsTests.digest(b)))
        XCTAssertEqual(PhysicsThreadsTests.digest(a), PhysicsThreadsTests.digest(b))
        XCTAssertEqual(a.stepIndex, b.stepIndex)
    }

    /// Each scene's world stepped on the CPU, its digest printed (`digest <name> <hex>`): the same lines from a build
    /// before a change to the CPU step and after it say it gives the same numbers. PHYSICS_DIGEST=1 (a name, or names
    /// joined by commas, for those only).
    func testDigests() throws {
        guard let only = ProcessInfo.processInfo.environment["PHYSICS_DIGEST"] else { throw XCTSkip("set PHYSICS_DIGEST=1") }
        let names = only == "1" ? nil : Set(only.split(separator: ",").map(String.init))
        for world in PhysicsThreadsTests.worlds where names?.contains(world.name) ?? true {
            let w = try XCTUnwrap(Scene(world.settings).physics)
            let start = Date()
            w.advance(to: world.seconds + PhysicsWorld.stepLength / 2)
            print(String(format: "digest %@ %016llx (%d bodies, %d particles, %.1f s)", world.name, PhysicsThreadsTests.digest(w),
                         w.bodies.count, w.particles.count, Date().timeIntervalSince(start)))
        }
    }
}
