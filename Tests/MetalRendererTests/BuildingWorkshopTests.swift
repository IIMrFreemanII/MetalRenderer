import XCTest
import Metal
import QuartzCore
import simd
@testable import MetalRenderer

/// The building workshop (Scene+Buildings.swift): what it holds, and how long an edit's new scene takes to make with
/// its structures (it is made again at every edit).
final class BuildingWorkshopTests: XCTestCase {
    private func workshop(_ change: (inout BuildingSceneSettings) -> Void = { _ in }) -> Scene {
        var s = SceneSettings(kind: .buildings)
        change(&s.buildings)
        return Scene(s)
    }

    /// One building inside and out: walkable (its colliders, its door's way in), its doors and switches, its stats;
    /// the cutaway leaves the storeys above its cut out.
    func testTheWorkshopHoldsABuilding() {
        let s = workshop { $0.floors = 4 }
        XCTAssertEqual(s.walkAreas.count, 1)
        XCTAssertGreaterThan(s.walkColliders.count, 200)
        XCTAssertFalse(s.interiorControls?.doors.isEmpty ?? true)
        let stats = try? XCTUnwrap(s.buildingStats)
        XCTAssertEqual(stats?.storeys, 4)
        XCTAssertGreaterThan(stats?.rooms ?? 0, 20)
        XCTAssertNotNil(s.focus)
        let cut = workshop { $0.floors = 4; $0.view = .cutaway; $0.cut = 1 }
        let top = cut.walkColliders.map(\.hi.y).max() ?? 0, full = s.walkColliders.map(\.hi.y).max() ?? 0
        XCTAssertLessThan(top, full - 3, "nothing above the cut")
        // At night its lit rooms are lit, and every room can be switched.
        let night = workshop { $0.floors = 4; $0.night = true }
        XCTAssertGreaterThan(night.interiorControls?.switches.count ?? 0, 10)
        XCTAssertGreaterThan(night.lights.count, s.lights.count)
    }

    /// From every room of every storey, straight at each of its four sides: the walker stays in the building (or on
    /// a balcony), its doors shut, and on its floor. (Each built-in style on the workshop's lot for it.)
    func testNoWayOutButTheDoors() {
        for (style, lot, floors) in [("office", SIMD2<Float>(34, 30), 8), ("residential", SIMD2(20, 14), 4), ("oldtown", SIMD2(9, 12), 3),
                                     ("warehouse", SIMD2(30, 26), 2), ("modern", SIMD2(22, 15), 3)] {
            let s = workshop { $0.style = style; $0.lot = lot; $0.floors = floors; $0.sides = .free }
            guard let area = s.walkAreas.first, let c = s.interiorControls else { XCTFail(style); continue }
            for i in c.doors.indices { c.doors[i].auto = false; c.doors[i].open = 0; c.doors[i].target = 0 }
            for i in c.lifts.indices { c.lifts[i].doors = 0 }
            let grid = ColliderGrid(s.walkColliders), inverse = area.at.inverse
            var escapes = 0
            for f in area.building.plan.storeys {
                for room in f.rooms where !room.type.isCore {
                    for out in [SIMD2<Float>(1, 0), [-1, 0], [0, 1], [0, -1]] {
                        let start = area.at * SIMD4(room.rect.center.x, f.floor + 0.05, room.rect.center.y, 1)
                        var w = Walker(feet: SIMD3(start.x, start.y, start.z))
                        var remainder: Float = 0
                        let o4 = area.at * SIMD4(out.x, 0, out.y, 0)
                        for _ in 0..<(60 * 8) {
                            w.advance(1 / 60, input: Walker.Input(move: SIMD2(o4.x, o4.z)), world: grid, moving: c.obstacles, remainder: &remainder)
                        }
                        let local = inverse * SIMD4(w.feet, 1)
                        let r = area.rect
                        let outside = local.x < r.lo.x - 2 || local.x > r.hi.x + 2 || local.z < r.lo.y - 2 || local.z > r.hi.y + 2
                        if outside || w.feet.y < start.y - 0.3 {
                            escapes += 1
                            if escapes <= 5 {
                                XCTFail("\(style) storey \(f.storey): from the \(room.type) toward \(out), out at \(local) (lot \(r.lo)...\(r.hi))")
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(escapes, 0, style)
        }
    }

    /// The loose furniture: bodies that rest where they stand (on their floors, not through them) and fall asleep; a
    /// shove moves one, and it stays on its floor.
    func testLooseFurnitureRestsAndMoves() throws {
        let s = workshop { $0.floors = 3 }
        let physics = try XCTUnwrap(s.physics)
        let props = try XCTUnwrap(s.interiorControls?.props)
        XCTAssertGreaterThan(props.count, 3)
        let start = props.map { PhysicsMath.xyz(physics.bodies[$0.body].position) }
        physics.advance(to: 4)
        for (k, p) in props.enumerated() {
            let x = PhysicsMath.xyz(physics.bodies[p.body].position)
            XCTAssertLessThan(abs(x.y - start[k].y), 0.25, "prop \(k) fell or flew")
            XCTAssertLessThan(length(SIMD2(x.x, x.z) - SIMD2(start[k].x, start[k].z)), 0.3, "prop \(k) slid away")
        }
        XCTAssertGreaterThan(physics.bodies.filter { $0.info.y & PhysicsWorld.asleep != 0 }.count, props.count / 2, "they sleep")
        // A shove: the walker walking into the first one.
        let p = props[0], x = PhysicsMath.xyz(physics.bodies[p.body].position)
        let feet = SIMD3(x.x - Walker.radius - p.half.x, x.y - p.half.y, x.z)
        for k in 0..<30 {
            s.interiorControls?.push(physics, feet: feet + SIMD3(Float(k) * 0.02, 0, 0), velocity: [1.4, 0, 0], height: 1.8)
            physics.advance(to: 4 + Float(k + 1) / 60)
        }
        physics.advance(to: 7)
        let moved = PhysicsMath.xyz(physics.bodies[p.body].position)
        XCTAssertGreaterThan(moved.x - x.x, 0.05, "the shove moved it")
        XCTAssertGreaterThan(moved.y, x.y - p.half.y - 0.05, "it stayed on its floor")
    }

    /// A style that is a little different, the same building otherwise: what an edit makes.
    func testRemakingIsQuick() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { throw XCTSkip("no Metal ray tracing") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for (name, change) in [("house", { (p: inout BuildingSceneSettings) in p.style = "oldtown"; p.lot = SIMD2(9, 12); p.floors = 3 }),
                               ("apartments", { $0.style = "residential"; $0.lot = SIMD2(22, 14); $0.floors = 6 }),
                               ("office tower", { $0.style = "office"; $0.lot = SIMD2(34, 30); $0.sides = .free; $0.floors = 12 })]
                as [(String, (inout BuildingSceneSettings) -> Void)] {
            var best = Double.infinity, sceneMs = 0.0, made: Scene?
            for seed in 1...3 {
                let start = CACurrentMediaTime()
                let scene = workshop { change(&$0); $0.seed = seed }
                let built = CACurrentMediaTime()
                _ = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
                let total = (CACurrentMediaTime() - start) * 1000
                if total < best { best = total; sceneMs = (built - start) * 1000; made = scene }
            }
            let stats = made?.buildingStats
            print(String(format: "Building workshop %@: %.1f ms (scene %.1f, buffers %.1f); %d storeys, %d rooms, %d + %d triangles",
                         name, best, sceneMs, best - sceneMs, stats?.storeys ?? 0, stats?.rooms ?? 0, stats?.shellTriangles ?? 0,
                         stats?.interiorTriangles ?? 0))
            XCTAssertLessThan(best, 3000, name)
        }
    }
}
