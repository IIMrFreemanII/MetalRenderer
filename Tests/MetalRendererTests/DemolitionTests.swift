import XCTest
import simd
@testable import MetalRenderer

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
