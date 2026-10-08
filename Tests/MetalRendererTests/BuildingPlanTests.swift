import XCTest
import simd
@testable import MetalRenderer

/// The buildings' floor plans (BuildingPlanner.swift) and the interiors made from them (Building+Interior.swift):
/// every style on lots of several sizes and kinds, over a run of seeds.
final class BuildingPlanTests: XCTestCase {
    private let lots: [(SIMD2<Float>, [CityPlan.Edge])] = [
        (SIMD2(9, 12), [.street, .party, .open, .party]),          // a house in a row
        (SIMD2(10, 11), [.street, .party, .party, .party]),        // ...back to back
        (SIMD2(18, 14), [.street, .street, .party, .party]),       // a corner
        (SIMD2(26, 16), [.street, .party, .open, .party]),
        (SIMD2(22, 13), [.street, .party, .party, .party]),
        (SIMD2(36, 34), [.street, .open, .open, .street]),         // free-standing
        (SIMD2(40, 28), [.street, .street, .street, .street]),
    ]

    /// The lots the city gives each district (CityPlan.subdivide), at their ends and between.
    private func cityLots(_ style: CityStyle) -> [(SIMD2<Float>, [CityPlan.Edge])] {
        switch style {
        case .oldtown: return [(SIMD2(7, 10), [.street, .party, .open, .party]), (SIMD2(11, 13), [.street, .street, .party, .party]),
                               (SIMD2(9, 11.5), [.street, .party, .party, .party])]
        case .residential: return [(SIMD2(14, 12), [.street, .party, .open, .party]), (SIMD2(22, 15), [.street, .street, .party, .party]),
                                   (SIMD2(18, 13), [.street, .party, .party, .party])]
        case .modern: return [(SIMD2(20, 14), [.street, .party, .open, .party]), (SIMD2(32, 17), [.street, .party, .open, .street]),
                              (SIMD2(26, 15), [.street, .party, .party, .party])]
        case .office, .warehouse: return [(SIMD2(34, 30), [.street, .open, .open, .street]), (SIMD2(38, 38), [.street, .street, .street, .street]),
                                          (SIMD2(30, 26), [.street, .open, .open, .open])]
        case .mixed: return []
        }
    }

    /// Every style on its own district's lots (`city`), or on all of `lots`.
    func specs(seeds: Int = 4, interior: Bool = false, city: Bool = false) -> [BuildingSpec] {
        var out: [BuildingSpec] = []
        for style in CityStyle.allCases where style != .mixed {
            for (k, lot) in (city ? cityLots(style) : lots).enumerated() {
                for seed in 0..<seeds {
                    var spec = BuildingSpec(size: lot.0)
                    spec.edges = lot.1
                    spec.style = style
                    spec.floors = style == .office ? 4 + seed * 7 : 1 + (seed * 3 + k) % 7
                    spec.seed = UInt64(seed * 31 + k * 7 + style.rawValue * 1009 + 1)
                    spec.interior = interior
                    out.append(spec)
                }
            }
        }
        return out
    }

    private func name(_ spec: BuildingSpec) -> String { "\(spec.style) \(spec.size) \(spec.floors) floors, seed \(spec.seed)" }

    /// The rooms tile each storey inside its outer walls, nothing overlaps, every room is reached from the stair
    /// (through doors on walls the rooms share), and the stair is in the same place on every storey.
    func testPlansTileAndConnect() {
        var rooms = 0, worst = 0.0
        var drawn: [String: Int] = [:]
        for spec in specs(seeds: 6, city: true) {
            let start = CFAbsoluteTimeGetCurrent()
            let b = BuildingGenerator.generate(spec)
            worst = max(worst, CFAbsoluteTimeGetCurrent() - start)
            let plan = b.plan, n = name(spec)
            XCTAssertEqual(plan.storeys.count, b.tiers.reduce(0) { $0 + $1.heights.count }, n)
            let stair = plan.storeys.first?.stair
            for f in plan.storeys {
                XCTAssertEqual(f.stair, stair, "\(n): the stair moved on storey \(f.storey)")
                let usable = f.usable.reduce(0) { $0 + $1.area }
                let covered = f.rooms.reduce(0) { $0 + $1.area }
                XCTAssertEqual(covered, usable, accuracy: 0.05 * max(1, usable / 100), "\(n) storey \(f.storey): rooms cover \(covered) of \(usable)")
                for (i, a) in f.rooms.enumerated() {
                    XCTAssertEqual(a.id, i)
                    XCTAssertTrue(f.usable.contains { $0.contains(a.rect, tolerance: 1e-2) }, "\(n) storey \(f.storey): \(a.type) is outside")
                    for b in f.rooms[(i + 1)...] {
                        XCTAssertFalse(a.rect.overlaps(b.rect, tolerance: 1e-2), "\(n) storey \(f.storey): \(a.type) overlaps \(b.type)")
                    }
                }
                XCTAssertTrue(f.rooms.contains { $0.type == .stairs }, n)
                // Doors: on a wall their rooms share.
                for d in f.doors where d.b >= 0 {
                    XCTAssertNotNil(SharedEdge.between(f.rooms[d.a].rect, f.rooms[d.b].rect), "\(n): a door between rooms that don't meet")
                }
                // Reached from the stair (or the street: a shop).
                var reached = Set<Int>(), queue = f.rooms.indices.filter { f.rooms[$0].type == .stairs } + f.doors.filter { $0.b < 0 }.map(\.a)
                while let r = queue.popLast() {
                    guard reached.insert(r).inserted else { continue }
                    for d in f.doors where d.touches(r) && d.b >= 0 { queue.append(d.other(r)) }
                }
                for r in f.rooms where !reached.contains(r.id) && r.type != .lift {
                    XCTFail("\(n) storey \(f.storey): \(r.type) \(r.rect.size) isn't reached")
                }
                if f.rooms.contains(where: { !reached.contains($0.id) && $0.type != .lift }) || f.rooms.contains(where: { r in !f.usable.contains { $0.contains(r.rect, tolerance: 1e-2) } }),
                   ProcessInfo.processInfo.environment["PLAN_DRAW"] != nil, drawn[spec.style.name, default: 0] < 2 {
                    drawn[spec.style.name, default: 0] += 1
                    print("UNREACHED \(n) storey \(f.storey):\n" + draw(f, size: spec.size))
                }
                rooms += f.rooms.count
            }
            // The ground floor has a way in.
            XCTAssertFalse(plan.outsideDoors(0).isEmpty, "\(n): no door from the street")
        }
        print(String(format: "Plans: %d rooms; the slowest building (with its plan) %.1f ms", rooms, worst * 1000))
    }

    /// Every flat has a bathroom, and a house (storeys of one home) one on some storey, and a bedroom if it has an
    /// upstairs; no flat is a lone room; an office floor (on the city's office lots) has toilets.
    func testHomesHaveBathrooms() {
        var flats = 0
        let city = specs(seeds: 6, city: true)
        for (k, spec) in (city + specs(seeds: 3)).enumerated() {
            let plan = BuildingGenerator.generate(spec).plan, n = name(spec)
            var house = false, houseBath = false
            for f in plan.storeys {
                let units = Set(f.rooms.map(\.unit).filter { $0 >= 0 })
                if units.count == 1 { houseBath = houseBath || f.rooms.contains { $0.type == .bath || $0.type == .wc } }
                for u in units {
                    let rooms = f.rooms.filter { $0.unit == u }
                    guard rooms.contains(where: { $0.type == .living || $0.type == .bedroom }) else { continue }
                    let bath = rooms.contains { $0.type == .bath || $0.type == .wc }
                    if units.count == 1 {
                        house = true
                    } else {
                        flats += 1
                        XCTAssertTrue(bath, "\(n) storey \(f.storey): a flat of \(rooms.map(\.type)) without a bathroom")
                        XCTAssertGreaterThan(rooms.count, 1, "\(n) storey \(f.storey): a flat of one room")
                    }
                }
            }
            if house { XCTAssertTrue(houseBath, "\(n): a house without a bathroom") }
            if spec.style == .office && k < city.count {   // (the city's office lots: not a tower on a house's plot)
                for f in plan.storeys.dropFirst() where !f.rooms.contains(where: { $0.type == .toilets }) {
                    XCTFail("\(n) storey \(f.storey): an office floor without toilets")
                }
            }
            if house && plan.storeys.count > 1 {
                XCTAssertTrue(plan.storeys.contains { $0.rooms.contains { $0.type == .bedroom } }, "\(n): a house without a bedroom")
            }
        }
        print("Homes: \(flats) flats")
    }

    /// On any lot, of any style (the workshop's sliders reach further than the city goes): the plan covers its
    /// storeys, and every room that can't be reached is a room the generator gave up on, not a crash.
    func testAnyLotMakesAPlan() {
        for spec in specs() {
            let plan = BuildingGenerator.generate(spec).plan, n = name(spec)
            for f in plan.storeys {
                XCTAssertFalse(f.rooms.isEmpty, n)
                let usable = f.usable.reduce(0) { $0 + $1.area }, covered = f.rooms.reduce(0) { $0 + $1.area }
                XCTAssertLessThanOrEqual(covered, usable * 1.02 + 0.5, "\(n) storey \(f.storey): rooms overlap")
            }
        }
    }

    /// The interior's meshes are sound, its storeys shared where they are the same, and it has walls to walk into.
    func testInteriorsAreSound() {
        var triangles = 0, worst = 0.0
        for spec in specs(seeds: 2, interior: true) {
            let start = CFAbsoluteTimeGetCurrent()
            let b = BuildingGenerator.generate(spec)
            worst = max(worst, CFAbsoluteTimeGetCurrent() - start)
            let n = name(spec)
            guard let interior = b.interior else { return XCTFail("\(n): no interior") }
            XCTAssertEqual(interior.placements.count, b.plan.storeys.count, n)
            XCTAssertLessThanOrEqual(interior.storeys.count, interior.placements.count)
            XCTAssertFalse(interior.colliders.isEmpty)
            for storey in interior.storeys {
                for part in storey.parts {
                    let m = part.mesh
                    XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.positions.count }, n)
                    XCTAssertTrue(m.normals.allSatisfy { abs(length($0) - 1) < 1e-3 }, n)
                    for p in m.positions { XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, n) }
                }
            }
            for c in interior.colliders { XCTAssertTrue(all(c.lo .<= c.hi), "\(n): an inside-out collider") }
            triangles += interior.triangles
        }
        print(String(format: "Interiors: %d triangles; the slowest building with its interior %.1f ms", triangles, worst * 1000))
    }

    /// A plan drawn in characters, to look at.
    func testDrawAPlan() {
        for (style, size, edges, floors) in [(CityStyle.residential, SIMD2<Float>(22, 14), [CityPlan.Edge.street, .party, .open, .party], 5),
                                             (.oldtown, SIMD2(9, 12), [.street, .party, .open, .party], 3),
                                             (.office, SIMD2(36, 30), [.street, .open, .open, .street], 8),
                                             (.warehouse, SIMD2(34, 30), [.street, .open, .open, .street], 2),
                                             (.modern, SIMD2(20, 14), [.street, .party, .open, .party], 2)] {
            var spec = BuildingSpec(size: size)
            (spec.style, spec.edges, spec.floors, spec.seed) = (style, edges, floors, style == .modern ? 5201 : 7)
            let plan = BuildingGenerator.generate(spec).plan
            for s in [0, min(1, plan.storeys.count - 1)] {
                print("\(style) storey \(s):")
                print(draw(plan.storeys[s], size: size))
            }
        }
    }

    private func draw(_ f: FloorPlan, size: SIMD2<Float>) -> String {
        let scale: Float = 2.5   // characters per metre across
        let w = Int(size.x * scale) + 1, h = Int(size.y * scale / 2) + 1
        var grid = Array(repeating: Array(repeating: Character(" "), count: w), count: h)
        for r in f.rooms {
            let x0 = Int((r.rect.lo.x + size.x / 2) * scale), x1 = Int((r.rect.hi.x + size.x / 2) * scale)
            let z0 = Int((size.y / 2 - r.rect.hi.y) * scale / 2), z1 = Int((size.y / 2 - r.rect.lo.y) * scale / 2)
            for z in max(0, z0)...min(h - 1, z1) {
                for x in max(0, x0)...min(w - 1, x1) where z == z0 || z == z1 || x == x0 || x == x1 { grid[z][x] = z == z0 || z == z1 ? "-" : "|" }
            }
            let label = String(r.type.rawValue.prefix(max(1, x1 - x0 - 1)))
            let cz = (z0 + z1) / 2
            for (k, c) in label.enumerated() where x0 + 1 + k < w && cz < h && cz >= 0 { grid[cz][x0 + 1 + k] = c }
        }
        for d in f.doors {
            let x = Int((d.at.x + size.x / 2) * scale), z = Int((size.y / 2 - d.at.y) * scale / 2)
            if z >= 0 && z < h && x >= 0 && x < w { grid[z][x] = d.kind == .open ? " " : d.b < 0 ? "E" : "D" }
        }
        return grid.map { String($0) }.joined(separator: "\n")
    }
}
