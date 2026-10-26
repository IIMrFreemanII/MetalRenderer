import XCTest
import simd
@testable import EngineCore
@testable import Modeling
@testable import Procedural

/// The procedural geometry: attribute tables, merging and cutting, group patterns, the point grid, the bridge to the
/// modeller's meshes.
final class ProceduralGeoTests: XCTestCase {
    /// Two quads side by side: points 0-5, prims 0 (left) and 1 (right).
    private func twoQuads() -> ProcGeo {
        ProcGeo(P: [[0, 0, 0], [1, 0, 0], [2, 0, 0], [0, 0, 1], [1, 0, 1], [2, 0, 1]],
                prims: [[0, 3, 4, 1], [1, 4, 5, 2]])
    }

    func testTablesGatherBlendAndAppend() {
        var t = AttributeTable(count: 3)
        t.set("f", .float([1, 2, 3]))
        t.set("s", .string([0, 1, 2], table: ["", "a", "b"]))
        t.setGroup("g", [true, false, true])
        let g = t.gathered([2, 0, -1])
        XCTAssertEqual(g.floats("f"), [3, 1, 0])
        XCTAssertEqual(g["s"]?.string(0), "b")
        XCTAssertEqual(g["s"]?.string(2), "")
        XCTAssertEqual(g.group("g"), [true, true, false])
        // Row 0 = half of 0 and half of 1; row 1 = all of 2.
        let b = t.blended(start: [0, 2, 3], sources: [0, 1, 2], weights: [0.5, 0.5, 1])
        XCTAssertEqual(b.floats("f"), [1.5, 3])
        XCTAssertEqual(b["s"]?.string(1), "b")
        var u = AttributeTable(count: 2)
        u.set("s", .string([1, 1], table: ["", "c"]))
        u.set("v", .vector3([[1, 2, 3], [4, 5, 6]]))
        t.append(u)
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(t.floats("f"), [1, 2, 3, 0, 0])
        XCTAssertEqual((0..<5).map { t["s"]!.string($0) }, ["", "a", "b", "c", "c"])
        XCTAssertEqual(t.vectors3("v")?[0], .zero)
        XCTAssertEqual(t.vectors3("v")?[4], [4, 5, 6])
        XCTAssertEqual(t.group("g"), [true, false, true, false, false])
        t.rename("f", to: "h")
        XCTAssertEqual(t.names.first, "h")
    }

    func testMergeKeepingAndReorder() {
        var a = twoQuads()
        a.points.set("id", .int([0, 1, 2, 3, 4, 5]))
        var b = twoQuads()
        b.prims.set("piece", .int([7, 8]))
        a.merge(b)
        XCTAssertNil(a.validate())
        XCTAssertEqual(a.pointCount, 12)
        XCTAssertEqual(a.primCount, 4)
        XCTAssertEqual(Array(a.primPoints(2)), [6, 9, 10, 7])
        XCTAssertEqual(a.prims.ints("piece"), [0, 0, 7, 8])
        // Keep the right quad of the first copy: points 1, 2, 4, 5 stay, renumbered.
        let k = a.keeping(prims: [false, true, false, false])
        XCTAssertNil(k.validate())
        XCTAssertEqual(k.primCount, 1)
        XCTAssertEqual(k.pointCount, 4)
        XCTAssertEqual(k.points.ints("id"), [1, 2, 4, 5])
        XCTAssertEqual(Array(k.primPoints(0)), [0, 2, 3, 1])
        let r = twoQuads().reorderedPrims([1, 0])
        XCTAssertEqual(Array(r.primPoints(0)), [1, 4, 5, 2])
    }

    func testGroupPatterns() throws {
        var g = twoQuads()
        g.points.setGroup("left", [true, false, false, true, false, false])
        g.points.set("w", .float([0, 0.25, 0.5, 0.75, 1, 1]))
        XCTAssertEqual(try GroupPattern.evaluate("", in: g, .point), [Bool](repeating: true, count: 6))
        XCTAssertEqual(try GroupPattern.evaluate("left", in: g, .point), [true, false, false, true, false, false])
        XCTAssertEqual(try GroupPattern.evaluate("le*", in: g, .point), [true, false, false, true, false, false])
        XCTAssertEqual(try GroupPattern.evaluate("1-4:3", in: g, .point), [false, true, false, false, true, false])
        XCTAssertEqual(try GroupPattern.evaluate("* ^left", in: g, .point), [false, true, true, false, true, true])
        XCTAssertEqual(try GroupPattern.evaluate("@w>=0.5", in: g, .point), [false, false, true, true, true, true])
        XCTAssertEqual(try GroupPattern.evaluate("@P.x==2", in: g, .point), [false, false, true, false, false, true])
        XCTAssertThrowsError(try GroupPattern.evaluate("@nope>1", in: g, .point))
        XCTAssertEqual(GroupPattern.prims(ofPoints: [true, true, false, true, true, false], in: g), [true, false])
    }

    func testPointGrid() {
        var rng = SplitMix64(seed: 3)
        let pts = (0..<2000).map { _ in SIMD3<Float>(rng.range(-5, 5), rng.range(-5, 5), rng.range(-5, 5)) }
        let grid = PointGrid(pts)
        for _ in 0..<50 {
            let q = SIMD3<Float>(rng.range(-8, 8), rng.range(-8, 8), rng.range(-8, 8))
            let brute = pts.indices.min { simd_distance_squared(pts[$0], q) < simd_distance_squared(pts[$1], q) }!
            XCTAssertEqual(simd_distance(pts[Int(grid.nearest(q))], q), simd_distance(pts[brute], q), accuracy: 1e-6)
        }
        var near: [Int32] = []
        grid.within(pts[0], radius: 1, into: &near)
        XCTAssertEqual(Set(near), Set(pts.indices.filter { simd_distance(pts[$0], pts[0]) <= 1 }.map { Int32($0) }))
    }

    func testBridgeRoundTrip() {
        let cube = Primitive.cube.mesh()
        let g = ProcGeo(cube, materials: ["Red"])
        XCTAssertNil(g.validate())
        XCTAssertEqual(g.pointCount, 8)
        XCTAssertEqual(g.primCount, 6)
        XCTAssertNotNil(g.vertices.vectors2("uv"))
        XCTAssertEqual(g.prims["material"]?.string(0), "Red")
        let (m, materials) = g.editMesh()
        XCTAssertNil(m.validate())
        XCTAssertEqual(m.faceCount, 6)
        XCTAssertEqual(m.edgeCount, 12)
        XCTAssertEqual(materials, ["Red"])
        XCTAssertEqual(m.cornerUVs, cube.cornerUVs)
        // Without normals the cube shows smooth faces with every edge sharp (90° is past the 60° cusp).
        XCTAssertTrue(m.edgeFlags.allSatisfy { $0 & EditMesh.Flag.sharp != 0 })
        // A polyline becomes loose edges and comes back as two-point polylines.
        let line = ProcGeo(P: [[0, 0, 0], [1, 0, 0], [2, 0, 0]], prims: [[0, 1, 2]], closed: [false])
        let back = ProcGeo(line.editMesh().mesh)
        XCTAssertEqual(back.primCount, 2)
        XCTAssertFalse(back.primClosed[0])
    }

    func testTransferAttributes() {
        var src = twoQuads()
        src.points.set("w", .float([0, 1, 2, 3, 4, 5]))
        src.prims.set("side", .int([10, 20]))
        var dst = ProcGeo(P: [[0.1, 0, 0.1], [1.9, 0, 0.9], [2, 0, 0]], prims: [[0, 1, 2]])
        dst.transferAttributes(from: src)
        XCTAssertEqual(dst.points.floats("w"), [0, 5, 2])
        XCTAssertEqual(dst.prims.ints("side"), [20])
    }
}
