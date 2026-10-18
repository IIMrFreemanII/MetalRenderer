import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Physics+Fracture.swift and Scene+Fracture.swift: fractured objects that stand, break under impacts into pieces held
/// by their welds, come free, fade; the GPU's steps against the CPU's through a break; replays.
final class DestructionTests: XCTestCase {
    /// A scene with nothing of its own (the Cornell room has no physics), its world given a floor.
    private func scene() -> Scene {
        let s = Scene(SceneSettings(kind: .cornell))
        s.addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        return s
    }

    private func wall(_ s: Scene, pieces: [Int] = [14, 6], at centre: SIMD3<Float> = [0, 1.25, 0], strength: Float = 1,
                      toughness: Float = 1) -> Scene.Fractured {
        var r = FractureRecipe.defaults(.concrete)
        r.counts = pieces
        return s.addFractured("wall", shape: SDFShape(.box(halfExtents: [1.7, 1.25, 0.15])), recipe: r, transform: translate(centre),
                              material: 0, interior: 0, anchor: .ground(0), toughness: toughness, strength: strength)
    }

    /// A ball of `mass` kg shot from `from` at `target`.
    private func ball(_ s: Scene, from: SIMD3<Float>, at target: SIMD3<Float>, speed: Float, radius: Float = 0.15, mass: Float = 100) -> Int {
        let world = s.physicsWorld()
        let b = world.bodies.count
        let density = mass / (4 / 3 * .pi * pow(radius, 3))
        s.addBody(sdf: s.addSDFShape(SDFShape(.sphere(radius: radius))), 0, translate(from), density: density, friction: 0.4,
                  restitution: 0.1, velocity: normalize(target - from) * speed)
        return b
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) { w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2) }

    /// How many of the object's nodes are enabled, how many of those moved more than `far` from where they started
    /// (in their parent's place at rest), and how many welds broke.
    private func census(_ w: PhysicsWorld, _ f: Scene.Fractured, far: Float = 0.15) -> (enabled: Int, moved: Int, broken: Int) {
        var enabled = 0, moved = 0
        for k in f.tree.nodes.indices {
            let i = f.firstBody + k
            guard w.bodies[i].info.y & PhysicsWorld.disabledBit == 0 else { continue }
            enabled += 1
            if length(PhysicsMath.xyz(w.bodies[i].position) - PhysicsMath.xyz(w.initialBodies[i].position)) > far { moved += 1 }
        }
        return (enabled, moved, w.welds.filter { $0.info.z != 0 }.count)
    }

    // MARK: The tree

    func testTheCellsFillTheObject() {
        for material in FractureMaterial.allCases {
            let box = ConvexCell(box: [-1, -0.8, -0.1], [1, 0.8, 0.1])
            let tree = FractureTree(recipe: FractureRecipe.defaults(material), cell: box)
            XCTAssertGreaterThan(tree.nodes.count, 3, "\(material)")
            // Every node's children fill it.
            for node in tree.nodes where !node.isLeaf {
                let sum = node.children.reduce(Float(0)) { $0 + tree.nodes[$1].cell.volume }
                XCTAssertEqual(sum, node.cell.volume, accuracy: node.cell.volume * 1e-3, "\(material) level \(node.level)")
            }
            XCTAssertFalse(tree.welds.isEmpty, "\(material)")
        }
    }

    func testTheSameSeedMakesTheSamePieces() {
        let box = ConvexCell(box: [-1, -1, -1], [1, 1, 1])
        let a = FractureTree(recipe: FractureRecipe.defaults(.concrete), cell: box)
        let b = FractureTree(recipe: FractureRecipe.defaults(.concrete), cell: box)
        XCTAssertEqual(a.nodes.count, b.nodes.count)
        for (x, y) in zip(a.nodes, b.nodes) { XCTAssertEqual(x.cell.centroid, y.cell.centroid) }
        XCTAssertEqual(a.welds.count, b.welds.count)
    }

    // MARK: Breaking

    /// The scene on the CPU: each object's census along the demo (a look at what the scene does, not a check).
    func testTheSceneAlongItsDemo() throws {
        guard ProcessInfo.processInfo.environment["DESTRUCTION_SCENE"] != nil else { throw XCTSkip("set DESTRUCTION_SCENE=1") }
        var settings = SceneSettings(kind: .destruction)
        settings.physics.backend = .cpu
        let s = Scene(settings)
        let w = s.physics!
        let times: [Float] = ProcessInfo.processInfo.environment["DESTRUCTION_TIMES"].map { $0.split(separator: ",").compactMap { Float($0) } }
            ?? [2.5, 3.2, 4, 5, 6.6, 8]
        for t in times {
            w.advance(to: t)
            print("t \(t): " + s.destructionRig!.objects.map { f in
                let c = census(w, f)
                return "\(f.name) \(c.enabled)/\(c.moved)/\(c.broken)"
            }.joined(separator: ", "))
        }
    }

    /// The scene's brick wall and its cannonball (which once slid the wall off its foot, and once flung bricks 20 m:
    /// welds pulled shut from a centimetre away).
    func testABrickWallKeepsMostOfItsBricks() {
        let s = scene()
        var r = FractureRecipe.defaults(.brick)
        r.brick = [0.4, 0.16, 0.22]
        r.seed = 21
        let f = s.addFractured("bricks", shape: SDFShape(.box(halfExtents: [1.4, 0.88, 0.11])), recipe: r, transform: translate([1.5, 0.88, -5.2]),
                               material: 0, interior: 0, anchor: .ground(0))
        let w = s.physics!
        let b = w.bodies.count
        s.addBody(sdf: s.addSDFShape(SDFShape(.sphere(radius: 0.17))), 0, translate([0, -50, 0]), density: 7000, friction: 0.4, restitution: 0.1)
        w.disable(b)
        let from = SIMD3<Float>(0.5, 1.6, 8)
        let (dir, speed) = Scene.aim(from: from, at: [1.7, 0.8, -5.2], speed: 16, gravity: w.gravity.y)
        w.command(.shoot, body: b, origin: from, direction: dir, magnitude: speed, at: 30)
        w.finish()
        run(w, 3)
        let c = census(w, f)
        var farthest: Float = 0
        for k in f.tree.nodes.indices where w.bodies[f.firstBody + k].info.y & PhysicsWorld.disabledBit == 0 {
            let i = f.firstBody + k
            farthest = max(farthest, length(PhysicsMath.xyz(w.bodies[i].position) - PhysicsMath.xyz(w.initialBodies[i].position)))
        }
        print("bricks: \(f.tree.nodes.count) nodes, \(f.tree.welds.count) welds; 3 s: \(c.enabled) enabled, \(c.moved) moved, \(c.broken) broken, farthest \(farthest) m")
        XCTAssertGreaterThan(c.enabled, 1, "the wall broke")
        XCTAssertLessThan(Float(c.moved), 0.3 * Float(c.enabled), "most of the wall still stands")
        XCTAssertLessThan(farthest, 6, "nothing is flung")
    }

    func testAnAnchoredWallStands() {
        let s = scene()
        let f = wall(s)
        let w = s.physics!
        w.finish()
        run(w, 3)
        let c = census(w, f)
        XCTAssertEqual(c.enabled, 1, "nothing broke it")
        XCTAssertEqual(c.moved, 0)
    }

    func testAShotMakesAHoleNotAHeap() {
        let s = scene()
        let f = wall(s)
        _ = ball(s, from: [0.3, 1.4, 4], at: [0.3, 1.4, 0], speed: 15, mass: 120)
        let w = s.physics!
        w.finish()
        run(w, 0.4)
        let hit = census(w, f)
        run(w, 2.6)
        let later = census(w, f)
        let leaves = f.tree.leaves
        print("shot: \(f.tree.nodes.count) nodes (\(leaves) leaves, \(f.tree.welds.count) welds); 0.4 s: \(hit.enabled) enabled, \(hit.moved) moved, \(hit.broken) welds broken; 3 s: \(later.enabled) enabled, \(later.moved) moved, \(later.broken) broken")
        XCTAssertGreaterThan(hit.enabled, 1, "the wall broke")
        XCTAssertGreaterThan(later.moved, 0, "pieces were knocked out")
        XCTAssertLessThan(Float(later.moved), 0.5 * Float(later.enabled), "most of the wall still stands")
    }

    // MARK: Commands

    func testABlastBreaksAndAReplayDoesTheSame() {
        let s = scene()
        let f = wall(s)
        let w = s.physics!
        w.finish()
        w.command(.blast, origin: [0.4, 1.2, 0.4], radius: 1.3, magnitude: 10, at: 10, steps: 6)
        run(w, 1.5)
        let first = w.bodies, c = census(w, f)
        XCTAssertGreaterThan(c.enabled, 1, "the blast broke the wall")
        XCTAssertGreaterThan(c.moved, 0)
        // Back to the start and on again: the same breaks, the same places.
        w.advance(to: 0.5)
        w.advance(to: 1.5 + PhysicsWorld.stepLength / 2)
        for (a, b) in zip(first, w.bodies) {
            XCTAssertEqual(a.info.y, b.info.y)
            XCTAssertEqual(a.position, b.position)
        }
    }

    func testFadedPiecesGo() {
        let s = scene()
        var r = FractureRecipe.defaults(.concrete)
        r.counts = [10, 8]
        let f = s.addFractured("wall", shape: SDFShape(.box(halfExtents: [1.7, 1.25, 0.15])), recipe: r, transform: translate([0, 1.25, 0]),
                               material: 0, interior: 0, anchor: .ground(0), fadeRadius: 0.4)
        let w = s.physics!
        w.fractureTuning.x = 1   // fade a second after lying still
        w.finish()
        w.command(.blast, origin: [0, 1.2, 0.4], radius: 2, magnitude: 14, at: 5, steps: 6)
        run(w, 8)
        var faded = 0
        for k in f.tree.nodes.indices where f.tree.nodes[k].isLeaf {
            let i = f.firstBody + k
            if w.bodies[i].info.y & PhysicsWorld.disabledBit != 0 && w.fractureNodes[i].extra.z > 0
                && w.fractureState[i].strain.y > 0 { faded += 1 }
        }
        XCTAssertGreaterThan(faded, 0, "small still pieces faded away")
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")

    /// The GPU's steps against the CPU's through a shot's break: the same step, the same pieces, about the same places
    /// (a weld near its strength breaks on one and not the other, from float rounding: they part, as a pile does).
    func testTheGPUBreaksAsTheCPUDoes() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: DestructionTests.shaders, lightTypes: 0x3F, stats: false)
        let s = scene()
        let f = wall(s)
        _ = ball(s, from: [0.3, 1.4, 4], at: [0.3, 1.4, 0], speed: 15, mass: 120)
        let w = s.physics!
        w.finish()
        let sdf = try SDFBuffers(device: device, scene: s)
        let gpu = try PhysicsGPU(device: device, world: w, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        func steps(_ n: Int) {
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            gpu.encodeSteps(Metal3Pass(enc: enc), pipelines: pipelines, steps: n)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
            for _ in 0..<n { w.step() }
        }
        func compare() -> (differ: Int, worst: Float) {
            var worst: Float = 0, differ = 0
            for (g, c) in zip(gpu.readBodies(), w.bodies) {
                if g.info.y & PhysicsWorld.disabledBit != c.info.y & PhysicsWorld.disabledBit { differ += 1 }
                worst = max(worst, length(PhysicsMath.xyz(g.position) - PhysicsMath.xyz(c.position)))
            }
            return (differ, worst)
        }
        steps(16)   // the shot's break (step 14) and its children's first steps
        let early = compare(), enabled = census(w, f).enabled
        steps(20)
        let late = compare()
        print("GPU against CPU through a break: \(enabled) enabled; after 16 steps \(early.differ) differ, within \(early.worst) m; after 36 \(late.differ) differ")
        XCTAssertGreaterThan(enabled, 1, "it broke")
        XCTAssertEqual(early.differ, 0, "the same pieces enabled")
        // (A weld at its strength breaks in one and holds in the other a substep after the break: 1.3 mm then, 13 mm at
        // 16 steps, in this one.)
        XCTAssertLessThan(early.worst, 0.03)
        XCTAssertEqual(late.differ, 0, "the same pieces still")
    }
}
