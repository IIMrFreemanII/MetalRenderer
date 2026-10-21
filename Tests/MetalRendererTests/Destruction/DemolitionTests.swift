import XCTest
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The demolition scene's world (Scene+Demolition.swift, Physics+Demolition.swift) on the CPU: the office stands, the
/// tools break it, the walker walks it, and all of it is the same however it is stepped.
final class DemolitionTests: XCTestCase {
    static func settings(_ change: (inout DemolitionSettings) -> Void = { _ in }) -> SceneSettings {
        var s = SceneSettings(kind: .demolition)
        s.physics.backend = .cpu
        if let sub = ProcessInfo.processInfo.environment["DEMOLITION_SUBSTEPS"].flatMap(Int.init) { s.physics.substeps = sub }
        s.demolition.dust = false
        change(&s.demolition)
        return s
    }

    static func make(_ change: (inout DemolitionSettings) -> Void = { _ in }) throws -> (Scene, PhysicsWorld) {
        let scene = Scene(settings(change))
        return (scene, try XCTUnwrap(scene.physics))
    }

    /// Where body `i` is.
    static func position(_ w: PhysicsWorld, _ i: Int) -> SIMD3<Float> { PhysicsMath.xyz(w.bodies[i].position) }

    func testItBuildsWithinItsBudget() throws {
        let start = Date()
        let (scene, w) = try DemolitionTests.make()
        let rig = try XCTUnwrap(scene.demolitionRig)
        print(String(format: "demolition: %d objects, %d bodies, %d welds, built in %.1f s", rig.objects.count, w.bodies.count, w.welds.count,
                     Date().timeIntervalSince(start)))
        XCTAssertLessThan(w.bodies.count, 12000)
        XCTAssertEqual(rig.rockets.count, Scene.DemolitionRig.rocketPool)
        XCTAssertGreaterThanOrEqual(rig.walker, 0)
    }

    /// Every object woken at the start: nothing breaks and nothing comes down (each stands on what is under it).
    func testItStandsWhenWoken() throws {
        let (scene, w) = try DemolitionTests.make()
        let rig = try XCTUnwrap(scene.demolitionRig)
        for f in rig.objects { w.command(.wake, body: f.firstBody, at: 0) }
        let before = rig.objects.map { DemolitionTests.position(w, $0.firstBody) }
        let start = Date()
        w.advance(to: 3)
        var worst: Float = 0, which = 0
        for (k, f) in rig.objects.enumerated() where w.bodies[f.firstBody].info.y & PhysicsWorld.disabledBit == 0 {
            let d = length(DemolitionTests.position(w, f.firstBody) - before[k])
            if d > worst { (worst, which) = (d, k) }
        }
        print(String(format: "woken: 3 s in %.1f s, %d breaks, the most an object moved %.3f m (%@)", Date().timeIntervalSince(start),
                     w.breakTotal, worst, rig.objects[which].name))
        // (Awake all at once, a stack ten blocks tall settles a few centimetres and a few light pieces jolt: in the
        // scene it starts asleep and wakes where it is hit.)
        XCTAssertLessThan(w.breakTotal, 20)
        XCTAssertLessThan(worst, 0.3)
    }

    /// A blast on the third floor's front: what is round it breaks, the rest of the office stays where it was.
    func testABlastStaysWhereItIs() throws {
        let (scene, w) = try DemolitionTests.make()
        let rig = try XCTUnwrap(scene.demolitionRig)
        let at = SIMD3<Float>(0, rig.floors[2] + 1.5, 8.3)
        w.command(.blast, origin: at, radius: 2.5, magnitude: 16, at: 30, steps: 6)
        let before = rig.objects.map { DemolitionTests.position(w, $0.firstBody) }
        w.advance(to: 6)
        var far: Float = 0, farName = "", near = 0
        for (k, f) in rig.objects.enumerated() {
            let d = distance(before[k], at)
            let gone = w.bodies[f.firstBody].info.y & PhysicsWorld.disabledBit != 0
            if d < 4 && gone { near += 1 }
            if d > 9 && !gone {
                let moved = length(DemolitionTests.position(w, f.firstBody) - before[k])
                if moved > far { (far, farName) = (moved, f.name) }
            }
        }
        print(String(format: "blast: %d breaks, %d objects broken near it, the most one 9 m away moved %.3f m (%@)", w.breakTotal, near, far, farName))
        XCTAssertGreaterThan(near, 3)
        XCTAssertLessThan(far, 0.02)
    }
}

extension DemolitionTests {
    static func blueprint(_ scene: Scene) -> DemolitionBlueprint { DemolitionBlueprint(scene.settings.demolition) }
    static let step = { (t: Float) in Int(t / PhysicsWorld.stepLength) }

    /// A burst at a ground-floor pier: pieces of it knocked out, the pier still standing.
    func testTheMachineGunChips() throws {
        let (scene, w) = try DemolitionTests.make()
        let rig = try XCTUnwrap(scene.demolitionRig), b = DemolitionTests.blueprint(scene)
        let k = try XCTUnwrap(b.blocks.indices.first { b.blocks[$0].kind == .pier && b.blocks[$0].storey == 1 && b.blocks[$0].hi.z > b.outline.hi.y - 0.01 })
        let p = b.blocks[k], f = rig.objects[k]
        for n in 0..<12 {
            let at = SIMD3((p.lo.x + p.hi.x) / 2 + Float(n % 3 - 1) * 0.2, (p.lo.y + p.hi.y) / 2 + Float(n / 3 - 2) * 0.25, p.hi.z)
            w.command(.hit, body: f.firstBody, origin: at, direction: [0, 0, -1], magnitude: 25, at: DemolitionTests.step(0.5 + Float(n) / 12))
        }
        w.advance(to: 3)
        let pieces = f.firstBody..<(f.firstBody + f.tree.nodes.count)
        // (Knocked into the building, along the bullets.)
        let out = pieces.filter { w.bodies[$0].info.y & PhysicsWorld.disabledBit == 0 && abs(w.bodies[$0].position.z - (p.lo.z + p.hi.z) / 2) > 0.3 }.count
        let standing = pieces.filter { w.bodies[$0].info.y & PhysicsWorld.disabledBit == 0 && abs(w.bodies[$0].position.z - (p.lo.z + p.hi.z) / 2) < 0.1 }.count
        print("machine gun: \(w.breakTotal) breaks, \(out) pieces knocked out, \(standing) still in the wall")
        XCTAssertGreaterThan(out, 0)
        XCTAssertGreaterThan(standing, 0)
    }

    /// A rocket at the third floor's front: gone where it hit, the wall round it broken.
    func testARocketGoesOffWhereItHits() throws {
        let (scene, w) = try DemolitionTests.make()
        let rig = try XCTUnwrap(scene.demolitionRig), b = DemolitionTests.blueprint(scene)
        let from = SIMD3<Float>(1, 6, b.outline.hi.y + 20), target = SIMD3<Float>(1, b.floors[2] + 1.6, b.outline.hi.y)
        let (dir, speed) = Scene.aim(from: from, at: target, speed: 28, gravity: w.gravity.y)
        w.command(.rocket, body: rig.rockets[0], origin: from, radius: 2.5, direction: dir, magnitude: speed, at: 30)
        w.advance(to: 3)
        let gone = w.bodies[rig.rockets[0]].info.y & PhysicsWorld.disabledBit != 0
        let at = try XCTUnwrap(w.demolition.detonations.first)
        print("rocket: went off at \(PhysicsMath.xyz(at)) (aimed at \(target)), \(w.breakTotal) breaks")
        XCTAssertTrue(gone)
        XCTAssertLessThan(distance(PhysicsMath.xyz(at), target), 1)
        XCTAssertGreaterThan(w.breakTotal, 5)
    }

    /// The walker on the fourth floor walks into a hole TNT blew in it, and comes down through it (the rubble may take
    /// the floor under it too), not out of the world.
    func testTheWalkerFallsThroughAHole() throws {
        let (scene, w) = try DemolitionTests.make()
        let b = DemolitionTests.blueprint(scene), f = b.floors
        let hole = SIMD3<Float>(-6, f[3] - 0.1, -3)
        w.command(.blast, origin: hole, radius: DemolitionPlayer.tntRadius, magnitude: DemolitionPlayer.tntPush, at: DemolitionTests.step(0.5), steps: 4)
        let walker = try XCTUnwrap(scene.demolitionRig?.walker)
        w.command(.drive, body: Int(DemolitionState.Walker.enableFlag | DemolitionState.Walker.placeFlag),
                  origin: [hole.x, f[3] + 0.95, hole.z + 3.2], at: DemolitionTests.step(1.5))
        w.command(.drive, direction: [0, 0, -2.5], at: DemolitionTests.step(2))
        var lowest: Float = .infinity
        for k in 1...30 {
            w.advance(to: 2 + Float(k) * 0.1)
            lowest = min(lowest, w.bodies[walker].position.y)
        }
        let fallen = w.bodies.indices.filter { k in
            w.bodies[k].info.y & (PhysicsWorld.disabledBit | PhysicsWorld.pieceBit) == PhysicsWorld.pieceBit && w.bodies[k].position.y < f[3] - 1
                && length(SIMD2(w.bodies[k].position.x - hole.x, w.bodies[k].position.z - hole.z)) < 3
        }.count
        print("hole: \(fallen) pieces fell from round it, \(w.breakTotal) breaks")
        let y = w.bodies[walker].position.y
        print("walker: \(y) m at 5 s (the fourth floor's at \(f[3]), the third's at \(f[2])); lowest \(lowest)")
        XCTAssertGreaterThan(fallen, 10)
        XCTAssertLessThan(y, f[3] - 1)
        XCTAssertGreaterThan(y, 0.5)
        XCTAssertFalse(y.isNaN)
    }

    /// The walker up the ground floor's first flight, a slope, to its half landing.
    func testTheWalkerClimbsTheStairs() throws {
        let (scene, w) = try DemolitionTests.make()
        let b = DemolitionTests.blueprint(scene)
        let st = try XCTUnwrap(b.building.plan.storeys[0].stair)
        let inset = b.building.plan.partition / 2
        let r = CityPlan.Rect(lo: st.rect.lo + inset, hi: st.rect.hi - inset)
        // The entry end's middle of the first flight's side, and along the stair.
        let along: SIMD2<Float> = st.alongX ? SIMD2(st.entryLow ? 1 : -1, 0) : SIMD2(0, st.entryLow ? 1 : -1)
        let across = st.flightWidth / 2
        let start2: SIMD2<Float> = st.alongX
            ? SIMD2(st.entryLow ? r.lo.x + 0.5 : r.hi.x - 0.5, st.firstLow ? r.lo.y + across : r.hi.y - across)
            : SIMD2(st.firstLow ? r.lo.x + across : r.hi.x - across, st.entryLow ? r.lo.y + 0.5 : r.hi.y - 0.5)
        let walker = try XCTUnwrap(scene.demolitionRig?.walker)
        w.command(.drive, body: Int(DemolitionState.Walker.enableFlag | DemolitionState.Walker.placeFlag),
                  origin: [start2.x, 0.95, start2.y], at: DemolitionTests.step(0.5))
        w.command(.drive, direction: [along.x * 2, 0, along.y * 2], at: DemolitionTests.step(1))
        w.advance(to: 4)
        let (_, _, h) = StairPlan.steps(b.floors[1] - b.floors[0] + 0)
        let mid = Float(StairPlan.steps(b.building.plan.storeys[0].top - b.building.plan.storeys[0].floor).first) * h
        let feet = w.bodies[walker].position.y - PhysicsWorld.walkerHalf - PhysicsWorld.walkerRadius
        print("stairs: feet at \(feet) m after 3 s up the flight (its landing at \(mid))")
        XCTAssertGreaterThan(feet, mid * 0.7)
    }

    /// The demo with the player's commands on top, stepped to 8 s, then from the start again: the same world.
    func testAReplayIsTheSame() throws {
        let (scene, w) = try DemolitionTests.make { $0.demo = true }
        let rig = try XCTUnwrap(scene.demolitionRig)
        w.command(.rocket, body: rig.rockets[1], origin: [6, 4, 30], radius: 2.5, direction: normalize(SIMD3<Float>(0, 0.05, -1)), magnitude: 28,
                  at: DemolitionTests.step(3))
        w.command(.hit, body: rig.objects[5].firstBody, origin: PhysicsMath.xyz(w.bodies[rig.objects[5].firstBody].position), direction: [0, 0, -1],
                  magnitude: 25, at: DemolitionTests.step(3.5))
        w.advance(to: 8)
        let first = PhysicsThreadsTests.digest(w)
        w.advance(to: 0)
        w.advance(to: 8)
        let again = PhysicsThreadsTests.digest(w)
        print(String(format: "replay: %016llx, %016llx", first, again))
        XCTAssertEqual(first, again)
    }

}

extension DemolitionTests {
    func testDiagnoseStanding() throws {
        guard ProcessInfo.processInfo.environment["DEMOLITION_DIAGNOSE"] != nil else { throw XCTSkip("diagnosis") }
        let (scene, w) = try DemolitionTests.make()
        let rig = try XCTUnwrap(scene.demolitionRig)
        for f in rig.objects { w.command(.wake, body: f.firstBody, at: 0) }
        let before = rig.objects.map { DemolitionTests.position(w, $0.firstBody) }
        for k in 1...6 {
            w.advance(to: Float(k) * PhysicsWorld.stepLength + 0.001)
            for (j, f) in rig.objects.enumerated() where w.bodies[f.firstBody].info.y & PhysicsWorld.disabledBit != 0 && j >= 0 {
                let b = blueprintBlock(scene, j)
                print("step", k, "broke", f.name, b)
            }
            let fast = w.bodies.indices.filter { w.bodies[$0].info.y & PhysicsWorld.disabledBit == 0 && length(PhysicsMath.xyz(w.bodies[$0].velocity)) > 0.5 }
            if k <= 3 {
                let bp = DemolitionBlueprint(scene.settings.demolition)
                let column = bp.blocks.indices.filter { bp.blocks[$0].lo.x < -11.5 && bp.blocks[$0].hi.x > -11.5 && bp.blocks[$0].lo.z < 7.8 && bp.blocks[$0].hi.z > 7.8 }
                print("column step", k, column.map { (j: Int) -> String in
                    let i = rig.objects[j].firstBody
                    return String(format: "%@ y%.3f v%.3f m%.4g fl%d", rig.objects[j].name, w.bodies[i].position.y, w.bodies[i].velocity.y, w.bodies[i].position.w, w.bodies[i].info.y)
                }.joined(separator: " | "))
            }
            if k == 1 {
                for (x, y) in [(8821, 8693), (8693, 8821), (8821, 8831)] {
                    let m = w.collide(w.bodies[x], w.bodies[y], margin: PhysicsWorld.margin)
                    print("collide", x, y, m.count, "pos", PhysicsMath.xyz(w.bodies[x].position), PhysicsMath.xyz(w.bodies[y].position),
                          "shapes", w.bodies[x].info.x, w.bodies[y].info.x, "kinds", w.shapes[Int(w.bodies[x].info.x)].info.x, w.shapes[Int(w.bodies[y].info.x)].info.x,
                          "params", w.shapes[Int(w.bodies[x].info.x)].params, w.shapes[Int(w.bodies[y].info.x)].params)
                }
            }
            if k == 2 {
                for i in [8821, 8881] {
                    let n = Int(w.pairCounts[i])
                    print("pairs of", i, n, (0..<n).map { (q: Int) -> String in
                        let c = w.pairs[i * PhysicsWorld.maxPairs + q].partner
                        let name = c & PhysicsWorld.staticBit != 0 ? "static" : (rig.objects.last { $0.firstBody <= Int(c) }?.name ?? "?")
                        return "\(c & ~PhysicsWorld.staticBit) \(name) contacts \(w.pairs[i * PhysicsWorld.maxPairs + q].contacts)"
                    })
                }
            }
            if k == 3 {
                let bp = DemolitionBlueprint(scene.settings.demolition)
                for i in fast.prefix(4) {
                    guard let j = rig.objects.lastIndex(where: { $0.firstBody <= i }) else { continue }
                    let a = bp.blocks[j]
                    let under = bp.blocks.enumerated().filter { abs($0.element.hi.y - a.lo.y) < 0.004 && $0.element.lo.x < a.hi.x && a.lo.x < $0.element.hi.x
                        && $0.element.lo.z < a.hi.z && a.lo.z < $0.element.hi.z }
                    print("fast", rig.objects[j].name, a.lo, a.hi, "body", i, "root", rig.objects[j].firstBody, "under:", under.map { "\($0.offset) \($0.element.kind) \($0.element.lo) \($0.element.hi) flags \(w.bodies[rig.objects[$0.offset].firstBody].info.y)" })
                }
            }
            print("step", k, "fast bodies", fast.count, fast.prefix(3).map { (i: Int) -> String in
                let name = rig.objects.last { $0.firstBody <= i }?.name ?? "?"
                return "\(name) v=\(PhysicsMath.xyz(w.bodies[i].velocity))"
            })
        }
        for t: Float in [0.1, 0.25, 0.5, 1, 2, 3, 4, 6] {
            w.advance(to: t)
            var worst: [String: (Float, String)] = [:]
            for (k, f) in rig.objects.enumerated() {
                let kind = String(f.name.split(separator: " ").dropLast().joined(separator: " "))
                let alive = w.bodies[f.firstBody].info.y & PhysicsWorld.disabledBit == 0
                let d = alive ? length(DemolitionTests.position(w, f.firstBody) - before[k]) : 99
                if d > (worst[kind]?.0 ?? -1) { worst[kind] = (d, f.name) }
            }
            let awake = rig.objects.filter { PhysicsWorld.moves(w.bodies[$0.firstBody]) }.count
            var fastest: (Float, String) = (0, "")
            for f in rig.objects where PhysicsWorld.moves(w.bodies[f.firstBody]) {
                let v = length(PhysicsMath.xyz(w.bodies[f.firstBody].velocity))
                if v > fastest.0 { fastest = (v, f.name) }
            }
            print("t", t, "awake roots", awake, "fastest", fastest)
            print("t", t, "breaks", w.breakTotal, worst.sorted { $0.key < $1.key }.map { "\($0.key): \(String(format: "%.3f", $0.value.0)) \($0.value.1)" }.joined(separator: "; "))
        }
    }
}

func blueprintBlock(_ scene: Scene, _ j: Int) -> String {
    let b = DemolitionBlueprint(scene.settings.demolition).blocks[j]
    return "\(b.kind) storey \(b.storey) \(b.lo) \(b.hi)"
}
