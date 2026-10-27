import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Cooks at scale, timed (release: `Tools/release.sh test --filter ProceduralPerfTests` with PROC_PERF=1): a 1M-point
/// scatter (and relaxed), 10k copies to points, a wrangle over 1M points, a sweep along a 100k-point curve, the attribute
/// nodes that write row by row or convert, Ray onto a sphere, Voronoi Fracture (PROC_PERF_SIDE: the grids' side, smaller
/// unoptimised). Prints each node's own cook time (the best of three cooks, each by a new cooker: nothing cached) with
/// the whole network's, and a fingerprint of the output (its positions, topology and attributes) that an optimisation
/// must leave as it is.
final class ProceduralPerfTests: XCTestCase {
    private let environment = ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 })

    /// The best of `repeats` cooks of `node`: its own milliseconds, the network's, and its output.
    @discardableResult
    private func time(_ label: String, _ graph: ProcGraph, _ node: String, repeats: Int = 3) throws -> ProcGeo {
        var own = Double.infinity, whole = Double.infinity
        var out = ProcGeo()
        for _ in 0..<repeats {
            let cooker = ProcCooker(environment: environment)
            let start = DispatchTime.now().uptimeNanoseconds
            out = try cooker.cook(graph, node).get()
            whole = min(whole, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            own = min(own, cooker.info[node]?.milliseconds ?? .nan)
        }
        print(String(format: "  %-44@ %9.1f ms  (network %9.1f ms)  %8d points %8d prims  %016llx",
                     label as NSString, own, whole, out.pointCount, out.primCount, fingerprint(out)))
        return out
    }

    /// A hash of everything the geometry holds.
    private func fingerprint(_ g: ProcGeo) -> UInt64 {
        var h = Hasher64()
        func add<T>(_ a: [T]) { a.withUnsafeBytes { h.add($0) } }
        // (A SIMD3's fourth lane is padding, holding whatever was there: its three lanes only.)
        func add(_ a: [SIMD3<Float>]) {
            var f: [Float] = []
            f.reserveCapacity(a.count * 3)
            for v in a { f.append(v.x); f.append(v.y); f.append(v.z) }
            add(f)
        }
        add(g.P); add(g.vertexPoint); add(g.primStart); add(g.primClosed)
        for c in AttributeClass.allCases {
            let t = g.table(c)
            for a in t.attributes.sorted(by: { $0.name < $1.name }) {
                h.add(a.name)
                switch a.values {
                case .float(let v): add(v)
                case .int(let v): add(v)
                case .vector2(let v): add(v)
                case .vector3(let v): add(v)
                case .vector4(let v): add(v)
                case .string(let v, let table): add(v); table.forEach { h.add($0) }
                }
            }
            for name in t.groupNames { h.add(name); add(t.group(name) ?? []) }
        }
        return h.value
    }

    private func perf() throws {
        guard ProcessInfo.processInfo.environment["PROC_PERF"] != nil else { throw XCTSkip("PROC_PERF not set") }
    }

    func testScatter() throws {
        try perf()
        print("Scatter:")
        for relax in [0, 2] {
            var g = ProcGraph()
            let grid = g.add(.grid, params: ["size": .vec2([100, 100]), "rows": .int(100), "cols": .int(100)])
            let s = g.add(.scatter, params: ["npts": .int(1_000_000), "seed": .int(5), "relaxiterations": .int(relax)])
            g.link(grid, to: s)
            let out = try time("scatter 1M points on a grid, relax \(relax)", g, s)
            XCTAssertEqual(out.pointCount, 1_000_000)
        }
    }

    func testCopyToPoints() throws {
        try perf()
        print("Copy to Points:")
        for (shape, params) in [(ProcNodeKind.box, [String: ProcParam]()),
                                (.sphere, ["rows": .int(8), "cols": .int(12), "scale": .float(0.3)])] {
            var g = ProcGraph()
            let grid = g.add(.grid, params: ["size": .vec2([100, 100])])
            let s = g.add(.scatter, params: ["npts": .int(10_000), "seed": .int(2)])
            let ps = g.add(.attribrandomize, params: ["name": .string("pscale"), "dims": .int(1), "min": .vec4([0.2, 0, 0, 0]),
                                                      "max": .vec4([0.6, 0, 0, 0])])
            let src = g.add(shape, params: params)
            let cp = g.add(.copytopoints)
            g.link(grid, to: s); g.link(s, to: ps)
            g.link(src, to: cp, 0); g.link(ps, to: cp, 1)
            let out = try time("10k copies of a \(shape.rawValue)", g, cp)
            XCTAssertEqual(out.primCount % 10_000, 0)
        }
    }

    func testWrangle() throws {
        try perf()
        if let p = WrangleCompiler.shared.problem() { throw XCTSkip(p) }
        print("Attribute Wrangle:")
        var g = ProcGraph()
        let grid = g.add(.grid, params: ["size": .vec2([20, 20]), "rows": .int(1000), "cols": .int(1000)])
        let w = g.add(.attribwrangle, params: ["snippet": .string("""
            @P.y += sin(@P.x * 4) * noise(@P * 0.5) * 0.3
            v@Cd = SIMD3(fit(@P.y, -0.3, 0.3, 0, 1), 0.5, 1)
            f@mass = Float(@ptnum % 7)
            """)])
        g.link(grid, to: w)
        _ = try ProcCooker(environment: environment).cook(g, w).get()   // compiled (or found in the bundle cache) first
        let out = try time("wrangle over 1M points (3 attributes)", g, w)
        XCTAssertTrue(out.points["Cd"] != nil)   // (not XCTAssertNotNil: it prints the million values)
    }

    /// The nodes that write an attribute row by row, or convert one to another type, over 1M points.
    func testAttributeWrites() throws {
        try perf()
        print("Attribute writes:")
        let side = Int(ProcessInfo.processInfo.environment["PROC_PERF_SIDE"] ?? "") ?? 1000   // (smaller for an unoptimised build)
        func grid(_ g: inout ProcGraph) -> String {
            g.add(.grid, params: ["size": .vec2([100, 100]), "rows": .int(side), "cols": .int(side)])
        }
        do {
            var g = ProcGraph()
            let r = g.add(.attribrandomize, params: ["name": .string("mass"), "dims": .int(1)])
            g.link(grid(&g), to: r)
            try time("randomize a float on \(side * side) points", g, r)
            let n = g.add(.attribnoise, params: ["name": .string("mass")])
            g.link(r, to: n)
            try time("noise added to it", g, n)
        }
        do {
            // An int read as a vector: converted, then written row by row.
            var g = ProcGraph()
            let id = g.add(.attribcreate, params: ["name": .string("id"), "type": .string("int"), "value": .vec4([3, 0, 0, 0])])
            let r = g.add(.attribrandomize, params: ["name": .string("id"), "dims": .int(3)])
            g.link(grid(&g), to: id); g.link(id, to: r)
            try time("randomize an int attribute as a vector", g, r)
        }
        do {
            var g = ProcGraph()
            let pr = g.add(.attribpromote, params: ["name": .string("P"), "from": .string("point"), "to": .string("primitive"),
                                                    "method": .string("minimum"), "deleteoriginal": .bool(false)])
            g.link(grid(&g), to: pr)
            try time("promote P to prims, minimum", g, pr)
        }
        do {
            // Colours from 1000 points, most of the grid out of their reach: it keeps its own.
            var g = ProcGraph()
            let cd = g.add(.attribcreate, params: ["name": .string("Cd"), "type": .string("vector3"), "value": .vec4([0.5, 0.5, 0.5, 0])])
            let src = g.add(.grid, params: ["size": .vec2([100, 100])])
            let s = g.add(.scatter, params: ["npts": .int(1000), "seed": .int(3)])
            let sc = g.add(.attribrandomize, params: ["name": .string("Cd")])
            let tr = g.add(.attribtransfer, params: ["attribs": .string("Cd"), "distance": .float(0.5)])
            g.link(grid(&g), to: cd); g.link(src, to: s); g.link(s, to: sc)
            g.link(cd, to: tr, 0); g.link(sc, to: tr, 1)
            try time("transfer Cd, most out of reach", g, tr)
        }
        do {
            // Merged copy by copy: every attribute column (Cd, uv, copynum) grows 5000 times.
            var g = ProcGraph()
            let small = g.add(.grid, params: ["rows": .int(10), "cols": .int(10)])
            let cd = g.add(.attribrandomize, params: ["name": .string("Cd")])
            let cx = g.add(.copyxform, params: ["ncy": .int(5000), "copynum": .bool(true)])
            g.link(small, to: cd); g.link(cd, to: cx)
            try time("copy and transform a grid 5000 times", g, cx)
        }
        do {
            // An expression per point: the expression VM over 1M points.
            var g = ProcGraph()
            let a = g.add(.attribcreate, params: ["name": .string("h")])
            g.nodes[g.index(of: a)!].expressions["valuex"] = "@P.z * 2 + sin($PT)"
            g.link(grid(&g), to: a)
            try time("attribute create by an expression per point", g, a)
        }
        if WrangleCompiler.shared.problem() == nil {
            // The wrangle reads the int as a float: converted.
            var g = ProcGraph()
            let id = g.add(.attribcreate, params: ["name": .string("id"), "type": .string("int"), "value": .vec4([3, 0, 0, 0])])
            let w = g.add(.attribwrangle, params: ["snippet": .string("f@id *= 2")])
            g.link(grid(&g), to: id); g.link(id, to: w)
            _ = try ProcCooker(environment: environment).cook(g, w).get()
            try time("wrangle reads an int as a float", g, w)
        }
    }

    /// Ray (along a direction and to the nearest place) of a grid's points onto a sphere of ~9k triangles.
    func testRay() throws {
        try perf()
        print("Ray:")
        let side = Int(ProcessInfo.processInfo.environment["PROC_PERF_SIDE"] ?? "") ?? 300
        for method in ["project", "minimum"] {
            var g = ProcGraph()
            let grid = g.add(.grid, params: ["size": .vec2([3, 3]), "rows": .int(side), "cols": .int(side)])
            let up = g.add(.transform, params: ["t": .vec3([0, 3, 0])])
            let sphere = g.add(.sphere, params: ["rows": .int(48), "cols": .int(96)])
            let ray = g.add(.ray, params: ["method": .string(method)])
            g.link(grid, to: up); g.link(up, to: ray, 0); g.link(sphere, to: ray, 1)
            try time("ray \(side * side) points onto a sphere, \(method)", g, ray)
        }
    }

    /// Voronoi Fracture of a sphere: cut by exact booleans, and the cells alone.
    func testVoronoi() throws {
        try perf()
        print("Voronoi Fracture:")
        for (cells, cut) in [(100, true), (2000, false)] {
            var g = ProcGraph()
            let sphere = g.add(.sphere, params: ["rows": .int(24), "cols": .int(48)])
            let pts = g.add(.scatter, params: ["npts": .int(cells), "seed": .int(4)])
            let v = g.add(.voronoifracture, params: ["cutinput": .bool(cut)])
            g.link(sphere, to: pts); g.link(sphere, to: v, 0); g.link(pts, to: v, 1)
            try time("fracture a sphere into \(cells) cells\(cut ? ", cut" : "")", g, v)
        }
    }

    func testSweep() throws {
        try perf()
        print("Sweep:")
        // A helix 10 turns round, about 316 long, resampled to ~100k points.
        let helix = (0...80).map { i -> SIMD3<Float> in
            let a = Float(i) / 80 * 20 * .pi
            return SIMD3(cos(a) * 5, Float(i) / 80 * 20, sin(a) * 5)
        }
        var g = ProcGraph()
        let curve = g.add(.curve, params: ["points": .points(helix), "type": .string("smooth"), "segs": .int(16)])
        let rs = g.add(.resample, params: ["length": .float(0.00316)])
        let sw = g.add(.sweep, params: ["cols": .int(16)])
        g.link(curve, to: rs); g.link(rs, to: sw)
        try time("resample a helix to ~100k points", g, rs)
        let out = try time("sweep 16 columns along it", g, sw)
        XCTAssertGreaterThan(out.pointCount, 1_500_000)
    }
}
