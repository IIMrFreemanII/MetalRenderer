import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Cooks at scale, timed (release: `Tools/release.sh test --filter ProceduralPerfTests` with PROC_PERF=1): a 1M-point
/// scatter (and relaxed), 10k copies to points, a wrangle over 1M points, a sweep along a 100k-point curve. Prints each
/// node's own cook time (the best of three cooks, each by a new cooker: nothing cached) with the whole network's, and a
/// fingerprint of the output (its positions, topology and attributes) that an optimisation must leave as it is.
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
