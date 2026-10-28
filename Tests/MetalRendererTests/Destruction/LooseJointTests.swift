import XCTest
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

/// Physics+LooseJoints.swift: welds that give way go loose before they break. A row of bricks held at its ends (a
/// bridge) or at one end (a ledge), its welds too weak to hold it rigid: with loose joints it sags and hangs; without,
/// it falls. Loose links let go under a hit, past their fatigue, and the same way in a replay and on any threads.
final class LooseJointTests: XCTestCase {
    /// A scene with nothing of its own, its world given a floor.
    private func scene() -> Scene {
        let s = Scene(SceneSettings(kind: .cornell))
        s.addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        return s
    }

    /// A row of bricks 3 m long, 2 m up, already in pieces (its root disabled), the end bricks held (both ends, or the
    /// left one only), its welds holding `strength` x the brick's; `loose` the world's loose joints.
    private func row(_ s: Scene, bothEnds: Bool = true, height: Float = 5, strength: Float, loose: LooseJoints?) -> (Scene.Fractured, [Int]) {
        var r = FractureRecipe.defaults(.brick)
        r.counts = [0]
        r.brick = [0.3, 0.2, 0.4]
        r.seed = 3
        let f = s.addFractured("row", shape: SDFShape(.box(halfExtents: [1.5, 0.1, 0.2])), recipe: r, transform: translate([0, height, 0]),
                               material: 0, interior: 0, anchor: .none, strength: strength)
        let w = s.physics!
        w.looseJoints = loose
        w.bodies[f.firstBody].info.y |= PhysicsWorld.disabledBit
        var bricks: [Int] = []
        for k in f.tree.nodes.indices where k > 0 {
            let i = f.firstBody + k
            w.bodies[i].info.y &= ~PhysicsWorld.disabledBit
            bricks.append(i)
            let x = f.tree.nodes[k].cell.vertices.map(\.x)
            if (x.min() ?? 0) < -1.45 || (bothEnds && (x.max() ?? 0) > 1.45) {
                w.bodies[i].info.y |= PhysicsWorld.anchoredBit
                w.bodies[i].position.w = 0
                w.fractureNodes[i].info.w |= PhysicsWorld.anchoredNode
            }
        }
        return (f, bricks)
    }

    /// How many of `bricks` are still linked to a held one through welds holding or loose.
    private func linked(_ w: PhysicsWorld, _ bricks: [Int]) -> Int {
        var seen = Set(bricks.filter { w.bodies[$0].info.y & PhysicsWorld.anchoredBit != 0 && w.bodies[$0].position.w == 0 })
        var queue = Array(seen)
        while let i = queue.popLast() {
            for k in Int(w.weldStarts[i])..<Int(w.weldStarts[i + 1]) where w.welds[Int(w.weldList[k].y)].info.z != 1 {
                let j = Int(w.weldList[k].x)
                if w.bodies[j].info.y & PhysicsWorld.disabledBit == 0, seen.insert(j).inserted { queue.append(j) }
            }
        }
        return seen.count
    }

    private func run(_ w: PhysicsWorld, _ seconds: Float) { w.advance(to: w.time + seconds + PhysicsWorld.stepLength / 2) }

    /// The most any brick dropped (m), and whether any position isn't a number.
    private func drop(_ w: PhysicsWorld, _ bricks: [Int]) -> (most: Float, nan: Bool) {
        var most: Float = 0, nan = false
        for i in bricks {
            let y = w.bodies[i].position.y
            if !y.isFinite { nan = true }
            most = max(most, w.initialBodies[i].position.y - y)
        }
        return (most, nan)
    }

    /// A ledge whose welds can't hold it out (strength 0.2): with loose joints it swings down and hangs on its links,
    /// then comes down when their time is up; without, it falls at once.
    func testALedgeHangsOnItsLinksThenFalls() {
        for loose in [false, true] {
            let s = scene()
            let (_, bricks) = row(s, bothEnds: false, strength: 0.2, loose: loose ? LooseJoints() : nil)
            let w = s.physics!
            w.finish()
            func onFloor() -> Int { bricks.filter { w.initialBodies[$0].position.y - w.bodies[$0].position.y > 4.6 }.count }
            var fastest: Float = 0
            for _ in 0..<15 {
                run(w, 0.1)
                for i in bricks { fastest = max(fastest, length(PhysicsMath.xyz(w.bodies[i].velocity))) }
            }
            let hung = linked(w, bricks), d = drop(w, bricks), floor = onFloor(), c = w.weldStates
            run(w, 4.5)   // (past the longest a link lasts: 3 s and half that again)
            let later = linked(w, bricks), floorLater = onFloor()
            print("ledge, loose \(loose): 1.5 s \(hung) of \(bricks.count) linked, \(floor) on the floor, dropped \(d.most) m, fastest \(fastest) m/s, welds \(c); 6 s \(later) linked, \(floorLater) on the floor")
            XCTAssertFalse(d.nan)
            if loose {
                XCTAssertEqual(hung, bricks.count, "every brick hangs on")
                XCTAssertEqual(floor, 0)
                XCTAssertGreaterThan(d.most, 1, "it swung down")
                XCTAssertGreaterThan(c.loose, 0)
                // (A fall from the ledge's height reaches 9.9 m/s; a swinging chain's tip whips past that, the more
                // the play it catches up: 9.4 m/s with 2 cm, 12.5 with 10. Blowing up would be far more.)
                XCTAssertLessThan(fastest, 15, "nothing flung")
                XCTAssertEqual(later, 1, "its links' time is up")
                XCTAssertGreaterThan(floorLater, bricks.count / 2, "and it came down")
            } else {
                XCTAssertGreaterThan(floor, 0, "without loose joints it falls at once")
                XCTAssertGreaterThan(floorLater, bricks.count / 2)
            }
        }
    }

    /// A blast on the hanging ledge cuts its links; a link that carries a load tires and lets go.
    func testLinksLetGo() {
        do {
            let s = scene()
            let (_, bricks) = row(s, bothEnds: false, strength: 0.2, loose: LooseJoints())
            let w = s.physics!
            w.finish()
            run(w, 1.2)
            let before = linked(w, bricks)
            // (A blast as big as the ledge swings it whole; one on a brick near the anchor cuts it there.)
            let target = PhysicsMath.xyz(w.bodies[bricks[2]].position)
            w.command(.blast, origin: target + SIMD3(0, 0, 0.3), radius: 0.4, magnitude: 40, steps: 2)
            run(w, 1)
            let why = (1...6).map { k in w.welds.filter { $0.loose.z == Float(k) }.count }
            print("blast: \(before) linked before, \(linked(w, bricks)) after; let go by load/stretch/fatigue/freed/broke/time \(why)")
            XCTAssertEqual(before, bricks.count)
            XCTAssertLessThan(linked(w, bricks), before, "the blast cut links")
        }
        do {
            let s = scene()
            var tired = LooseJoints()
            tired.fatigueFloor = 0
            tired.fatigueLimit = 0.05
            let (_, bricks) = row(s, bothEnds: false, strength: 0.2, loose: tired)
            let w = s.physics!
            w.finish()
            run(w, 1.4)
            let fatigued = w.welds.filter { $0.loose.z == 3 }.count
            print("fatigue: \(linked(w, bricks)) linked at 1.4 s (before any link's time is up), \(fatigued) links tired out")
            XCTAssertGreaterThan(fatigued, 0, "loaded links tire")
            XCTAssertLessThan(linked(w, bricks), bricks.count)
        }
    }

    /// The same hang in a replay, and on one thread as on all.
    func testAReplayAndTheThreadsAgree() {
        func hang(threads: Bool) -> [GPUPhysicsBody] {
            PhysicsPool.shared.enabled = threads
            defer { PhysicsPool.shared.enabled = true }
            let s = scene()
            _ = row(s, bothEnds: false, strength: 0.2, loose: LooseJoints())
            let w = s.physics!
            w.finish()
            run(w, 2)
            let first = w.bodies
            w.advance(to: 0.5)
            w.advance(to: 2 + PhysicsWorld.stepLength / 2)
            for (a, b) in zip(first, w.bodies) { XCTAssertEqual(a.position, b.position, "a replay is the same") }
            return w.bodies
        }
        let one = hang(threads: false), all = hang(threads: true)
        for (a, b) in zip(one, all) {
            XCTAssertEqual(a.position, b.position, "one thread and all agree")
            XCTAssertEqual(a.rotation, b.rotation)
        }
    }

    /// The demolition demo and the massive building with loose joints and without: each second, the welds holding,
    /// loose and broken, how many enabled pieces are still above 2 m, the highest one, and the CPU's time a step.
    /// (`LOOSE_PROBE=1`: a measurement, not a check.)
    func testProbeTheScenes() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOOSE_PROBE"] == "1" else { throw XCTSkip("LOOSE_PROBE=1 runs it") }
        // (LOOSE_SCENES=destruction or demolition for one; LOOSE_TUNE="share,floor,limit;..." for loose joints so tuned.)
        let kinds: [SceneKind] = env["LOOSE_SCENES"] == "destruction" ? [.destruction] : env["LOOSE_SCENES"] == "demolition" ? [.demolition] : [.demolition, .destruction]
        var tunes: [LooseJoints?] = [nil, LooseJoints()]
        if let t = env["LOOSE_TUNE"] {
            tunes = [nil] + t.split(separator: ";").map { v -> LooseJoints? in
                let f = v.split(separator: ",").compactMap { Float($0) }
                var l = LooseJoints()
                (l.share, l.fatigueFloor, l.fatigueLimit) = (f[0], f[1], f[2])
                if f.count > 3 { l.lifetime = f[3] }
                if f.count > 4 { l.slack = f[4] }
                return l
            }
        }
        for kind in kinds {
            for tune in tunes {
                let loose = tune != nil
                var settings = SceneSettings(kind: kind)
                settings.physics.backend = .cpu
                settings.demolition.demo = true
                settings.demolition.dust = false
                settings.demolition.looseJoints = loose
                settings.destruction.massive = true
                settings.destruction.dust = false
                settings.destruction.looseJoints = loose
                if let x = env["LOOSE_STRENGTH"].flatMap(Float.init) { settings.destruction.strength = x }
                let scene = Scene(settings)
                let w = try XCTUnwrap(scene.physics)
                w.looseJoints = tune
                print("\(kind) loose \(tune.map { "share \($0.share) fatigue \($0.fatigueFloor) \($0.fatigueLimit)" } ?? "off"): \(w.bodies.count) bodies, \(w.welds.count) welds")
                for second in 1...12 {
                    let start = Date()
                    w.advance(to: Float(second))
                    let ms = Date().timeIntervalSince(start) * 1000 / Double(1 / PhysicsWorld.stepLength)
                    var up = 0, top: Float = 0
                    for b in w.bodies where b.info.y & (PhysicsWorld.pieceBit | PhysicsWorld.disabledBit) == PhysicsWorld.pieceBit {
                        if b.position.y > 2 { up += 1 }
                        top = max(top, b.position.y)
                    }
                    let c = w.weldStates
                    let why = (1...6).map { k in w.welds.filter { $0.loose.z == Float(k) }.count }
                    if second == 3 && loose && env["LOOSE_WHERE"] == "1" {
                        for k in w.welds.indices where w.welds[k].info.z == 2 {
                            let a = w.bodies[Int(w.welds[k].info.x)], b = w.bodies[Int(w.welds[k].info.y)]
                            print(String(format: "    link %d at (%.1f, %.1f, %.1f), pieces %.2f / %.2f kg, moved %.2f m, load lately %.2f, F %.0f",
                                         k, a.position.x, a.position.y, a.position.z, a.position.w > 0 ? 1 / a.position.w : 0,
                                         b.position.w > 0 ? 1 / b.position.w : 0,
                                         length(PhysicsMath.xyz(a.position) - PhysicsMath.xyz(w.initialBodies[Int(w.welds[k].info.x)].position)),
                                         Float(bitPattern: w.welds[k].info.w), w.welds[k].anchorA.w))
                        }
                    }
                    print(String(format: "  %2d s: welds %d holding, %d loose, %d broken (loose let go by load/stretch/fatigue/freed/broke/time %@); %d pieces above 2 m, top %.1f m; %.1f ms a step",
                                 second, c.holding, c.loose, c.broken, why.description, up, top, ms))
                }
            }
        }
    }
}
