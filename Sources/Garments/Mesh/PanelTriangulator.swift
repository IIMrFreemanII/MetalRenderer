import Foundation
import simd

/// A panel's mesh: its outline's samples (each with where it is on its edge), a triangular lattice inside along the
/// grain, and the internal lines' samples, triangulated (Delaunay). The outline and the lines are kept as edges of
/// the triangulation by keeping every one of their segments Gabriel (no other point in the circle on it): a lattice
/// point too near one is dropped, a segment that two constraint points crowd is split.
package struct PanelMesh {
    /// The points on the sheet.
    package var points: [SIMD2<Float>] = []
    package var triangles: [UInt32] = []
    /// The outline's samples in order (point indices), and where each is: its edge and the fraction of that edge's length.
    package var boundary: [Int] = []
    package var boundaryAt: [(edge: Int, f: Float)] = []
    /// The internal lines' segments (point indices) and the line each is on.
    package var lineSegments: [(a: Int, b: Int, line: Int)] = []
    /// Outline segments the triangulation lost (a sliver of an outline too thin for the spacing): 0 when it is clean.
    package var missingEdges = 0

    package var triangleCount: Int { triangles.count / 3 }
}

package enum PanelTriangulator {
    /// The mesh of `panel`, its outline sampled at `samples` (each edge's fractions, from its start, its end left to
    /// the next edge) and its inside at `spacing`.
    package static func mesh(_ panel: Panel, samples: [[Float]], spacing d: Float) -> PanelMesh {
        var out = PanelMesh()
        let edges = panel.edges
        // The outline's samples.
        var constraintPoint: [Bool] = []
        for (e, fs) in samples.enumerated() {
            for f in fs {
                out.boundary.append(out.points.count)
                out.boundaryAt.append((e, f))
                out.points.append(edges[e].point(at: f))
                constraintPoint.append(true)
            }
        }
        let outline = out.boundary.map { out.points[$0] }
        guard outline.count >= 3 else { return out }
        // The lines' samples, at the spacing (their ends where they are; clipped to the panel).
        var lineChains: [[Int]] = []
        for (l, line) in panel.lines.enumerated() {
            var chain: [Int] = []
            for k in 0..<max(0, line.points.count - 1) {
                let a = line.points[k], b = line.points[k + 1]
                let n = max(1, Int((simd_distance(a, b) / d).rounded(.up)))
                for i in 0...n where !(i == 0 && k > 0) {
                    let q = simd_mix(a, b, SIMD2(repeating: Float(i) / Float(n)))
                    guard Polygon2D.contains(outline, q), nearestDistance(q, outline) > 0.3 * d else { continue }
                    chain.append(out.points.count)
                    out.points.append(q)
                    constraintPoint.append(true)
                }
            }
            lineChains.append(chain)
            _ = l
        }
        // The constraint segments: the outline's, closed, then the lines'.
        var segments: [(Int, Int, line: Int)] = []
        for i in out.boundary.indices { segments.append((out.boundary[i], out.boundary[(i + 1) % out.boundary.count], -1)) }
        for (l, chain) in lineChains.enumerated() where chain.count > 1 {
            for k in 0..<(chain.count - 1) { segments.append((chain[k], chain[k + 1], l)) }
        }
        // The lattice inside, along the grain, kept 0.55 of the spacing from every segment.
        let segGrid = SegmentGrid(cell: d, segments: segments.map { (out.points[$0.0], out.points[$0.1]) })
        let u = SIMD2<Float>(cos(panel.grain), sin(panel.grain)), v = SIMD2<Float>(-u.y, u.x)
        let (lo, hi) = bounds(outline)
        let centre = (lo + hi) / 2, reach = simd_length(hi - lo) / 2 + d
        let rowStep = d * sqrt(3) / 2
        let rows = Int(reach / rowStep) + 1, cols = Int(reach / d) + 1
        for r in -rows...rows {
            let shift = (r & 1) == 0 ? 0 : d / 2
            for c in -cols...cols {
                // (Nudged a hair, by a hash of its place: a lattice's rings of six are on circles, which Delaunay
                // splits either way.)
                let h = UInt32(bitPattern: Int32(truncatingIfNeeded: r &* 73_856_093 ^ c &* 19_349_663)) &* 2_654_435_761
                let jitter = SIMD2(Float(h & 0xFFFF), Float(h >> 16)) / 65535 - 0.5
                let q = centre + u * (Float(c) * d + shift) + v * (Float(r) * rowStep) + jitter * (0.002 * d)
                guard q.x > lo.x, q.y > lo.y, q.x < hi.x, q.y < hi.y, Polygon2D.contains(outline, q) else { continue }
                if segGrid.nearest(q, within: 0.55 * d) { continue }
                out.points.append(q)
                constraintPoint.append(false)
            }
        }
        // Every segment Gabriel: lattice points in its circle go; a segment crowded by constraint points is split.
        var removed = [Bool](repeating: false, count: out.points.count)
        for _ in 0..<6 {
            var grid = PointGrid(cell: d, points: out.points)
            var split: [Int] = []
            for (s, seg) in segments.enumerated() {
                let a = out.points[seg.0], b = out.points[seg.1], m = (a + b) / 2, r = simd_distance(a, b) / 2 * 0.999
                var crowded = false
                grid.visit(m, radius: r) { p in
                    guard p != seg.0, p != seg.1, !removed[p], simd_distance(out.points[p], m) < r else { return }
                    if constraintPoint[p] { crowded = true } else { removed[p] = true }
                }
                if crowded && simd_distance(a, b) > 0.15 * d { split.append(s) }
            }
            guard !split.isEmpty else { break }
            // Split from the back, so the indices before stay.
            for s in split.reversed() {
                let seg = segments[s]
                let p = out.points.count
                if seg.line < 0 {
                    // On the outline: between its two samples, on the edge (the fraction between theirs).
                    guard let k = out.boundary.firstIndex(of: seg.0) else { continue }
                    let at0 = out.boundaryAt[k], at1 = out.boundaryAt[(k + 1) % out.boundaryAt.count]
                    let f1 = at1.edge == at0.edge ? at1.f : 1
                    let f = (at0.f + f1) / 2
                    out.points.append(edges[at0.edge].point(at: f))
                    out.boundary.insert(p, at: k + 1)
                    out.boundaryAt.insert((at0.edge, f), at: k + 1)
                } else {
                    out.points.append((out.points[seg.0] + out.points[seg.1]) / 2)
                }
                constraintPoint.append(true)
                removed.append(false)
                segments[s] = (seg.0, p, seg.line)
                segments.insert((p, seg.1, seg.line), at: s + 1)
            }
            grid = PointGrid(cell: d, points: out.points)
        }
        // Triangulate what is left, keep the triangles inside the outline.
        let kept = out.points.indices.filter { !removed[$0] }
        var remap = [Int](repeating: -1, count: out.points.count)
        for (k, i) in kept.enumerated() { remap[i] = k }
        let pts = kept.map { out.points[$0] }
        let finalOutline = out.boundary.map { out.points[$0] }
        let tris = Delaunay.triangulate(pts)
        var triangles: [UInt32] = []
        triangles.reserveCapacity(tris.count)
        for t in stride(from: 0, to: tris.count, by: 3) {
            let a = pts[Int(tris[t])], b = pts[Int(tris[t + 1])], c = pts[Int(tris[t + 2])]
            guard Polygon2D.contains(finalOutline, (a + b + c) / 3) else { continue }
            triangles += [tris[t], tris[t + 1], tris[t + 2]]
        }
        out.points = pts
        out.triangles = triangles
        out.boundary = out.boundary.map { remap[$0] }
        out.lineSegments = segments.filter { $0.line >= 0 }.map { (remap[$0.0], remap[$0.1], $0.line) }
        // Which outline segments are edges of the mesh.
        var edgeSet = Set<UInt64>()
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let a = UInt64(triangles[t + k]), b = UInt64(triangles[t + (k + 1) % 3])
                edgeSet.insert(min(a, b) << 32 | max(a, b))
            }
        }
        for i in out.boundary.indices {
            let a = UInt64(out.boundary[i]), b = UInt64(out.boundary[(i + 1) % out.boundary.count])
            if !edgeSet.contains(min(a, b) << 32 | max(a, b)) { out.missingEdges += 1 }
        }
        smooth(&out, iterations: 3)
        return out
    }

    /// A few rounds of moving each inner point toward its neighbours' middle (the lattice's rows meet the outline's
    /// samples more evenly).
    private static func smooth(_ m: inout PanelMesh, iterations: Int) {
        var fixed = [Bool](repeating: false, count: m.points.count)
        for b in m.boundary { fixed[b] = true }
        for s in m.lineSegments { fixed[s.a] = true; fixed[s.b] = true }
        var sum = [SIMD2<Float>](repeating: .zero, count: m.points.count), count = [Float](repeating: 0, count: m.points.count)
        for _ in 0..<iterations {
            for i in sum.indices { sum[i] = .zero; count[i] = 0 }
            for t in stride(from: 0, to: m.triangles.count, by: 3) {
                for k in 0..<3 {
                    let a = Int(m.triangles[t + k]), b = Int(m.triangles[t + (k + 1) % 3])
                    sum[a] += m.points[b]; count[a] += 1
                    sum[b] += m.points[a]; count[b] += 1
                }
            }
            for i in m.points.indices where !fixed[i] && count[i] > 0 {
                m.points[i] = simd_mix(m.points[i], sum[i] / count[i], SIMD2(repeating: 0.5))
            }
        }
    }

    private static func bounds(_ p: [SIMD2<Float>]) -> (SIMD2<Float>, SIMD2<Float>) {
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        return (lo, hi)
    }

    private static func nearestDistance(_ q: SIMD2<Float>, _ outline: [SIMD2<Float>]) -> Float {
        var best = Float.infinity
        for i in outline.indices { best = min(best, Polygon2D.segmentDistance(q, outline[i], outline[(i + 1) % outline.count])) }
        return best
    }
}

/// Points binned in square cells, for the points near a place.
struct PointGrid {
    let cell: Float
    var bins: [SIMD2<Int32>: [Int]] = [:]
    let points: [SIMD2<Float>]

    init(cell: Float, points: [SIMD2<Float>]) {
        self.cell = cell
        self.points = points
        for (i, p) in points.enumerated() { bins[key(p), default: []].append(i) }
    }
    func key(_ p: SIMD2<Float>) -> SIMD2<Int32> { SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down))) }

    /// Calls `body` with every point in the cells within `radius` of `q` (a superset of those within it).
    func visit(_ q: SIMD2<Float>, radius: Float, _ body: (Int) -> Void) {
        let lo = key(q - radius), hi = key(q + radius)
        for y in lo.y...hi.y {
            for x in lo.x...hi.x {
                if let b = bins[SIMD2(x, y)] { for i in b { body(i) } }
            }
        }
    }
}

/// Segments binned in square cells (each in every cell its box covers).
struct SegmentGrid {
    let cell: Float
    var bins: [SIMD2<Int32>: [Int]] = [:]
    let segments: [(SIMD2<Float>, SIMD2<Float>)]

    init(cell: Float, segments: [(SIMD2<Float>, SIMD2<Float>)]) {
        self.cell = cell
        self.segments = segments
        for (i, s) in segments.enumerated() {
            let lo = key(simd_min(s.0, s.1)), hi = key(simd_max(s.0, s.1))
            for y in lo.y...hi.y { for x in lo.x...hi.x { bins[SIMD2(x, y), default: []].append(i) } }
        }
    }
    func key(_ p: SIMD2<Float>) -> SIMD2<Int32> { SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down))) }

    /// Whether a segment comes within `r` of `q`.
    func nearest(_ q: SIMD2<Float>, within r: Float) -> Bool {
        let lo = key(q - r), hi = key(q + r)
        for y in lo.y...hi.y {
            for x in lo.x...hi.x {
                guard let b = bins[SIMD2(x, y)] else { continue }
                for i in b where Polygon2D.segmentDistance(q, segments[i].0, segments[i].1) < r { return true }
            }
        }
        return false
    }
}

/// Delaunay triangulation of points in the plane (Bowyer–Watson: each point in turn, the triangles whose circumcircle
/// holds it replaced by a fan from it), counter-clockwise triangles, in double precision.
package enum Delaunay {
    package static func triangulate(_ input: [SIMD2<Float>]) -> [UInt32] {
        let n = input.count
        guard n >= 3 else { return [] }
        var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
        for p in input { let q = SIMD2<Double>(p); lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let size = max(hi.x - lo.x, hi.y - lo.y, 1e-6), mid = (lo + hi) / 2
        // The points, then a triangle far round them all.
        var p = input.map { SIMD2<Double>($0) }
        p.append(mid + SIMD2(-20 * size, -10 * size))
        p.append(mid + SIMD2(20 * size, -10 * size))
        p.append(mid + SIMD2(0, 20 * size))
        var tv: [SIMD3<Int32>] = [SIMD3(Int32(n), Int32(n + 1), Int32(n + 2))]
        var tn: [SIMD3<Int32>] = [SIMD3(-1, -1, -1)]
        var alive: [Bool] = [true]
        var last = 0
        var stamp: [Int] = [0], round = 0
        var bad: [Int] = [], stack: [Int] = []
        var rim: [(a: Int32, b: Int32, outer: Int32, from: Int)] = []

        func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func inCircle(_ t: Int, _ d: SIMD2<Double>) -> Bool {
            let a = p[Int(tv[t].x)] - d, b = p[Int(tv[t].y)] - d, c = p[Int(tv[t].z)] - d
            let det = (a.x * a.x + a.y * a.y) * (b.x * c.y - c.x * b.y) - (b.x * b.x + b.y * b.y) * (a.x * c.y - c.x * a.y)
                + (c.x * c.x + c.y * c.y) * (a.x * b.y - b.x * a.y)
            return det > 0
        }
        func locate(_ q: SIMD2<Double>) -> Int {
            var t = alive[last] ? last : alive.lastIndex(of: true)!
            for _ in 0..<(tv.count + 8) {
                var moved = false
                for k in 0..<3 {
                    let a = p[Int(tv[t][(k + 1) % 3])], b = p[Int(tv[t][(k + 2) % 3])]
                    if orient(a, b, q) < 0, tn[t][k] >= 0 { t = Int(tn[t][k]); moved = true; break }
                }
                if !moved { return t }
            }
            // (A walk that cycles: look at them all.)
            for i in tv.indices where alive[i] {
                let a = p[Int(tv[i].x)], b = p[Int(tv[i].y)], c = p[Int(tv[i].z)]
                if orient(a, b, q) >= 0 && orient(b, c, q) >= 0 && orient(c, a, q) >= 0 { return i }
            }
            return t
        }

        // In the order of a coarse grid's rows, so the walk from the last triangle is short.
        let cell = size / max(1, sqrt(Double(n)))
        let order = (0..<n).sorted {
            let ra = Int((p[$0].y - lo.y) / cell), rb = Int((p[$1].y - lo.y) / cell)
            if ra != rb { return ra < rb }
            return (ra & 1 == 0) ? p[$0].x < p[$1].x : p[$0].x > p[$1].x
        }
        for i in order {
            let q = p[i]
            round += 1
            let start = locate(q)
            bad.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            stamp[start] = round
            while let t = stack.popLast() {
                bad.append(t)
                for k in 0..<3 {
                    let nb = Int(tn[t][k])
                    if nb >= 0, stamp[nb] != round, inCircle(nb, q) {
                        stamp[nb] = round
                        stack.append(nb)
                    }
                }
            }
            // The cavity's rim: edges of bad triangles whose other side isn't bad.
            rim.removeAll(keepingCapacity: true)
            for t in bad {
                for k in 0..<3 {
                    let nb = tn[t][k]
                    if nb < 0 || stamp[Int(nb)] != round {
                        rim.append((tv[t][(k + 1) % 3], tv[t][(k + 2) % 3], nb, t))
                    }
                }
            }
            for t in bad { alive[t] = false }
            let first = tv.count
            for e in rim {
                let t = tv.count
                tv.append(SIMD3(e.a, e.b, Int32(i)))
                tn.append(SIMD3(-1, -1, e.outer))
                alive.append(true)
                stamp.append(0)
                if e.outer >= 0 {
                    let o = Int(e.outer)
                    for k in 0..<3 where Int(tn[o][k]) == e.from { tn[o][k] = Int32(t) }
                }
            }
            // The fan's triangles to each other: [a, b, i] meets the one starting at b across (b, i), the one ending at a
            // across (i, a).
            for t in first..<tv.count {
                let a = tv[t].x, b = tv[t].y
                for u in first..<tv.count where u != t {
                    if tv[u].x == b { tn[t].x = Int32(u) }
                    if tv[u].y == a { tn[t].y = Int32(u) }
                }
            }
            last = tv.count - 1
        }
        var out: [UInt32] = []
        out.reserveCapacity(n * 6)
        for t in tv.indices where alive[t] {
            let v = tv[t]
            if v.x >= Int32(n) || v.y >= Int32(n) || v.z >= Int32(n) { continue }
            out += [UInt32(v.x), UInt32(v.y), UInt32(v.z)]
        }
        return out
    }
}
