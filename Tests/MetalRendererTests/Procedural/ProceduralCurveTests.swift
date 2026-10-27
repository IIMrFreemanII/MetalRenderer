import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Curve, Resample, Sweep, Revolve, PolyWire, Carve, Ends, L-System.
final class ProceduralCurveTests: XCTestCase {
    private let cooker = ProcCooker(environment: ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 }))

    private func chain(_ steps: [(ProcNodeKind, [String: ProcParam])], file: StaticString = #filePath, line: UInt = #line) -> ProcGeo {
        var g = ProcGraph()
        var last: String?
        for (kind, params) in steps {
            let id = g.add(kind, params: params)
            if let last { g.link(last, to: id) }
            last = id
        }
        switch cooker.cook(g, last!) {
        case .success(let geo):
            XCTAssertNil(geo.validate(), file: file, line: line)
            return geo
        case .failure(let e):
            XCTFail("cook failed: \(e.message)", file: file, line: line)
            return ProcGeo()
        }
    }

    private func volume(_ g: ProcGeo) -> Float {
        var v: Float = 0
        for p in 0..<g.primCount where g.isPolygon(p) {
            let r = g.vertexRange(p)
            let o = g.P[Int(g.vertexPoint[r.lowerBound])]
            for k in (r.lowerBound + 1)..<(r.upperBound - 1) {
                v += simd_dot(o, simd_cross(g.P[Int(g.vertexPoint[k])], g.P[Int(g.vertexPoint[k + 1])])) / 6
            }
        }
        return v
    }

    func testCurveAndResample() {
        let straight = chain([(.curve, ["points": .points([[0, 0, 0], [2, 0, 0], [2, 0, 2]])])])
        XCTAssertEqual(straight.pointCount, 3)
        XCTAssertFalse(straight.primClosed[0])
        let smooth = chain([(.curve, ["points": .points([[0, 0, 0], [2, 0, 0], [2, 0, 2]]), "type": .string("smooth"), "segs": .int(4)])])
        XCTAssertEqual(smooth.pointCount, 9)
        // A line of length 2 at 0.25 apart: 9 points, the middle one at 1, curveu along.
        let line = chain([(.line, ["dist": .float(2)]), (.resample, ["length": .float(0.25)])])
        XCTAssertEqual(line.pointCount, 9)
        XCTAssertEqual(line.P[4].y, 1, accuracy: 1e-5)
        XCTAssertEqual(line.points.floats("curveu")?[4] ?? 0, 0.5, accuracy: 1e-5)
        let counted = chain([(.circle, ["divs": .int(4)]), (.resample, ["dolength": .bool(false), "segs": .int(12)])])
        XCTAssertEqual(counted.pointCount, 12)
        XCTAssertTrue(counted.primClosed[0])
        // Attributes follow: a value on the line's ends blended between.
        let blended = chain([(.line, ["dist": .float(1)]), (.attribcreate, ["name": .string("w"), "group": .string("1"), "value": .vec4([1, 0, 0, 0])]),
                             (.resample, ["length": .float(0.5)])])
        XCTAssertEqual(blended.points.floats("w")!, [0, 0.5, 1])
    }

    func testSweepAndPolyWire() {
        // A tube of 8 columns along 5 points: 4 × 8 walls and 2 caps, round the Y axis at radius 0.1.
        let tube = chain([(.line, ["points": .int(5), "dist": .float(2)]), (.sweep, ["cols": .int(8)])])
        XCTAssertEqual(tube.primCount, 34)
        XCTAssertEqual(tube.pointCount, 40)
        XCTAssertTrue(tube.P.allSatisfy { abs(simd_length(SIMD2($0.x, $0.z)) - 0.1) < 1e-4 })
        XCTAssertGreaterThan(volume(tube), 0)   // closed, fronts outward
        XCTAssertEqual(tube.vertices.vectors2("uv")?.count, tube.vertexCount)
        // A bent curve: rings stay across it, of the same radius.
        let bent = chain([(.curve, ["points": .points([[0, 0, 0], [1, 0, 0], [1, 1, 0], [1, 1, 1]]), "type": .string("smooth")]),
                          (.sweep, ["radius": .float(0.2), "cols": .int(6)])])
        XCTAssertGreaterThan(volume(bent), 0)
        // Scale ramp to zero at the end: the last ring is a point's worth.
        let cone = chain([(.line, ["points": .int(3)]), (.sweep, ["applyscale": .bool(true), "scaleramp": .ramp([[0, 1], [1, 0]]), "endcaps": .bool(false)])])
        XCTAssertEqual(simd_length(SIMD2(cone.P.last!.x, cone.P.last!.z)), 0, accuracy: 1e-5)
        let ribbon = chain([(.line, ["points": .int(4)]), (.sweep, ["surfaceshape": .string("ribbon")])])
        XCTAssertEqual(ribbon.primCount, 3)
        // PolyWire: a tube round each of a square's four edges' loop.
        let wire = chain([(.grid, ["rows": .int(2), "cols": .int(2)]), (.polywire, ["divs": .int(6)])])
        XCTAssertEqual(wire.primCount, 4 * 6)
    }

    func testRevolveCarveEnds() {
        // A vertical line at x = 1 turned round Y: a tube's wall.
        let wall = chain([(.line, ["origin": .vec3([1, 0, 0]), "points": .int(3)]), (.revolve, ["divs": .int(12)])])
        XCTAssertEqual(wall.primCount, 24)
        XCTAssertEqual(wall.pointCount, 36)
        // A profile touching the axis: one point there, triangles round it.
        let cone = chain([(.add, ["points": .points([[0, 1, 0], [1, 0, 0]]), "connect": .string("open")]), (.revolve, ["divs": .int(8)])])
        XCTAssertEqual(cone.pointCount, 9)
        XCTAssertTrue((0..<cone.primCount).allSatisfy { cone.primSize($0) == 3 })
        let carved = chain([(.line, ["dist": .float(4), "points": .int(5)]), (.carve, ["firstu": .float(0.25), "secondu": .float(0.6)])])
        XCTAssertEqual(carved.P.first!.y, 1, accuracy: 1e-5)
        XCTAssertEqual(carved.P.last!.y, 2.4, accuracy: 1e-5)
        XCTAssertEqual(carved.pointCount, 3)   // the cut at 1, the line's point at 2, the cut at 2.4
        let closed = chain([(.line, ["points": .int(4)]), (.ends, ["closeu": .string("close")])])
        XCTAssertTrue(closed.primClosed[0])
        let unrolled = chain([(.circle, ["divs": .int(5)]), (.ends, ["closeu": .string("unroll")])])
        XCTAssertFalse(unrolled.primClosed[0])
        XCTAssertEqual(unrolled.primSize(0), 6)
    }

    func testLSystem() {
        XCTAssertEqual(String(CurveNodes.rewrite("F", rules: "F=F+F", generations: 2, seed: 0)), "F+F+F+F")
        let plant = chain([(.lsystem, ["generations": .int(3)])])
        XCTAssertGreaterThan(plant.primCount, 10)
        XCTAssertNotNil(plant.points.floats("width"))
        XCTAssertEqual(Set(plant.points.ints("generation")!).count, 4)
        XCTAssertGreaterThan(plant.bounds.hi.y, 1)
        // Branches start where their parent is: every polyline's first point is on another's (but the trunk's).
        let tree = chain([(.lsystem, ["generations": .int(3)]), (.polywire, ["radius": .float(0.02)])])
        XCTAssertGreaterThan(tree.primCount, plant.primCount * 8)
    }
}
