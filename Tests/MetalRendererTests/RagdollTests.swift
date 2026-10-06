import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Joints and ragdolls (Physics.swift's addJoint, PhysicsCPU.solveJoint, Shaders/Physics.metal's physSolveJoint,
/// Scene+Ragdolls.swift): anchors that stay together, limits that hold, joined bodies that don't collide, ragdolls that
/// sleep and wake whole, and the GPU's steps against the CPU's.
final class RagdollTests: XCTestCase {
    private func world() -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0])
        return w
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) {
        w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2)
    }

    private func position(_ w: PhysicsWorld, _ i: Int) -> SIMD3<Float> { PhysicsMath.xyz(w.bodies[i].position) }

    /// How far joint `j`'s two anchors are apart.
    private func gap(_ bodies: [GPUPhysicsBody], _ j: GPUPhysicsJoint) -> Float {
        let a = bodies[Int(j.info.x)], b = bodies[Int(j.info.y)]
        return length(PhysicsMath.xyz(a.position) + PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.anchorA))
                      - PhysicsMath.xyz(b.position) - PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.anchorB)))
    }

    /// Joint `j`'s angles as the solver sees them: the angle between its axes (a ball joint's swing, a hinge's
    /// misalignment) and its twist (a hinge's turn about its axis).
    private func angles(_ bodies: [GPUPhysicsBody], _ j: GPUPhysicsJoint) -> (bend: Float, twist: Float) {
        let a = bodies[Int(j.info.x)], b = bodies[Int(j.info.y)]
        let axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA)), axisB = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.axisB))
        let bend = atan2(length(cross(axisA, axisB)), dot(axisA, axisB))
        let n = j.info.z == PhysicsJointKind.hinge.rawValue ? axisA : normalize(axisA + axisB)
        let n1 = PhysicsWorld.across(PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.referenceA)), n)
        let n2 = PhysicsWorld.across(PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.referenceB)), n)
        return (bend, atan2(dot(cross(n1, n2), n), dot(n1, n2)))
    }

    /// How far joint `j` is outside its limits (radians; 0 inside).
    private func excess(_ bodies: [GPUPhysicsBody], _ j: GPUPhysicsJoint) -> Float {
        let (bend, twist) = angles(bodies, j)
        let out = max(j.axisA.w - twist, twist - j.axisB.w, 0)
        return max(out, j.info.z == PhysicsJointKind.hinge.rawValue ? bend : bend - j.referenceA.w)
    }

    private func asleep(_ w: PhysicsWorld) -> Int { w.bodies.filter { $0.info.y & PhysicsWorld.asleep != 0 }.count }

    // MARK: Joints

    func testABallJointChainHoldsTogether() {
        // Five rods end to end, the first held up by the mouse's pull at its end: the rest swing down under it.
        let w = world()
        let rod = SDFShape(.capsule(halfLength: 0.2, radius: 0.04))
        for k in 0..<5 {
            w.addBody(sdf: 0, rod, transform: translate([0.5 * Float(k), 2.5, 0]) * rotate(.pi / 2, [0, 0, 1]), instance: k)
        }
        for k in 1..<5 {
            w.addJoint(k - 1, k, at: [0.5 * Float(k) - 0.25, 2.5, 0], axis: [1, 0, 0], reference: [0, 1, 0],
                       .ball(swing: .pi, twist: -.pi...(.pi)))
        }
        w.finish()
        let end = SIMD3<Float>(-0.25, 2.5, 0), b0 = w.bodies[0]
        let anchor = PhysicsMath.qrot(PhysicsMath.qconj(b0.rotation), end - PhysicsMath.xyz(b0.position))
        w.grab = GPUPhysicsGrab(target: SIMD4(end, 1), anchor: SIMD4(anchor, 0), body: 0)
        var worst: Float = 0, lowest: Float = .infinity
        for _ in 0..<180 {
            w.step()
            for j in w.joints { worst = max(worst, gap(w.bodies, j)) }
            lowest = min(lowest, position(w, 4).y)
        }
        print(String(format: "ball joint chain: anchors apart by %.2g m at most", worst))
        XCTAssertLessThan(worst, 1e-3)
        XCTAssertLessThan(lowest, 1, "the chain swings down")
    }

    /// A heavy slab on the floor and a rod standing on it, joined at the rod's foot by `kind` (a hinge about x, a ball
    /// joint about the rod), the rod set falling over about x at `tilt` (rad/s) and spinning at `spin`.
    private func stand(_ kind: PhysicsJoint, tilt: Float, spin: SIMD3<Float> = .zero) -> PhysicsWorld {
        let w = world()
        w.addBody(sdf: 0, SDFShape(.box(halfExtents: [0.5, 0.1, 0.5])), transform: translate([0, 0.1, 0]), instance: 0, density: 3000)
        w.addBody(sdf: 1, SDFShape(.capsule(halfLength: 0.3, radius: 0.05)), transform: translate([0, 0.6, 0]), instance: 1)
        let hinge = kind.kind == .hinge
        w.addJoint(0, 1, at: [0, 0.25, 0], axis: hinge ? [1, 0, 0] : [0, 1, 0], reference: hinge ? [0, 1, 0] : [0, 0, 1], kind)
        w.finish()
        // Tipped over a little about x, to fall that way.
        w.bodies[1].angular = SIMD4(tilt, 0, 0, w.bodies[1].angular.w) + SIMD4(spin, 0)
        return w
    }

    func testAHingeKeepsItsRange() {
        // A hinge about x that lets the rod lean 0.5 rad either way: it falls over and stops leaning at 0.5.
        let w = stand(.hinge(-0.5...0.5), tilt: 2)
        var worst: Float = 0
        for _ in 0..<120 {
            w.step()
            worst = max(worst, excess(w.bodies, w.joints[0]))
        }
        let (bend, twist) = angles(w.bodies, w.joints[0])
        print(String(format: "hinge: leans %.3f rad (limit 0.5), axes %.2g apart, at most %.2g past", abs(twist), bend, worst))
        XCTAssertEqual(abs(twist), 0.5, accuracy: 0.03)
        XCTAssertLessThan(worst, 0.05)
        XCTAssertLessThan(gap(w.bodies, w.joints[0]), 1e-3)
    }

    func testABallJointKeepsItsConeAndTwist() {
        // A cone of 0.6 rad and a twist of +-0.3: the rod falls over spinning about itself, and leans on the cone
        // with its twist at a limit.
        let w = stand(.ball(swing: 0.6, twist: -0.3...0.3), tilt: 1.5, spin: [0, 8, 0])
        var worst: Float = 0
        for _ in 0..<120 {
            w.step()
            worst = max(worst, excess(w.bodies, w.joints[0]))
        }
        let (swing, twist) = angles(w.bodies, w.joints[0])
        print(String(format: "ball joint: swings %.3f rad (limit 0.6), twists %.3f (limit 0.3), at most %.2g past", swing, twist, worst))
        XCTAssertEqual(swing, 0.6, accuracy: 0.03)
        XCTAssertLessThanOrEqual(abs(twist), 0.33)
        XCTAssertLessThan(worst, 0.05)
    }

    // MARK: Ragdolls

    private func ragdollScene(_ ragdolls: Int, backend: PhysicsSettings.Backend = .cpu) -> Scene {
        var settings = SceneSettings(kind: .ragdolls)
        settings.physics.ragdolls = ragdolls
        settings.physics.backend = backend
        return Scene(settings)
    }

    func testARagdollIsBuiltAsATree() {
        let w = ragdollScene(2).physics!
        XCTAssertEqual(w.bodies.count, 22)
        XCTAssertEqual(w.joints.count, 20)
        XCTAssertEqual(w.ragdolls, [SIMD2(0, 11), SIMD2(11, 11)])
        XCTAssertLessThanOrEqual(w.jointStarts.count - 1, 5, "colours")
        // Every joint starts at rest: anchors together, angles 0.
        for j in w.joints {
            XCTAssertLessThan(gap(w.bodies, j), 1e-5)
            XCTAssertEqual(excess(w.bodies, j), 0, accuracy: 1e-6)
        }
    }

    func testJoinedBodiesDontCollide() {
        let w = ragdollScene(1).physics!
        w.step()
        let k = PhysicsWorld.maxPairs
        for i in w.bodies.indices {
            for n in 0..<Int(w.pairCounts[i]) {
                let partner = w.pairs[i * k + n].partner
                guard partner & PhysicsWorld.staticBit == 0 else { continue }
                XCTAssertFalse(PhysicsWorld.joined(w.bodies[i], i, w.bodies[Int(partner)], Int(partner)), "\(i) and \(partner)")
            }
        }
    }

    func testRagdollsTumbleDownTheStairsAndRest() {
        // Six ragdolls dropped over the stairs tumble down them: their joints hold (a few mm apart at the hardest
        // landings, under the contacts' pushes) and keep their limits all the way, nothing goes through the floor,
        // and within 24 s they all sleep (18 s on the M1 Max: one settling can stir the ragdoll it leans on).
        let w = ragdollScene(6).physics!
        var worstGap: Float = 0, worstExcess: Float = 0, lowest: Float = .infinity
        for _ in 0..<1440 {
            w.step()
            for j in w.joints {
                worstGap = max(worstGap, gap(w.bodies, j))
                worstExcess = max(worstExcess, excess(w.bodies, j))
            }
            for b in w.bodies { lowest = min(lowest, b.position.y) }
        }
        let farthest = w.bodies.map(\.position.z).max() ?? 0
        let resting = w.joints.map { gap(w.bodies, $0) }.max() ?? 0
        print(String(format: "6 ragdolls, 24 s: %d of %d bodies asleep; joints apart by %.2g m (%.2g at rest), past their limits by %.2g rad at most; lowest centre %.3f m, farthest %.2f m forward",
                     asleep(w), w.bodies.count, worstGap, resting, worstExcess, lowest, farthest))
        XCTAssertEqual(asleep(w), w.bodies.count)
        XCTAssertLessThan(worstGap, 0.01)
        XCTAssertLessThan(resting, 2e-3)
        XCTAssertLessThan(worstExcess, 0.1)
        XCTAssertGreaterThan(lowest, 0.03, "a part sank through the floor")
        XCTAssertGreaterThan(farthest, -2, "some came down the stairs")
    }

    func testARagdollSleepsAndWakesWhole() {
        // A ragdoll at rest, then a hand grabbed and pulled up: every part wakes at once, and the hand lifts it.
        let w = ragdollScene(1).physics!
        run(w, 12)
        XCTAssertEqual(asleep(w), 11)
        let hand = 4   // the left forearm (pelvis, chest, head, then per side the upper arm, forearm, thigh and shin)
        let pelvis = position(w, 0).y
        let grip = position(w, hand)
        // Lifted 2.5 m by the hand: the rest hangs from it, a metre under the hand (it lay on a step: 1.6 m left the
        // pelvis hanging where it began).
        w.grab = GPUPhysicsGrab(target: SIMD4(grip + [0, 2.5, 0], 1), anchor: .zero, body: UInt32(hand))
        w.step()
        XCTAssertEqual(asleep(w), 0, "the whole ragdoll wakes")
        run(w, 3)
        XCTAssertEqual(position(w, hand).y, grip.y + 2.5, accuracy: 0.1)
        XCTAssertGreaterThan(position(w, 0).y, pelvis + 0.5, "the pelvis comes up after the hand")
        for j in w.joints { XCTAssertLessThan(gap(w.bodies, j), 5e-3) }
        // Let go: it falls and sleeps again, whole.
        w.grab.target.w = 0
        run(w, 15)
        XCTAssertEqual(asleep(w), 11)
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = RagdollTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: RagdollTests.shaders, kind: .metal, lightTypes: 0x3F, stats: false)
        RagdollTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The ragdoll scene, its world stepped by the CPU, and the GPU's copy of it.
    private func gpuScene(_ ragdolls: Int) throws -> (world: PhysicsWorld, gpu: PhysicsGPU, run: (Int, Bool) -> Void) {
        let m = try metal()
        let scene = ragdollScene(ragdolls)
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
        return (scene.physics!, gpu, run)
    }

    func testGPURagdollsMatchTheCPU() throws {
        // A quarter of a second: the drop, every joint holding the ragdolls together in the air. (Their velocities come
        // from positions 5 m out, good to 5e-4 m/s in a substep, rounded apart by the GPU's fused arithmetic; once they
        // land on each other, that is chaos.)
        let (world, gpu, run) = try gpuScene(12)
        run(15, false)
        for _ in 0..<15 { world.step() }
        var worst: Float = 0
        for (g, c) in zip(gpu.readBodies(), world.bodies) {
            worst = max(worst, length(PhysicsMath.xyz(g.position) - PhysicsMath.xyz(c.position)))
        }
        let gaps = world.joints.map { gap(gpu.readBodies(), $0) }.max() ?? 0
        print(String(format: "GPU against CPU, 12 ragdolls after 15 steps: within %.2g m; the GPU's joints apart by %.2g m", worst, gaps))
        XCTAssertLessThan(worst, 1e-3)
        XCTAssertLessThan(gaps, 1e-3)
    }

    func testGPURagdollRunsAreTheSame() throws {
        // 5 s of a pile: crowded bodies drop partners, and a pair only one of its bodies listed once took a colour beside
        // that body's other pairs (two threads moved it at once: runs parted after a second).
        let (_, gpu, run) = try gpuScene(24)
        run(300, false)
        let first = gpu.readBodies()
        run(300, true)
        let second = gpu.readBodies()
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.position, b.position)
            XCTAssertEqual(a.rotation, b.rotation)
        }
    }

    func testGPURagdollsComeToRest() throws {
        // 24 ragdolls: all asleep by 15 s on the M1 Max.
        let (world, gpu, run) = try gpuScene(24)
        run(1500, false)
        let bodies = gpu.readBodies()
        let sleeping = bodies.filter { $0.info.y & PhysicsWorld.asleep != 0 }.count
        let worstGap = world.joints.map { gap(bodies, $0) }.max() ?? 0
        let worstExcess = world.joints.map { excess(bodies, $0) }.max() ?? 0
        print(String(format: "GPU, 24 ragdolls after 25 s: %d of %d asleep; joints apart by %.2g m, past their limits by %.2g rad",
                     sleeping, bodies.count, worstGap, worstExcess))
        XCTAssertEqual(sleeping, bodies.count)
        XCTAssertLessThan(worstGap, 2e-3)
        XCTAssertLessThan(worstExcess, 0.1)
    }
}
