import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Hair and fur (PhysicsHair.swift, Shaders/Physics.metal's hair kernels, Scene+Hair.swift, HairBSDF.swift): strands
/// that keep their length and shape, hang, follow their bodies, stay out of what they touch, rest and wake with their
/// bodies and blow in the wind; the scene's drawn strands; the GPU's steps and strands against the CPU's; the BSDF.
final class HairTests: XCTestCase {
    private func world() -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0])
        return w
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) {
        w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2)
    }

    private func vertices(_ w: PhysicsWorld, _ s: Int) -> [SIMD3<Float>] {
        let strand = w.hairStrands[s]
        return (0..<Int(strand.info.z)).map { PhysicsMath.xyz(w.hairVertices[Int(strand.info.y) + $0].position) }
    }

    /// A strand of `n` vertices, `length` long, straight from `root` along `direction`, held by `body` (nil: the world),
    /// with stiffness in rad/s.
    @discardableResult
    private func strand(_ w: PhysicsWorld, body: Int? = nil, root: SIMD3<Float>, direction: SIMD3<Float>, length: Float, n: Int = 10,
                        global: (Float, Float) = (0, 0), local: Float = 0) -> Int {
        let points = (0..<n).map { root + normalize(direction) * length * Float($0) / Float(n - 1) }
        let across = normalize(cross(direction, abs(direction.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)))
        return w.addStrand(body: body, points: points, radius: 0.002, globalRoot: global.0, globalTip: global.1, local: local, across: across)
    }

    // MARK: Strands

    func testAStrandKeepsItsLength() {
        // Long hair from a point in the air, swinging down in a gusting breeze for 3 s: follow-the-leader keeps every
        // segment at its length.
        let w = world()
        strand(w, root: [0, 2, 0], direction: [1, 0.3, 0], length: 0.5, n: 14)
        w.wind = SIMD4(1.5, 0, 0.5, 0.8)
        w.finish()
        var worst: Float = 0
        for _ in 0..<180 {
            w.step()
            let v = vertices(w, 0)
            for i in 1..<v.count { worst = max(worst, abs(length(v[i] - v[i - 1]) / (0.5 / 13) - 1)) }
        }
        print(String(format: "a strand's segments within %.2g of their length", worst))
        XCTAssertLessThan(worst, 1e-3)
    }

    func testLongHairHangs() {
        // Straight out sideways, with no stiffness: it swings down and hangs.
        let w = world()
        strand(w, root: [0, 2, 0], direction: [1, 0, 0], length: 0.4)
        w.finish()
        run(w, 4)
        let tip = vertices(w, 0).last!
        XCTAssertLessThan(tip.y, 2 - 0.38)
        XCTAssertLessThan(abs(tip.x), 0.03)
    }

    func testFurKeepsItsShape() {
        // The scene's fur stiffness (80 rad/s at the root, 30 at the tip, 40 locally): upright it doesn't move; out
        // sideways gravity bends it by about g / omega^2.
        let w = world()
        strand(w, root: [0, 1, 0], direction: [0, 1, 0], length: 0.07, n: 6, global: (80, 30), local: 40)
        strand(w, root: [1, 1, 0], direction: [1, 0, 0], length: 0.07, n: 6, global: (80, 30), local: 40)
        w.finish()
        let rest = [vertices(w, 0), vertices(w, 1)]
        run(w, 2)
        let up = zip(vertices(w, 0), rest[0]).map { length($0 - $1) }.max()!
        let side = zip(vertices(w, 1), rest[1]).map { length($0 - $1) }.max()!
        print(String(format: "fur upright moved %.2g m, out sideways sagged %.2g m", up, side))
        XCTAssertLessThan(up, 1e-3)
        XCTAssertLessThan(side, 0.015)
    }

    func testRootsFollowTheirBody() {
        // A ball thrown up spinning: its strands' roots stay where it holds them, to rounding.
        let w = world()
        let b = w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.2)), transform: translate([0, 1, 0]), instance: 0,
                          velocity: [0.5, 3, 0], spin: [4, 7, -3])
        for d in [SIMD3<Float>(1, 0, 0), [0, 1, 0], [0, 0, -1], normalize(SIMD3<Float>(1, 1, 1))] {
            strand(w, body: b, root: SIMD3<Float>(0, 1, 0) + d * 0.201, direction: d, length: 0.1, n: 5, global: (60, 15), local: 30)
        }
        w.finish()
        var worst: Float = 0
        for _ in 0..<40 {
            w.step()
            let pose = PhysicsWorld.Pose(w.bodies[b])
            for s in w.hairStrands.indices {
                let root = w.hairVertices[Int(w.hairStrands[s].info.y)]
                worst = max(worst, length(PhysicsMath.xyz(root.position) - pose.toWorld(PhysicsMath.xyz(root.rest))))
            }
        }
        XCTAssertLessThan(worst, 1e-5)
    }

    func testStrandsStayOutOfWhatTheyTouch() {
        // Long hair from above a ball lying on the floor, falling over it onto the floor: no vertex sinks into the
        // ball or the floor by more than a millimetre past its radius.
        let w = world()
        let ball = w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.25)), transform: translate([0, 0.25, 0]), instance: 0)
        for k in 0..<8 {
            let a = Float(k) * .pi / 4
            strand(w, root: [0.05 * cos(a), 0.6, 0.05 * sin(a)], direction: [cos(a), 0.2, sin(a)], length: 0.6, n: 14)
        }
        w.finish()
        var floor: Float = 0, inside: Float = 0
        for _ in 0..<240 {
            w.step()
            let c = PhysicsMath.xyz(w.bodies[ball].position)
            for v in w.hairVertices {
                let x = PhysicsMath.xyz(v.position)
                floor = max(floor, v.position.w - x.y)
                inside = max(inside, 0.25 + v.position.w - length(x - c))
            }
        }
        print(String(format: "hair into the floor %.2g m, into the ball %.2g m (past its radius)", floor, inside))
        XCTAssertLessThan(floor, 1e-3)
        XCTAssertLessThan(inside, 1e-3)
    }

    func testStrandsRestAndWakeWithTheirBody() {
        // A furry ball dropped on the floor: once it sleeps its strands stop; nudged, they move again.
        let w = world()
        let b = w.addBody(sdf: 0, SDFShape(.sphere(radius: 0.2)), transform: translate([0, 0.5, 0]), instance: 0, friction: 0.8)
        for k in 0..<20 {
            let y = 1 - 2 * (Float(k) + 0.5) / 20, r = (1 - y * y).squareRoot(), a = Float(k) * 2.4
            let d = SIMD3<Float>(r * cos(a), y, r * sin(a))
            strand(w, body: b, root: SIMD3<Float>(0, 0.5, 0) + d * 0.201, direction: d, length: 0.06, n: 5, global: (60, 15), local: 30)
        }
        w.finish()
        run(w, 6)
        XCTAssertNotEqual(w.bodies[b].info.y & PhysicsWorld.asleep, 0, "the ball sleeps")
        XCTAssertEqual(w.hairStrands.filter { $0.info.w == 1 }.count, 20, "its strands are still")
        let before = w.hairVertices.map(\.position)
        w.step()
        XCTAssertEqual(w.hairVertices.map(\.position), before, "still strands don't move")
        w.bodies[b].info.y &= ~PhysicsWorld.asleep
        w.bodies[b].velocity = SIMD4(1, 0, 0, w.bodies[b].velocity.w)
        w.step()
        XCTAssertEqual(w.hairStrands.filter { $0.info.w == 1 }.count, 0, "woken with it")
    }

    func testTheBreezeBlowsHair() {
        // Two hanging strands, one in a breeze along +x: it leans downwind; the other hangs straight.
        func tip(_ wind: SIMD4<Float>) -> SIMD3<Float> {
            let w = world()
            strand(w, root: [0, 2, 0], direction: [0, -1, 0], length: 0.4)
            w.wind = wind
            w.finish()
            run(w, 3)
            return vertices(w, 0).last!
        }
        let calm = tip(.zero), windy = tip(SIMD4(3, 0, 0, 0))
        print("tip in calm air", calm, "in the breeze", windy)
        XCTAssertLessThan(abs(calm.x), 1e-4)
        XCTAssertGreaterThan(windy.x, 0.03)
    }

    // MARK: The scene

    private func hairScene(hair: Int = 2, fur: Int = 2) -> Scene {
        var settings = SceneSettings(kind: .hair)
        settings.physics.hair = hair
        settings.physics.furBodies = fur
        settings.physics.backend = .cpu
        return Scene(settings)
    }

    func testTheSceneDrawsItsStrandsAsCurves() {
        let full = hairScene(hair: 12, fur: 6).physics!
        let drawn = full.hairGroups.reduce(0) { $0 + Int($1.counts.y * $1.counts.z) }
        let points = full.hairGroups.reduce(0) { $0 + Int($1.counts.y * $1.counts.z * ($1.counts.w + 2)) }
        print("the hair scene: \(full.hairStrands.count) guides (\(full.hairVertices.count) vertices), \(drawn) drawn strands (\(points) control points)")
        let scene = hairScene(hair: 3, fur: 2)
        let w = scene.physics!
        XCTAssertTrue(scene.hasCurves)
        XCTAssertEqual(scene.curveMeshes.count, w.hairGroups.count)
        XCTAssertEqual(w.hairGroups.count, 3)   // two furry bodies and the mannequin's head
        for (g, m) in scene.hairMeshes {
            let group = w.hairGroups[g], mesh = scene.meshes[m]
            XCTAssertEqual(group.mesh.x, mesh.vertexOffset)
            XCTAssertEqual(group.mesh.y, mesh.prevOffset)
            XCTAssertNotEqual(mesh.prevOffset, 0)
            XCTAssertEqual(mesh.indexCount, 0, "no triangles")
            let n = Int(group.counts.w)
            XCTAssertEqual(scene.curveMeshes[m]!.segments, Int(group.counts.y * group.counts.z) * (n - 1))
            // A guide's own drawn strand is the guide (curling about it), with a phantom point at each end.
            let guide = vertices(w, Int(group.counts.x))
            let drawn = w.drawnStrand(group: group, 0)
            XCTAssertEqual(drawn.count, n + 2)
            for i in 0..<n { XCTAssertLessThan(length(drawn[i + 1] - guide[i]), group.shape.z + 1e-6) }
        }
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = HairTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: HairTests.shaders, kind: .metal, lightTypes: 0x3F, stats: false)
        HairTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The hair scene, its world stepped by the CPU, and the GPU's copy of it: `run` encodes steps, `encode` anything.
    private func gpuScene(hair: Int = 2, fur: Int = 2, wind: Bool = true) throws
        -> (scene: Scene, gpu: PhysicsGPU, run: (Int) -> Void, encode: ((ComputePass) -> Void) -> Void) {
        let m = try metal()
        let scene = hairScene(hair: hair, fur: fur)
        if !wind { scene.physics!.wind = .zero }
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

    func testGPUHairMatchesTheCPU() throws {
        // The first two steps. (A strand's velocities come from its vertices' moves over a substep, 1/960 s: the GPU's
        // fused rounding of positions a metre or two out moves them by micrometres, mm/s, which hanging hair keeps;
        // after five steps the two are millimetres apart, then they part as two swinging pendulums would.)
        let (scene, gpu, run, _) = try gpuScene()
        let world = scene.physics!
        run(2)
        for _ in 0..<2 { world.step() }
        var worst: Float = 0
        for (g, c) in zip(gpu.readHairVertices(), world.hairVertices) {
            worst = max(worst, length(PhysicsMath.xyz(g.position) - PhysicsMath.xyz(c.position)))
        }
        print(String(format: "GPU against CPU, hair after 2 steps: within %.2g m", worst))
        XCTAssertLessThan(worst, 1e-3)
    }

    func testGPUHairRunsAreTheSame() throws {
        let (_, gpu, run, _) = try gpuScene(fur: 4)
        run(200)
        let first = gpu.readHairVertices().map(\.position)
        let (_, again, rerun, _) = try gpuScene(fur: 4)
        rerun(200)
        XCTAssertEqual(first, again.readHairVertices().map(\.position))
    }

    func testGPUDrawsTheStrandsTheCPUDoes() throws {
        // The drawn strands' control points, from the guides as the steps left them: the GPU's kernel against
        // PhysicsWorld.drawnStrand (the GPU's guides and bodies read back into the world).
        let (scene, gpu, run, encode) = try gpuScene(hair: 3)
        let m = try metal(), world = scene.physics!
        run(20)
        world.hairVertices = gpu.readHairVertices()
        world.bodies = gpu.readBodies()
        let positions = m.device.makeBuffer(length: (scene.positions.count + 16) * 16, options: .storageModeShared)!
        encode { gpu.encodeHairCurves($0, pipelines: m.pipelines, slot: 0, positions: positions) }
        let p = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: scene.positions.count)
        var worst: Float = 0
        for group in world.hairGroups {
            let n = Int(group.counts.w) + 2
            for r in stride(from: 0, to: Int(group.counts.y * group.counts.z), by: 7) {
                for (k, x) in world.drawnStrand(group: group, r).enumerated() {
                    worst = max(worst, length(p[Int(group.mesh.x) + r * n + k] - x))
                }
            }
        }
        print(String(format: "GPU's drawn strands within %.2g m of the CPU's", worst))
        XCTAssertLessThan(worst, 1e-5)
    }

    func testGPUHairComesToRest() throws {
        // No breeze: the furry bodies sleep at the foot of the ramp, and their strands are still, but for a few where
        // two bodies' fur is squeezed between them: pushed out of the one, pulled back to its shape on the other, they
        // stir by millimetres a step (11 of the 2100 here).
        let (scene, gpu, run, _) = try gpuScene(fur: 3, wind: false)
        run(720)
        let bodies = gpu.readBodies(), world = scene.physics!
        let strands = world.hairStrands.indices.filter { world.hairStrands[$0].info.x < 3 }   // the furry bodies'
        let sleeping = strands.filter { bodies[Int(world.hairStrands[$0].info.x)].info.y & PhysicsWorld.asleep != 0 }
        XCTAssertEqual(sleeping.count, strands.count, "the furry bodies sleep")
        let before = gpu.readHairVertices()
        run(1)
        let after = gpu.readHairVertices()
        var moved = 0, worst: Float = 0
        for s in strands {
            let first = Int(world.hairStrands[s].info.y), n = Int(world.hairStrands[s].info.z)
            if (first..<(first + n)).contains(where: { after[$0].position != before[$0].position }) {
                moved += 1
                let d = (first..<(first + n)).map { length(PhysicsMath.xyz(after[$0].position) - PhysicsMath.xyz(before[$0].position)) }.max()!
                worst = max(worst, d)
            }
        }
        print("strands on the sleeping bodies that still moved:", moved, "of", strands.count, "by up to", worst, "m")
        XCTAssertLessThan(moved, strands.count / 100)
        XCTAssertLessThan(worst, 0.02)
    }

    // MARK: BSDF

    func testTheHairBSDFKeepsEnergy() {
        // A white furnace: light from every direction onto a strand that absorbs nothing comes back whole (Chiang et
        // al.'s lobes are normalised), averaged across it; a coloured strand gives back less.
        func furnace(view: SIMD3<Float>, sigma: SIMD3<Float>) -> Float {
            var total: Float = 0
            let n = 120, hs = 16
            for hi in 0..<hs {
                let h = -1 + 2 * (Float(hi) + 0.5) / Float(hs)
                for i in 0..<n {
                    let ct = -1 + 2 * (Float(i) + 0.5) / Float(n), st = (1 - ct * ct).squareRoot()
                    for j in 0..<(2 * n) {
                        let phi = 2 * Float.pi * (Float(j) + 0.5) / Float(2 * n)
                        total += HairBSDF.scatter(tangent: [1, 0, 0], view: view, h: h, wi: [ct, st * cos(phi), st * sin(phi)],
                                                  color: .one, sigma: sigma).x
                    }
                }
            }
            return total * 4 * .pi / Float(n * 2 * n * hs)
        }
        for angle: Float in [0, 0.6, 1.2] {
            let view = SIMD3<Float>(sin(angle), cos(angle), 0)
            let white = furnace(view: view, sigma: .zero), brown = furnace(view: view, sigma: HairBSDF.sigmaA([0.3, 0.15, 0.08]))
            print(String(format: "furnace at %.1f rad: %.4f white, %.4f brown", angle, white, brown))
            XCTAssertEqual(white, 1, accuracy: 0.01)
            XCTAssertLessThan(brown, white)
        }
    }

    func testTheCuticleTiltsTheHighlight() {
        // Seen square on, a strand that absorbs all that enters it shows only its R lobe: its brightest light comes
        // from 2 alpha off the mirror direction (Marschner's shift), not from the mirror direction itself.
        let view = SIMD3<Float>(0, 1, 0)
        var best: (angle: Float, value: Float) = (0, 0)
        for k in -200...200 {
            let theta = Float(k) * 0.002
            let wi = SIMD3<Float>(sin(theta), cos(theta), 0)
            let v = HairBSDF.scatter(tangent: [1, 0, 0], view: view, h: 0, wi: wi, color: .one, sigma: SIMD3(repeating: 50)).x
            if v > best.value { best = (theta, v) }
        }
        print(String(format: "R lobe's peak at %.3f rad (2 alpha = %.3f)", best.angle, 2 * HairBSDF.alpha))
        XCTAssertEqual(abs(best.angle), 2 * HairBSDF.alpha, accuracy: 0.02)
    }
}
