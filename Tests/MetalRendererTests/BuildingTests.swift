import XCTest
import simd
@testable import MetalRenderer

/// The building generator (Building*.swift) on the CPU: every style, on lots of several sizes with their sides
/// looking onto different things, over a run of seeds.
final class BuildingTests: XCTestCase {
    /// Lots to build on: (width, depth, what the front, right, back and left look onto).
    private let lots: [(SIMD2<Float>, [CityPlan.Edge])] = [
        (SIMD2(9, 12), [.street, .party, .open, .party]),          // a house in a row
        (SIMD2(18, 14), [.street, .street, .party, .party]),       // a corner
        (SIMD2(26, 16), [.street, .party, .open, .party]),
        (SIMD2(36, 34), [.street, .open, .open, .street]),         // free-standing
        (SIMD2(40, 28), [.street, .street, .street, .street]),
    ]

    private func specs(night: Bool = false) -> [BuildingSpec] {
        var out: [BuildingSpec] = []
        for style in CityStyle.allCases where style != .mixed {
            for (k, lot) in lots.enumerated() {
                for seed in 0..<6 {
                    var spec = BuildingSpec(size: lot.0)
                    spec.edges = lot.1
                    spec.style = style
                    spec.floors = style == .office ? 6 + seed * 6 : 1 + (seed + k) % 7
                    spec.seed = UInt64(seed * 31 + k * 7 + style.rawValue * 1009 + 1)
                    spec.night = night
                    spec.rooms = 0.3
                    spec.lit = 0.5
                    out.append(spec)
                }
            }
        }
        return out
    }

    func testEveryStylesMeshesAreValid() {
        for spec in specs() {
            let building = BuildingGenerator.generate(spec)
            let name = "\(spec.style) \(spec.size) \(spec.floors) floors, seed \(spec.seed)"
            XCTAssertGreaterThan(building.height, 2, name)
            XCTAssertGreaterThan(building.windows, 0, name)
            XCTAssertLessThanOrEqual(building.triangleCount, BuildingGenerator.triangleLimit, name)
            XCTAssertFalse(building.parts.contains { $0.slot == .lit || $0.slot == .lamp }, "\(name): a light by day")
            let half = spec.size / 2 + SIMD2<Float>(1.6, 1.6)   // balconies, awnings, cornices and eaves reach over the lot's edge
            for part in building.parts {
                let m = part.mesh
                XCTAssertEqual(m.positions.count, m.normals.count)
                XCTAssertEqual(m.positions.count, m.uvs.count)
                XCTAssertEqual(m.indices.count % 3, 0)
                XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.positions.count }, name)
                XCTAssertTrue(m.normals.allSatisfy { abs(length($0) - 1) < 1e-3 }, "\(name) \(part.slot): a normal isn't unit")
                for p in m.positions {
                    XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, name)
                    XCTAssertTrue(abs(p.x) <= half.x && abs(p.z) <= half.y && p.y >= -0.4 && p.y <= building.height + 25,
                                  "\(name) \(part.slot): \(p) is outside the lot")
                }
                for t in stride(from: 0, to: m.indices.count, by: 3) {
                    let (a, b, c) = (Int(m.indices[t]), Int(m.indices[t + 1]), Int(m.indices[t + 2]))
                    let area = length(cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a]))
                    XCTAssertGreaterThan(area, 1e-7, "\(name) \(part.slot): a triangle has no area")
                    // Textured parts need texture coordinates that span the triangle (a normal map's tangents).
                    if part.material.surface != nil {
                        let d1 = m.uvs[b] - m.uvs[a], d2 = m.uvs[c] - m.uvs[a]
                        XCTAssertGreaterThan(abs(d1.x * d2.y - d1.y * d2.x), 1e-9, "\(name) \(part.slot): a triangle has no UV area")
                    }
                }
            }
            XCTAssertTrue(building.parts.contains { $0.slot == .glass && $0.material.glass }, "\(name): no glass")
        }
    }

    func testABuildingIsItsSpecs() {
        for spec in specs().prefix(40) {
            let a = BuildingGenerator.generate(spec), b = BuildingGenerator.generate(spec)
            XCTAssertEqual(a.parts.map(\.mesh.positions), b.parts.map(\.mesh.positions))
            var other = spec
            other.seed += 1
            XCTAssertNotEqual(a.parts.map(\.mesh.positions), BuildingGenerator.generate(other).parts.map(\.mesh.positions))
        }
    }

    func testNightLightsWindowsInAtMostTwoParts() {
        var lit = 0
        for spec in specs(night: true) {
            let building = BuildingGenerator.generate(spec)
            let glowing = building.parts.filter { $0.material.emission != .zero }
            XCTAssertLessThanOrEqual(glowing.count, 2)
            XCTAssertTrue(glowing.allSatisfy { $0.slot == .lit || $0.slot == .lamp })
            XCTAssertLessThanOrEqual(building.lights, building.windows)
            lit += building.lights
        }
        XCTAssertGreaterThan(lit, 1000)
    }

    func testABigTowerStaysUnderTheTriangleLimit() {
        var spec = BuildingSpec(size: SIMD2(44, 44))
        spec.edges = [.street, .street, .street, .street]
        spec.style = .office
        spec.floors = 60
        for seed in 1...8 {
            spec.seed = UInt64(seed)
            let building = BuildingGenerator.generate(spec)
            XCTAssertLessThanOrEqual(building.triangleCount, BuildingGenerator.triangleLimit, "seed \(seed)")
            XCTAssertGreaterThan(building.height, 150)
        }
    }

    // MARK: - Plans

    private let shapes: [Footprint.Shape] = [.rect, .l(bar: 8, wing: 7, right: false), .l(bar: 8, wing: 7, right: true),
                                              .u(bar: 9, wing: 7), .t(bar: 8, wing: 8), .courtyard(ring: 7)]

    func testFootprintOutlinesCloseAroundTheirCover() {
        let rect = CityPlan.Rect(lo: SIMD2(-15, -12), hi: SIMD2(15, 12))
        for shape in shapes {
            let plan = Footprint(rect, shape)
            // The outlines' area (the court's counts against it) is the cover's.
            var outlined: Float = 0
            for loop in plan.loops {
                var twice: Float = 0
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    XCTAssertTrue(a.x == b.x || a.y == b.y, "\(shape): an edge isn't along x or z")
                    XCTAssertGreaterThan(distance(a, b), 0.5)
                    twice += a.x * b.y - b.x * a.y
                }
                outlined -= twice / 2   // the outer outline runs clockwise in (x, z): its walls face out
            }
            XCTAssertEqual(outlined, plan.area, accuracy: 1e-2, "\(shape)")
            for (i, a) in plan.cover.enumerated() {
                XCTAssertTrue(rect.contains(a))
                for b in plan.cover[(i + 1)...] { XCTAssertFalse(a.overlaps(b), "\(shape): the cover overlaps itself") }
            }
            // Every wall faces away from the building, and the building is right behind it.
            for loop in plan.loops {
                let normals = Footprint.normals(loop)
                for i in loop.indices {
                    let mid = (loop[i] + loop[(i + 1) % loop.count]) / 2
                    XCTAssertTrue(plan.contains(mid - normals[i] * 0.1), "\(shape): nothing behind wall \(i)")
                    XCTAssertFalse(plan.contains(mid + normals[i] * 0.1), "\(shape): wall \(i) faces into the building")
                    XCTAssertGreaterThan(plan.depth(behind: loop[i], loop[(i + 1) % loop.count]), 3)
                }
            }
        }
    }

    func testSteppingInStaysInside() {
        let rect = CityPlan.Rect(lo: SIMD2(-15, -12), hi: SIMD2(15, 12))
        for shape in shapes {
            let plan = Footprint(rect, shape)
            guard let inner = plan.inset(front: 2, right: 1, back: 0, left: 1.5, inner: 1) else { return XCTFail("\(shape) can't step in") }
            XCTAssertLessThan(inner.area, plan.area)
            for loop in inner.loops {
                for corner in loop { XCTAssertTrue(plan.contains(corner, margin: 1e-3), "\(shape): a corner left the plan") }
            }
            XCTAssertNil(plan.inset(front: 22), "\(shape): nothing is left to stand on")
        }
        XCTAssertEqual(Footprint.offset([SIMD2(0, 0), SIMD2(0, 2), SIMD2(2, 2), SIMD2(2, 0)], by: 0.5),
                       [SIMD2(-0.5, -0.5), SIMD2(-0.5, 2.5), SIMD2(2.5, 2.5), SIMD2(2.5, -0.5)])
    }

    func testMeshBuilderFacesOutwards() {
        var m = MeshBuilder(uvScale: 0.5)
        m.box([-1, 0, -2], [1, 3, 2])
        XCTAssertEqual(m.triangleCount, 12)
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let p = (0..<3).map { m.positions[Int(m.indices[t + $0])] }
            let centre = (p[0] + p[1] + p[2]) / 3 - SIMD3<Float>(0, 1.5, 0)
            XCTAssertGreaterThan(dot(m.normals[Int(m.indices[t])], centre), 0)
            XCTAssertGreaterThan(dot(cross(p[1] - p[0], p[2] - p[0]), centre), 0, "the winding agrees with the normal")
        }
        var walls = MeshBuilder()
        walls.prism([SIMD2(0, 0), SIMD2(0, 2), SIMD2(2, 2), SIMD2(2, 0)], y0: 0, y1: 1)
        for i in walls.positions.indices {
            XCTAssertGreaterThan(dot(walls.normals[i], walls.positions[i] - SIMD3<Float>(1, walls.positions[i].y, 1)), 0)
        }
    }
}
