import XCTest
import Metal
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Plants

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

    /// The scene's brick wall and its cannonball, which knocks bricks out of it (and once slid the wall off its foot,
    /// once flung bricks 20 m: welds pulled shut from a centimetre away; once stopped dead against it; once went through
    /// and the wall around the hole toppled after it).
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
        XCTAssertGreaterThan(c.moved, 0, "the shot knocked bricks out")
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

    /// A shot breaks the wall where it hits and knocks the pieces there out, and most of the wall stands. (It met the
    /// wall whole, held by the ground, in the step it broke, and stopped dead: it goes on now, into the pieces.)
    func testAShotBreaksTheWallWhereItHits() {
        let s = scene()
        let f = wall(s)
        _ = ball(s, from: [0.3, 1.4, 4], at: [0.3, 1.4, 0], speed: 15, mass: 120)
        let w = s.physics!
        w.finish()
        run(w, 0.4)
        let hit = census(w, f)
        var freed = 0
        for k in f.tree.nodes.indices where w.bodies[f.firstBody + k].info.y & PhysicsWorld.disabledBit == 0 {
            let i = f.firstBody + k
            let held = (Int(w.weldStarts[i])..<Int(w.weldStarts[i + 1])).contains { w.welds[Int(w.weldList[$0].y)].info.z == 0 }
            if w.bodies[i].position.w > 0 && !held { freed += 1 }
        }
        run(w, 2.6)
        let later = census(w, f)
        let leaves = f.tree.leaves
        print("shot: \(f.tree.nodes.count) nodes (\(leaves) leaves, \(f.tree.welds.count) welds); 0.4 s: \(hit.enabled) enabled, \(freed) free, \(hit.broken) welds broken; 3 s: \(later.enabled) enabled, \(later.moved) moved, \(later.broken) broken")
        XCTAssertGreaterThan(hit.enabled, 1, "the wall broke")
        XCTAssertGreaterThan(freed, 0, "the pieces at the hit came free")
        XCTAssertGreaterThan(later.moved, 0, "the shot knocked pieces out")
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

    private static let shaders = SourceTree.packageRoot.appendingPathComponent("Sources/MetalRenderer/Shaders.metal")

    /// The massive setting's building through its demo on the GPU, a line every half second: the building's live and
    /// sleeping pieces, their speeds and kinetic energy, the heap's height and reach, pieces faded, bodies with full pair
    /// lists, one-sided pair entries, the deepest contact. (A heap that never settled: DESTRUCTION_SETTLE=1.)
    func testTheBuildingSettles() throws {
        guard ProcessInfo.processInfo.environment["DESTRUCTION_SETTLE"] != nil else { throw XCTSkip("set DESTRUCTION_SETTLE=1") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: DestructionTests.shaders, lightTypes: 0x3F, stats: false)
        var settings = SceneSettings(kind: .destruction)
        settings.destruction.massive = true
        settings.destruction.statues = false
        settings.physics.backend = .gpu
        let s = Scene(settings)
        let w = s.physics!
        let sdf = try SDFBuffers(device: device, scene: s)
        let gpu = try PhysicsGPU(device: device, world: w, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        let building = w.initialBodies.indices.filter {
            w.initialBodies[$0].info.y & PhysicsWorld.pieceBit != 0 && w.initialBodies[$0].position.z < -11.5
        }
        let seconds = Float(ProcessInfo.processInfo.environment["DESTRUCTION_SECONDS"] ?? "") ?? 20
        let half = Int(0.5 / PhysicsWorld.stepLength)
        var peak: Float = 0
        print("settle: \(building.count) building bodies of \(w.bodies.count)")
        for k in 1...Int(seconds * 2) {
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            gpu.encodeSteps(Metal3Pass(enc: enc), pipelines: pipelines, steps: half)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
            let bodies = gpu.readBodies(), state = gpu.readFractureState(), (pairs, counts, contacts) = gpu.readPairs()
            var live = 0, asleep = 0, faded = 0, energy: Float = 0, fastest: Float = 0, speeds: Float = 0
            var heights: [Float] = [], reaches: [Float] = []
            for i in building {
                let b = bodies[i]
                if b.info.y & PhysicsWorld.disabledBit != 0 {
                    if w.fractureNodes[i].extra.z > 0 && state[i].direction.w <= 0 { faded += 1 }
                    continue
                }
                live += 1
                if b.info.y & PhysicsWorld.asleep != 0 { asleep += 1 }
                let v = length(PhysicsMath.xyz(b.velocity))
                speeds += v
                fastest = max(fastest, v)
                if b.position.w > 0 { energy += 0.5 * v * v / b.position.w }
                heights.append(b.position.y)
                reaches.append(length(SIMD2(b.position.x, b.position.z + 15)))
            }
            peak = max(peak, energy)
            heights.sort()
            reaches.sort()
            func at(_ a: [Float], _ q: Float) -> Float { a.isEmpty ? 0 : a[min(Int(Float(a.count) * q), a.count - 1)] }
            // Pieces held by a live weld, against the loose ones: how many of each sleep.
            let welds = gpu.readWelds()
            var welded = 0, weldedAsleep = 0, loose = 0, looseAsleep = 0
            for i in building where bodies[i].info.y & PhysicsWorld.disabledBit == 0 && bodies[i].position.w > 0 {
                let held = (Int(w.weldStarts[i])..<Int(w.weldStarts[i + 1])).contains { welds[Int(w.weldList[$0].y)].info.z == 0 }
                let sleeps = bodies[i].info.y & PhysicsWorld.asleep != 0
                if held { welded += 1; if sleeps { weldedAsleep += 1 } } else { loose += 1; if sleeps { looseAsleep += 1 } }
            }
            print("settle welded \(weldedAsleep)/\(welded) asleep, loose \(looseAsleep)/\(loose); " + heapLine(bodies, building, centre: [0, -15]))
            var full = 0, oneSided = 0, deepest: Float = 0
            for i in building where bodies[i].info.y & PhysicsWorld.disabledBit == 0 {
                let n = Int(counts[i])
                if n == PhysicsWorld.maxPairs { full += 1 }
                for e in i * PhysicsWorld.maxPairs..<i * PhysicsWorld.maxPairs + n {
                    if pairs[e].link == PhysicsWorld.none { oneSided += 1; continue }
                    guard pairs[e].link == UInt32(e) else { continue }
                    for c in 0..<Int(pairs[e].contacts) { deepest = min(deepest, contacts[e * PhysicsWorld.maxContacts + c].normal.w) }
                }
            }
            print(String(format: "settle t %4.1f: live %4d asleep %4d (%3.0f%%) mean %.3f max %.2f m/s energy %8.1f J (%5.1f%% of peak) height %.2f reach %.2f faded %3d full %3d one-sided %4d deepest %.3f",
                         Float(k) * 0.5, live, asleep, 100 * Float(asleep) / Float(max(live, 1)), speeds / Float(max(live, 1)), fastest,
                         energy, 100 * energy / max(peak, 1e-6), at(heights, 0.95), at(reaches, 0.9), faded, full, oneSided, deepest))
        }
        // The end: the deepest contacts and the fastest pieces, what they are and what they touch.
        let bodies = gpu.readBodies(), (pairs, counts, contacts) = gpu.readPairs(), welds = gpu.readWelds()
        func describe(_ i: Int) -> String {
            let b = bodies[i], node = w.fractureNodes[i]
            var live = 0
            for k in Int(w.weldStarts[i])..<Int(w.weldStarts[i + 1]) where welds[Int(w.weldList[k].y)].info.z == 0 { live += 1 }
            return String(format: "%d (%@, r %.2f, v %.2f w %.2f y %.2f, %d live welds, %@)", i, node.info.z > 0 ? "inner" : "leaf",
                          b.invInertia.w, length(PhysicsMath.xyz(b.velocity)), length(PhysicsMath.xyz(b.angular)), b.position.y, live,
                          b.position.w == 0 ? "held" : b.info.y & PhysicsWorld.asleep != 0 ? "asleep" : "awake")
        }
        var deep: [(Float, Int, UInt32, UInt32)] = []
        for i in building where bodies[i].info.y & PhysicsWorld.disabledBit == 0 {
            for e in i * PhysicsWorld.maxPairs..<i * PhysicsWorld.maxPairs + Int(counts[i]) where pairs[e].link == UInt32(e) {
                for c in 0..<Int(pairs[e].contacts) where contacts[e * PhysicsWorld.maxContacts + c].lambda.w != 1 {
                    deep.append((contacts[e * PhysicsWorld.maxContacts + c].normal.w, i, pairs[e].partner, pairs[e].contacts))
                }
            }
        }
        deep.sort { $0.0 < $1.0 }
        print("deep contacts under 2 cm: \(deep.filter { $0.0 < -0.02 }.count)")
        for (d, i, partner, n) in deep.prefix(6) {
            print(String(format: "deep %.3f (%d contacts): ", d, n) + describe(i) + " with "
                  + (partner & PhysicsWorld.staticBit != 0 ? "static \(partner & ~PhysicsWorld.staticBit)" : describe(Int(partner))))
        }
        let fastest = building.filter { bodies[$0].info.y & PhysicsWorld.disabledBit == 0 }
            .sorted { length(PhysicsMath.xyz(bodies[$0].velocity)) > length(PhysicsMath.xyz(bodies[$1].velocity)) }
        for i in fastest.prefix(6) {
            print("fast " + describe(i) + ", pairs \(counts[i])")
            for e in i * PhysicsWorld.maxPairs..<i * PhysicsWorld.maxPairs + Int(counts[i]) {
                let q = pairs[e], owner = Int(q.link == PhysicsWorld.none ? UInt32(e) : q.link)
                let n = Int(pairs[owner].contacts)
                let deepest = (0..<n).map { contacts[owner * PhysicsWorld.maxContacts + $0].normal.w }.min() ?? 0
                let weld = n == 1 && contacts[owner * PhysicsWorld.maxContacts].lambda.w == 1
                guard n > 0 else { continue }
                print(String(format: "    %@ %d contacts%@ %.3f", q.link == PhysicsWorld.none ? "ONE-SIDED" : "", n, weld ? " (weld)" : "", deepest)
                      + " " + (q.partner & PhysicsWorld.staticBit != 0 ? "static \(q.partner & ~PhysicsWorld.staticBit)" : describe(Int(q.partner))))
            }
        }
    }

    /// A line of a heap's state: how many of `ids` sleep, their mean and top speed, the heap's height (95th percentile)
    /// and reach about `centre` (90th, across).
    private func heapLine(_ bodies: [GPUPhysicsBody], _ ids: [Int], centre: SIMD2<Float>) -> String {
        var asleep = 0, live = 0, speeds: Float = 0, fastest: Float = 0, heights: [Float] = [], reaches: [Float] = []
        for i in ids where bodies[i].info.y & PhysicsWorld.disabledBit == 0 {
            let b = bodies[i], v = length(PhysicsMath.xyz(b.velocity))
            live += 1
            if b.info.y & PhysicsWorld.asleep != 0 { asleep += 1 }
            speeds += v
            fastest = max(fastest, v)
            heights.append(b.position.y)
            reaches.append(length(SIMD2(b.position.x, b.position.z) - centre))
        }
        heights.sort()
        reaches.sort()
        func at(_ a: [Float], _ q: Float) -> Float { a.isEmpty ? 0 : a[min(Int(Float(a.count) * q), a.count - 1)] }
        var each = ids.filter { bodies[$0].info.y & PhysicsWorld.disabledBit == 0 }.map { length(PhysicsMath.xyz(bodies[$0].velocity)) }
        each.sort()
        let stills = ids.map { bodies[$0].prevPosition.w }.sorted()
        return String(format: "asleep %3.0f%% mean %.3f p50 %.3f p90 %.3f max %.2f m/s still p50 %.2f s height %.2f reach %.2f",
                      100 * Float(asleep) / Float(max(live, 1)), speeds / Float(max(live, 1)), at(each, 0.5), at(each, 0.9), fastest,
                      at(stills, 0.5), at(heights, 0.95), at(reaches, 0.9))
    }

    /// 196 loose concrete shards (a 20 cm slab's Voronoi cells, freed: no welds, nothing to break) dropped four deep,
    /// on the CPU and the GPU: asleep in 8 s, still a heap. They once rocked on (the edge walk of the narrow phase,
    /// on a cell's distance, ended somewhere new each step), crept flat and never slept.
    /// 196 concrete shards dropped four deep onto the ground (testALooseHeapSettles), and with `ball` a cannonball
    /// kept aside for a shot.
    private func looseHeap(ball: Bool = false) -> (Scene, [Int], Int?) {
        let s = scene()
        let w = s.physicsWorld()
        var r = FractureRecipe.defaults(.concrete)
        r.counts = [150]
        var ids: [Int] = []
        for slab in 0..<2 {
            r.seed = 7 + UInt64(slab)
            let tree = FractureTree(recipe: r, cell: ConvexCell(box: [-1.5, -0.1, -1.2], [1.5, 0.1, 1.2]))
            for (k, node) in tree.nodes.enumerated() where node.isLeaf && k > 0 && ids.count < 196 {
                let n = ids.count
                let at = SIMD3<Float>(Float(n % 7) - 3, 0.5 + Float(n / 49) * 0.45, Float((n / 7) % 7) - 3) * SIMD3(0.45, 1, 0.45)
                let spin = rotate(Float(n) * 2.39996, normalize(SIMD3<Float>(sin(Float(n)), 1, cos(Float(n) * 1.7))))
                let shape = SDFShape(.cell(planes: node.cell.planes { _ in true }, lo: node.cell.bounds.lo, hi: node.cell.bounds.hi))
                let sdf = s.addSDFShape(shape)
                ids.append(w.bodies.count)
                w.addPiece(sdf: sdf, shape, build: PhysicsWorld.pieceShape(node.cell, sdf: sdf),
                           transform: translate(at) * spin * translate(-node.cell.centroid), instance: 0, material: .concrete)
            }
        }
        for i in ids { w.bodies[i].info.y |= PhysicsWorld.pieceBit }   // (freed pieces of nothing: roots that never break)
        var shot: Int?
        if ball {   // (a cannonball out of the way, for a shot: testASleepingHeapWakesWhereItIsTouched)
            shot = w.bodies.count
            s.addBody(sdf: s.addSDFShape(SDFShape(.sphere(radius: 0.15))), 0, translate([0, -50, 0]), density: 7000, friction: 0.4, restitution: 0.1)
            w.disable(shot!)
        }
        w.fractureNodes = [GPUFractureNode](repeating: GPUFractureNode(), count: w.bodies.count)
        w.finish()
        return (s, ids, shot)
        }

    func testALooseHeapSettles() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: DestructionTests.shaders, lightTypes: 0x3F, stats: false)
        let (cs, ids, _) = looseHeap(), (gs, _, _) = looseHeap()
        let cw = cs.physics!, gw = gs.physics!
        let sdf = try SDFBuffers(device: device, scene: gs)
        let gpu = try PhysicsGPU(device: device, world: gw, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        run(cw, 8)
        for _ in 0..<8 {
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            gpu.encodeSteps(Metal3Pass(enc: enc), pipelines: pipelines, steps: Int(1 / PhysicsWorld.stepLength))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        for (name, bodies) in [("CPU", cw.bodies), ("GPU", gpu.readBodies())] {
            let asleep = ids.filter { bodies[$0].info.y & PhysicsWorld.asleep != 0 }.count
            let heights = ids.map { bodies[$0].position.y }.sorted()
            let top = heights[heights.count * 95 / 100]
            print("loose heap on the \(name) at 8 s: \(asleep) of \(ids.count) asleep, " + heapLine(bodies, ids, centre: .zero))
            XCTAssertGreaterThanOrEqual(asleep, ids.count * 95 / 100, "the \(name)'s heap sleeps")
            XCTAssertGreaterThan(top, 0.33, "the \(name)'s heap is a heap, not a layer")
        }
    }

    /// The GPU's steps against the CPU's through a shot's break: the same step, the same pieces, about the same places
    /// (a weld near its strength breaks on one and not the other, from float rounding: they part, as a pile does).
    /// A sleeping heap (PhysicsCPU.settle, wake) touched three ways: a shot into it, a blast beside it, a piece pulled
    /// out of it. Each wakes and moves pieces where it touches, and leaves most of the far side asleep; the heap sleeps
    /// again; and woken all at once then, nothing moves more than a few cm: nothing slept in the air, or mid-slide.
    func testASleepingHeapWakesWhereItIsTouched() {
        for way in ["shot", "blast", "grab"] {
            let (s, ids, shot) = looseHeap(ball: true)
            let w = s.physics!
            run(w, 8)
            let asleep = { ids.filter { w.bodies[$0].info.y & PhysicsWorld.asleep != 0 }.count }
            XCTAssertGreaterThan(asleep(), ids.count * 9 / 10, "\(way): the heap asleep first")
            let before = ids.map { PhysicsMath.xyz(w.bodies[$0].position) }
            var at = SIMD3<Float>()
            switch way {
            case "shot":
                at = [0.6, 0.4, 0]
                let from = SIMD3<Float>(6, 1.2, 0)
                let (dir, speed) = Scene.aim(from: from, at: at, speed: 14, gravity: w.gravity.y)
                w.command(.shoot, body: shot!, origin: from, direction: dir, magnitude: speed)
            case "blast":
                at = [-1.4, 0.3, 0]
                w.command(.blast, origin: at, radius: 0.8, magnitude: 6, steps: 3)
            default:
                let top = ids.max { w.bodies[$0].position.y < w.bodies[$1].position.y }!
                at = PhysicsMath.xyz(w.bodies[top].position)
                w.grab = GPUPhysicsGrab(target: SIMD4(at + [0.8, 1.2, 0], 1), anchor: .zero, body: UInt32(top))
                run(w, 0.75)
                w.grab = GPUPhysicsGrab()
            }
            run(w, 0.5)
            var nearMoved = 0, far = 0, farMoved = 0
            for (k, i) in ids.enumerated() {
                let moved = length(PhysicsMath.xyz(w.bodies[i].position) - before[k]) > 0.02
                let d = length(before[k] - at)
                if d < 1 && moved { nearMoved += 1 }
                if d > 2.5 { far += 1; if moved { farMoved += 1 } }
            }
            run(w, 10)
            let again = asleep()
            let settled = ids.map { PhysicsMath.xyz(w.bodies[$0].position) }
            w.wakeAll()
            run(w, 1)
            let drift = ids.indices.map { length(PhysicsMath.xyz(w.bodies[ids[$0]].position) - settled[$0]) }.sorted()
            print(String(format: "sleeping heap, %@: moved near %d, far %d of %d; asleep again %d of %d; woken all, drift p99 %.3f max %.3f m",
                         way as NSString, nearMoved, farMoved, far, again, ids.count, drift[drift.count * 99 / 100], drift.last!))
            XCTAssertGreaterThan(nearMoved, 0, "\(way): pieces where it touched moved")
            XCTAssertLessThan(farMoved, max(far / 10, 2), "\(way): the far side stayed")
            XCTAssertGreaterThan(again, ids.count * 8 / 10, "\(way): asleep again")
            XCTAssertLessThan(drift.last!, 0.05, "\(way): nothing asleep in the air or mid-slide")
        }
    }

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
        // (Then the shot goes on into the pieces, some at their thresholds: one breaks a step later in one than the
        // other, it and its children, 7 bodies, here.)
        XCTAssertLessThanOrEqual(late.differ, 8, "the same pieces still, but for one at its threshold")
    }
}
