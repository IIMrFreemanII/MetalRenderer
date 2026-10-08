import XCTest
import simd
@testable import MetalRenderer

/// The walker (Walker.swift) among a generated building's colliders (Building+Interior.swift) and the ground: it
/// comes in through the door, climbs the stairs to the next floor, doesn't pass walls or glass, jumps and crouches.
final class WalkerTests: XCTestCase {
    private func building(_ style: CityStyle = .residential, size: SIMD2<Float> = SIMD2(22, 14), floors: Int = 4) -> (Building, ColliderGrid) {
        var spec = BuildingSpec(size: size)
        (spec.style, spec.floors, spec.seed, spec.interior) = (style, floors, 7, true)
        spec.edges = [.street, .party, .open, .party]
        let b = BuildingGenerator.generate(spec)
        let ground = Interior.Collider(lo: [-100, -1, -100], hi: [100, 0, 100])
        return (b, ColliderGrid(b.interior!.colliders + [ground]))
    }

    /// Walks toward each of `points` in turn (x, z) for at most `seconds`: where it ends up.
    private func walk(_ w: inout Walker, _ grid: ColliderGrid, through points: [SIMD2<Float>], seconds: Float = 30) {
        var remainder: Float = 0, next = 0, time: Float = 0
        while time < seconds && next < points.count {
            let to = points[next] - SIMD2(w.feet.x, w.feet.z)
            if length(to) < 0.2 { next += 1; continue }
            w.advance(1 / 60, input: Walker.Input(move: normalize(to)), world: grid, remainder: &remainder)
            time += 1 / 60
        }
    }

    private func settle(_ w: inout Walker, _ grid: ColliderGrid) {
        var remainder: Float = 0
        for _ in 0..<120 { w.advance(1 / 60, input: Walker.Input(), world: grid, remainder: &remainder) }
    }

    /// From the street through the front door into the building: on its ground floor, inside its walls.
    func testComesInThroughTheDoor() {
        let (b, grid) = building()
        let door = b.plan.outsideDoors(0)[0]
        let inside = b.plan.storeys[0].rooms[door.a].rect.center
        var w = Walker(feet: SIMD3(door.at.x, 0, door.at.y + 2))
        settle(&w, grid)
        XCTAssertEqual(w.feet.y, 0, accuracy: 0.01, "stands on the ground")
        walk(&w, grid, through: [door.at + SIMD2(0, 0.5), door.at - SIMD2(0, 1.0), inside])
        XCTAssertEqual(w.feet.y, b.plan.storeys[0].floor, accuracy: 0.02, "on the ground floor, up the step")
        XCTAssertLessThan(distance(SIMD2(w.feet.x, w.feet.z), inside), 0.4, "got to the lobby's middle")
    }

    /// Up the stair's two flights, from each storey to the next.
    func testClimbsTheStairs() {
        let (b, grid) = building(floors: 4)
        let plan = b.plan
        guard let st = plan.storeys[0].stair else { return XCTFail("no stair") }
        let length = st.alongX ? st.rect.size.x : st.rect.size.y, width = st.alongX ? st.rect.size.y : st.rect.size.x
        let w2 = st.flightWidth / 2
        func point(_ u: Float, _ v: Float) -> SIMD2<Float> {
            let r = st.rect
            let along = st.alongX ? (st.entryLow ? r.lo.x + u : r.hi.x - u) : (st.entryLow ? r.lo.y + u : r.hi.y - u)
            let across = st.alongX ? (st.firstLow ? r.lo.y + v : r.hi.y - v) : (st.firstLow ? r.lo.x + v : r.hi.x - v)
            return st.alongX ? SIMD2(along, across) : SIMD2(across, along)
        }
        let start = point(0.6, w2)
        var w = Walker(feet: SIMD3(start.x, plan.storeys[0].floor + 0.05, start.y))
        settle(&w, grid)
        for s in 0..<(plan.storeys.count - 1) {
            XCTAssertEqual(w.feet.y, plan.storeys[s].floor, accuracy: 0.03, "on storey \(s)'s landing")
            walk(&w, grid, through: [point(0.6, w2), point(length - 0.6, w2), point(length - 0.6, width - w2), point(0.6, width - w2), point(0.6, w2)])
            settle(&w, grid)
            XCTAssertEqual(w.feet.y, plan.storeys[s + 1].floor, accuracy: 0.03, "climbed to storey \(s + 1)")
        }
    }

    /// Into an outer wall from inside, and into a window: it stays in.
    func testWallsAndGlassHold() {
        let (b, grid) = building()
        let f = b.plan.storeys[1]
        // A room on the front with a window: walk at the window, then along the wall into the corner.
        guard let room = f.rooms.filter({ $0.type == .living || $0.type == .bedroom }).max(by: { $0.rect.hi.y < $1.rect.hi.y }) else {
            return XCTFail("no room")
        }
        var w = Walker(feet: SIMD3(room.rect.center.x, f.floor + 0.05, room.rect.center.y))
        settle(&w, grid)
        walk(&w, grid, through: [SIMD2(room.rect.center.x, room.rect.hi.y + 3)], seconds: 6)
        XCTAssertLessThan(w.feet.z, room.rect.hi.y - Walker.radius + 0.02, "through the outer wall")
        XCTAssertEqual(w.feet.y, f.floor, accuracy: 0.02)
    }

    func testJumpsAndCrouches() {
        let ground = Interior.Collider(lo: [-10, -1, -10], hi: [10, 0, 10])
        let low = Interior.Collider(lo: [2, 1.4, -1], hi: [4, 1.6, 1])      // a beam at 1.4 m
        let grid = ColliderGrid([ground, low])
        var w = Walker(feet: [0, 0, 0])
        var remainder: Float = 0
        w.advance(1 / 60, input: Walker.Input(), world: grid, remainder: &remainder)
        XCTAssertTrue(w.grounded)
        var top: Float = 0
        w.advance(1 / 60, input: Walker.Input(jump: true), world: grid, remainder: &remainder)
        for _ in 0..<120 {
            w.advance(1 / 60, input: Walker.Input(), world: grid, remainder: &remainder)
            top = max(top, w.feet.y)
        }
        XCTAssertEqual(top, Walker.jumpSpeed * Walker.jumpSpeed / (2 * Walker.gravity), accuracy: 0.08)
        XCTAssertEqual(w.feet.y, 0, accuracy: 1e-4)
        // Standing, the beam stops it; crouched, it passes under, and stays crouched until it is out from under it.
        for _ in 0..<240 { w.advance(1 / 60, input: Walker.Input(move: [1, 0]), world: grid, remainder: &remainder) }
        XCTAssertLessThan(w.feet.x, 2 - Walker.radius + 0.02)
        for _ in 0..<60 { w.advance(1 / 60, input: Walker.Input(move: [1, 0], crouch: true), world: grid, remainder: &remainder) }
        for _ in 0..<120 { w.advance(1 / 60, input: Walker.Input(move: [1, 0], crouch: true), world: grid, remainder: &remainder) }
        XCTAssertGreaterThan(w.feet.x, 2.5, "under the beam crouched")
        w.advance(1 / 60, input: Walker.Input(), world: grid, remainder: &remainder)
        if w.feet.x < 4 { XCTAssertTrue(w.crouched, "stood up under the beam") }
    }

    /// A door's leaf stops it shut and lets it by open; a lift carries it from floor to floor.
    func testDoorsAndLifts() {
        let ground = Interior.Collider(lo: [-10, -1, -10], hi: [10, 0, 10])
        let grid = ColliderGrid([ground])
        let c = InteriorControls()
        c.autoDoors = false
        c.doors = [InteriorControls.Door(hinge: [-0.5, 0, 1], along: [1, 0], turn: 1, width: 1, height: 2, open: 0, target: 0)]
        var w = Walker(feet: [0, 0, 0])
        var remainder: Float = 0
        for _ in 0..<180 { w.advance(1 / 60, input: Walker.Input(move: [0, 1]), world: grid, moving: c.obstacles, remainder: &remainder) }
        XCTAssertLessThan(w.feet.z, 1 - Walker.radius + 0.06, "through a shut door")
        c.doors[0].target = 1
        for _ in 0..<120 { c.advance(1 / 60, walker: nil) }
        for _ in 0..<180 { w.advance(1 / 60, input: Walker.Input(move: [0, 1]), world: grid, moving: c.obstacles, remainder: &remainder) }
        XCTAssertGreaterThan(w.feet.z, 2, "stopped by an open door")

        var lift = Lift(shaft: CityPlan.Rect(lo: [-1, -1], hi: [1, 1]), floors: [0, 3, 6], doorSide: [0, 1])
        lift.call(2)
        var time: Float = 0
        while lift.at != 2 && time < 30 { _ = lift.advance(1 / 60); time += 1 / 60 }
        XCTAssertEqual(lift.at, 2)
        XCTAssertEqual(lift.y, 6, accuracy: 1e-4)
        XCTAssertLessThan(time, 12)
    }

    /// In a cab at its landing (its floor level with the storey's): on the cab, and carried up with it to the next
    /// floor.
    func testRidesALift() {
        let c = InteriorControls()
        c.lifts = [Lift(shaft: CityPlan.Rect(lo: [-1, -1], hi: [1, 1]), floors: [0, 3], doorSide: [0, 1])]
        let grid = ColliderGrid([Interior.Collider(lo: [-10, -0.25, -10], hi: [10, 0, 10])])
        var w = Walker(feet: [0, 0.05, 0])
        var remainder: Float = 0, last = c.lifts.map(\.y)
        func frame() {
            c.advance(1 / 60, walker: w.feet)
            var moved = zip(c.lifts.map(\.y), last).map { $0 - $1 }
            last = c.lifts.map(\.y)
            w.advance(1 / 60, input: Walker.Input(), world: grid, moving: c.obstacles, carry: { p in
                defer { moved[p] = 0 }
                return SIMD3(0, moved[p], 0)
            }, remainder: &remainder)
        }
        for _ in 0..<30 { frame() }
        XCTAssertEqual(w.standingOn, 0, "on the cab")
        c.lifts[0].call(1)
        for _ in 0..<(60 * 12) { frame() }
        XCTAssertEqual(c.lifts[0].at, 1)
        XCTAssertEqual(w.feet.y, 3, accuracy: 0.02, "carried up")
    }
}
