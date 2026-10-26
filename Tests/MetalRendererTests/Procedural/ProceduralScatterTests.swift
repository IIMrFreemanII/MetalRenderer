import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Scatter, Copy to Points, Attribute Transfer, Ray, Point Jitter, Voronoi Fracture.
final class ProceduralScatterTests: XCTestCase {
    private let cooker = ProcCooker(environment: ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 }))

    /// A network made by `build` (which returns the node to cook).
    private func cook(file: StaticString = #filePath, line: UInt = #line, _ build: (inout ProcGraph) -> String) -> ProcGeo {
        var g = ProcGraph()
        let id = build(&g)
        switch cooker.cook(g, id) {
        case .success(let geo):
            XCTAssertNil(geo.validate(), file: file, line: line)
            return geo
        case .failure(let e):
            XCTFail("cook failed: \(e.message)", file: file, line: line)
            return ProcGeo()
        }
    }

    func testScatterOnASurface() {
        let pts = cook { g in
            let grid = g.add(.grid, params: ["size": .vec2([4, 2]), "rows": .int(3), "cols": .int(5)])
            let col = g.add(.attribcreate, params: ["name": .string("w"), "value": .vec4([2, 0, 0, 0])])
            let s = g.add(.scatter, params: ["npts": .int(500), "seed": .int(3)])
            g.link(grid, to: col); g.link(col, to: s)
            return s
        }
        XCTAssertEqual(pts.pointCount, 500)
        XCTAssertEqual(pts.primCount, 0)
        XCTAssertTrue(pts.P.allSatisfy { abs($0.y) < 1e-5 && abs($0.x) <= 2.0001 && abs($0.z) <= 1.0001 })
        XCTAssertEqual(pts.points.vectors3("N")?.first?.y ?? 0, 1, accuracy: 1e-5)
        XCTAssertTrue(pts.points.floats("w")!.allSatisfy { abs($0 - 2) < 1e-5 })
        XCTAssertNotNil(pts.points.ints("sourceprim"))
        // Even: each half of the grid gets about half.
        let left = pts.P.filter { $0.x < 0 }.count
        XCTAssertEqual(Float(left) / 500, 0.5, accuracy: 0.08)
        // Density: points per unit of area.
        let dense = cook { g in
            let grid = g.add(.grid, params: ["size": .vec2([4, 2])])
            let s = g.add(.scatter, params: ["usedensity": .bool(true), "density": .float(25)])
            g.link(grid, to: s)
            return s
        }
        XCTAssertEqual(dense.pointCount, 200)
        // Relaxing spreads them: the nearest neighbour's distance grows.
        func minSpacing(_ p: [SIMD3<Float>]) -> Float {
            let grid = PointGrid(p)
            return p.indices.map { simd_distance(p[$0], p[Int(grid.nearest(p[$0], except: Int32($0)))]) }.min()!
        }
        let relaxed = cook { g in
            let grid = g.add(.grid, params: ["size": .vec2([4, 2])])
            let s = g.add(.scatter, params: ["npts": .int(500), "seed": .int(3), "relaxiterations": .int(6)])
            g.link(grid, to: s)
            return s
        }
        XCTAssertGreaterThan(minSpacing(relaxed.P), minSpacing(pts.P) * 2)
    }

    func testCopyToPoints() {
        // A box on each of 4 points, sized by pscale, turned by N.
        let copies = cook { g in
            let box = g.add(.box)
            let line = g.add(.line, params: ["points": .int(4), "dir": .vec3([1, 0, 0]), "dist": .float(6)])
            let ps = g.add(.attribcreate, params: ["name": .string("pscale"), "value": .vec4([0.5, 0, 0, 0])])
            let tag = g.add(.attribcreate, params: ["name": .string("tag"), "type": .string("int"), "value": .vec4([9, 0, 0, 0])])
            let cp = g.add(.copytopoints, params: ["copyattrib": .bool(true)])
            g.link(line, to: ps); g.link(ps, to: tag)
            g.link(box, to: cp, 0); g.link(tag, to: cp, 1)
            return cp
        }
        XCTAssertEqual(copies.primCount, 24)
        XCTAssertEqual(copies.pointCount, 32)
        XCTAssertEqual(copies.bounds.hi.x, 6.25, accuracy: 1e-5)
        XCTAssertEqual(copies.bounds.hi.y, 0.25, accuracy: 1e-5)
        XCTAssertTrue(copies.points.ints("tag")!.allSatisfy { $0 == 9 })
        XCTAssertEqual(copies.prims.ints("copynum")?.last, 3)
        // N along +X turns a copy's +Z to +X.
        let turned = cook { g in
            let line = g.add(.line, params: ["origin": .vec3([0, 0, 1])])
            let start = g.add(.blast, params: ["group": .string("0"), "grouptype": .string("points"), "negate": .bool(true)])
            let n = g.add(.attribcreate, params: ["name": .string("N"), "type": .string("vector3"), "value": .vec4([1, 0, 0, 0])])
            let cp = g.add(.copytopoints)
            g.link(line, to: start); g.link(start, to: n)
            g.link(line, to: cp, 0); g.link(n, to: cp, 1)
            return cp
        }
        // The line (0,0,1)→(0,1,1) copied to the point (0,0,1) with N +X: the copy's +Z (its origin's z of 1) points along +X.
        XCTAssertEqual(turned.P[0].x, 1, accuracy: 1e-5)
        XCTAssertEqual(turned.P[0].z, 1, accuracy: 1e-5)
    }

    func testTransferRayJitter() {
        let moved = cook { g in
            let grid = g.add(.grid, params: ["size": .vec2([2, 2]), "rows": .int(5), "cols": .int(5)])
            let up = g.add(.transform, params: ["t": .vec3([0, 3, 0])])
            let sphere = g.add(.sphere)
            let ray = g.add(.ray)
            g.link(grid, to: up); g.link(up, to: ray, 0); g.link(sphere, to: ray, 1)
            return ray
        }
        // The middle point drops onto the sphere's top; corners (outside it, |x|,|z| = 1) miss.
        XCTAssertEqual(moved.P[12].y, 1, accuracy: 0.02)
        XCTAssertEqual(moved.points.ints("hitprim")?[0], 0)
        let nearest = cook { g in
            let p = g.add(.add, params: ["points": .points([[0, 5, 0], [3, 0, 0]])])
            let sphere = g.add(.sphere)
            let ray = g.add(.ray, params: ["method": .string("minimum")])
            g.link(p, to: ray, 0); g.link(sphere, to: ray, 1)
            return ray
        }
        XCTAssertEqual(simd_length(nearest.P[0]), 1, accuracy: 0.03)
        XCTAssertEqual(simd_length(nearest.P[1]), 1, accuracy: 0.03)
        let colored = cook { g in
            let src = g.add(.grid, params: ["size": .vec2([2, 2]), "rows": .int(2), "cols": .int(2)])
            let col = g.add(.color, params: ["color": .vec3([1, 0, 0])])
            let dst = g.add(.sphere)
            let t = g.add(.attribtransfer)
            g.link(src, to: col); g.link(dst, to: t, 0); g.link(col, to: t, 1)
            return t
        }
        XCTAssertTrue(colored.points.vectors3("Cd")!.allSatisfy { $0 == [1, 0, 0] })
        let jittered = cook { g in
            let grid = g.add(.grid)
            let j = g.add(.pointjitter, params: ["amount": .float(0.2)])
            g.link(grid, to: j)
            return j
        }
        XCTAssertTrue(jittered.P.contains { abs($0.y) > 0.01 })
        XCTAssertTrue(jittered.P.allSatisfy { abs($0.y) <= 0.1001 })
    }

    func testVoronoiFracture() {
        let pieces = cook { g in
            let box = g.add(.box, params: ["size": .vec3([2, 2, 2])])
            let pts = g.add(.scatter, params: ["npts": .int(6), "seed": .int(1)])
            let v = g.add(.voronoifracture)
            g.link(box, to: pts)
            g.link(box, to: v, 0); g.link(pts, to: v, 1)
            return v
        }
        XCTAssertEqual(Set(pieces.points.ints("piece")!).count, 6)
        // The pieces fill the box: their volumes add up to its 8.
        var volume: Float = 0
        for p in 0..<pieces.primCount where pieces.isPolygon(p) {
            let r = pieces.vertexRange(p)
            let o = pieces.P[Int(pieces.vertexPoint[r.lowerBound])]
            for k in (r.lowerBound + 1)..<(r.upperBound - 1) {
                volume += simd_dot(o, simd_cross(pieces.P[Int(pieces.vertexPoint[k])], pieces.P[Int(pieces.vertexPoint[k + 1])])) / 6
            }
        }
        XCTAssertEqual(volume, 8, accuracy: 0.05)
        XCTAssertTrue(pieces.prims.group("inside")!.contains(true))
        XCTAssertTrue(pieces.prims.group("inside")!.contains(false))
    }
}
