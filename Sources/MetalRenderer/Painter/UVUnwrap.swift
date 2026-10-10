import Foundation
import simd

/// A painted mesh's layout in its texture set: three UVs per triangle (its corners'; a seam is where two triangles
/// sharing a vertex give it different ones), and the island (chart) each triangle is in.
struct UVAtlas: Equatable {
    var corners: [SIMD2<Float>]          // 3 per triangle, in 0...1
    var chartOfTriangle: [Int32]
    var chartCount: Int
    var resolution: Int                  // the texture set's side it was laid out for (its gutters are in its texels)
    /// Texels per metre (object space) at `resolution` (the mesh's own UVs: their mean).
    var texelsPerMetre: Float = 0
    /// The mesh's own UVs (UVCheck said good), not an unwrap.
    var own = false

    /// The share of the square the triangles cover.
    var coverage: Float {
        var sum: Float = 0
        for t in 0..<corners.count / 3 {
            sum += abs(UVCheck.cross2(corners[3 * t + 1] - corners[3 * t], corners[3 * t + 2] - corners[3 * t])) / 2
        }
        return sum
    }
}

/// The painter's own unwrap (no library): the mesh is cut into charts that face about one way (grown from the largest
/// triangles while their normals stay within a cone), each chart is flattened by least-squares conformal maps (LSCM,
/// a Jacobi-preconditioned conjugate gradient from its projection on its plane; the projection itself if that folds,
/// and the chart split in two if the projection folds too), turned to its smallest bounding rectangle (and cut in two
/// where long or mostly empty in it) and packed by its outline (UVPack) into the square with gutters for the
/// painting's dilation and mip levels.
enum UVUnwrap {
    /// Bumped when the unwrap lays a mesh out differently (the cached layouts are made again).
    static let version = 6
    /// How far a chart's triangles may face from its mean normal, and from its first's.
    static let coneAngle: Float = 66 * .pi / 180
    static let seedAngle: Float = 85 * .pi / 180
    /// No chart grows across an edge whose faces meet at more than this (a box's edges: its faces are charts of their own).
    static let creaseAngle: Float = 50 * .pi / 180
    /// The gutter round each chart, in texels of the set (twice it between two charts).
    static func padding(_ resolution: Int) -> Int { max(2, resolution / 512) }

    /// The mesh's layout: its own UVs if they will do (UVCheck), else an unwrap.
    static func atlas(_ mesh: PaintMesh, resolution: Int) -> UVAtlas {
        UVCheck.verdict(mesh) == .good ? own(mesh, resolution: resolution) : unwrap(mesh, resolution: resolution)
    }

    /// The mesh's own UVs as its layout; its charts are its UV islands (triangles joined by edges whose ends have the
    /// same place and the same UV).
    static func own(_ mesh: PaintMesh, resolution: Int) -> UVAtlas {
        var corners = [SIMD2<Float>](repeating: .zero, count: mesh.indices.count)
        for i in mesh.indices.indices { corners[i] = mesh.uvs[Int(mesh.indices[i])] }
        // Vertices with the same place and UV are one; islands are what the triangles' shared edges join.
        var key: [SIMD4<Int32>: Int32] = [:]
        var weld = [Int32](repeating: 0, count: mesh.positions.count)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let step = max(simd_reduce_max(hi - lo), 1e-6) * 1e-6
        for (i, p) in mesh.positions.enumerated() {
            let q = SIMD3<Int32>(((p - lo) / step).rounded(.toNearestOrEven))
            let uv = SIMD2<Int32>((mesh.uvs[i] * 1e5).rounded(.toNearestOrEven))
            let k = SIMD4(q.x, q.y, q.z, uv.x &* 73856093 ^ uv.y &* 19349663)
            if let w = key[k] { weld[i] = w } else { weld[i] = Int32(key.count); key[k] = weld[i] }
        }
        let adj = mesh.adjacency(weld)
        let (chart, count) = components(Array(0..<mesh.triangleCount), adj, mesh.triangleCount)
        // Its scale: texels per metre over the whole (the square root of the UV area in texels over the surface's).
        var uvArea: Float = 0, worldArea: Float = 0
        for t in 0..<mesh.triangleCount {
            uvArea += abs(UVCheck.cross2(corners[3 * t + 1] - corners[3 * t], corners[3 * t + 2] - corners[3 * t])) / 2
            worldArea += mesh.area(t)
        }
        let texelsPerMetre = worldArea > 0 ? (uvArea / worldArea).squareRoot() * Float(resolution) : 0
        return UVAtlas(corners: corners, chartOfTriangle: chart, chartCount: count, resolution: resolution, texelsPerMetre: texelsPerMetre, own: true)
    }

    /// The unwrap.
    static func unwrap(_ mesh: PaintMesh, resolution: Int) -> UVAtlas {
        let n = mesh.triangleCount
        let (weld, weldCount) = mesh.welded()
        let adj = mesh.adjacency(weld)
        var normal = [SIMD3<Float>](repeating: .zero, count: n), area = [Float](repeating: 0, count: n)
        for t in 0..<n {
            let (a, b, c) = mesh.corners(t)
            let cr = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
            let l = simd_length(cr)
            area[t] = l / 2
            if l > 0 { normal[t] = cr / l }
        }
        var charts = merge(grow(n, normal: normal, area: area, adj: adj), normal: normal, area: area, adj: adj)
        // Flatten each; a chart that folds both ways is split, and its halves go round again.
        var flat: [(tris: [Int], uv: [SIMD2<Float>])] = []   // uv: 3 per triangle, in metres
        var scratch = [Int32](repeating: -1, count: weldCount)
        var c = 0
        while c < charts.count {
            let tris = charts[c]
            c += 1
            if let uv = flatten(tris, mesh, weld, normal: normal, area: area, scratch: &scratch) {
                flat.append((tris, uv))
            } else {
                for half in split(tris, normal: normal, adj: adj, n: n) { charts.append(half) }
            }
        }
        // Each chart square to its smallest rectangle, lying down, from 0. One longer than the square root of the whole's
        // area (it would set the scale) or over 1% of it and less than half its rectangle (a ring, an L) is cut in
        // two, its halves keeping their places in it (a part of a layout without folds or overlaps has none), and they
        // go round again.
        let total = area.reduce(0, +), side = total.squareRoot()
        var laid = flat
        flat = []
        var at = [Int32](repeating: 0, count: n)
        var i = 0
        while i < laid.count {
            let (tris, uv) = laid[i]
            laid[i] = ([], [])
            i += 1
            let up = upright(uv)
            var hi = SIMD2<Float>(repeating: 0), chartArea: Float = 0
            for p in up { hi = simd_max(hi, p) }
            for t in tris { chartArea += area[t] }
            let long = hi.x > side, empty = chartArea < 0.5 * hi.x * hi.y && chartArea > 0.01 * total
            guard tris.count >= 16 && (long || empty) else { flat.append((tris, up)); continue }
            for (j, t) in tris.enumerated() { at[t] = Int32(j) }
            for half in split(tris, normal: normal, adj: adj, n: n) {
                laid.append((half, half.flatMap { t in (0..<3).map { uv[3 * Int(at[t]) + $0] } }))
            }
        }
        // Packed by their outlines.
        let packed = UVPack.pack(flat.map(\.uv), resolution: resolution, padding: padding(resolution))
        var corners = [SIMD2<Float>](repeating: .zero, count: 3 * n)
        var chartOf = [Int32](repeating: 0, count: n)
        let r = Float(resolution)
        for (i, chart) in flat.enumerated() {
            let origin = packed.origins[i], turns = packed.turns.indices.contains(i) ? packed.turns[i] : 0
            for (j, t) in chart.tris.enumerated() {
                chartOf[t] = Int32(i)
                for k in 0..<3 { corners[3 * t + k] = (origin + UVPack.turn(chart.uv[3 * j + k], turns) * packed.scale) / r }
            }
        }
        return UVAtlas(corners: corners, chartOfTriangle: chartOf, chartCount: flat.count, resolution: resolution,
                       texelsPerMetre: packed.scale)
    }

    // MARK: - Charts

    /// Charts grown from the largest triangles: each takes the neighbours that face most like it first, while they
    /// stay within the cones. A triangle of no area joins whatever reaches it.
    static func grow(_ n: Int, normal: [SIMD3<Float>], area: [Float], adj: (start: [Int32], next: [Int32])) -> [[Int]] {
        let order = (0..<n).sorted { area[$0] > area[$1] || (area[$0] == area[$1] && $0 < $1) }
        var chartOf = [Int32](repeating: -1, count: n)
        var charts: [[Int]] = []
        let cone = cos(coneAngle), seedCone = cos(seedAngle), crease = cos(creaseAngle)
        var heap = Heap()
        for seed in order where chartOf[seed] < 0 {
            let id = Int32(charts.count)
            var tris = [seed]
            chartOf[seed] = id
            var sum = normal[seed] * max(area[seed], 1e-20)
            let n0 = normal[seed]
            heap.removeAll()
            func push(_ t: Int) {
                for j in Int(adj.start[t])..<Int(adj.start[t + 1]) {
                    let u = Int(adj.next[j])
                    guard chartOf[u] < 0 else { continue }
                    if normal[u] != .zero && normal[t] != .zero && simd_dot(normal[u], normal[t]) < crease { continue }
                    heap.push(1 - simd_dot(normal[u], simd_normalize(sum)), Int32(u))
                }
            }
            push(seed)
            while let (_, u32) = heap.pop() {
                let u = Int(u32)
                guard chartOf[u] < 0 else { continue }
                let nu = normal[u]
                if nu != .zero {
                    guard simd_dot(nu, simd_normalize(sum)) >= cone, simd_dot(nu, n0) >= seedCone || n0 == .zero else { continue }
                }
                chartOf[u] = id
                tris.append(u)
                sum += nu * area[u]
                push(u)
            }
            charts.append(tris)
        }
        return charts
    }

    /// Small charts (under a quarter of the mean's area, or a few triangles under the mean's) into the neighbour they
    /// share the most edges with, smallest first, if the two face within 100 degrees of each other: fewer seams and
    /// gutters (across a crease too: a hard-edged model's bevels and slivers; a box's faces, all alike, stay apart).
    /// (A merged chart that won't flatten is split again.)
    static func merge(_ grown: [[Int]], normal: [SIMD3<Float>], area: [Float], adj: (start: [Int32], next: [Int32])) -> [[Int]] {
        var charts = grown
        var chartOf = [Int32](repeating: 0, count: normal.count)
        var sums = [SIMD3<Float>](repeating: .zero, count: charts.count), areas = [Float](repeating: 0, count: charts.count)
        for (c, tris) in charts.enumerated() {
            for t in tris { chartOf[t] = Int32(c); sums[c] += normal[t] * area[t]; areas[c] += area[t] }
        }
        let mean = areas.reduce(0, +) / Float(max(charts.count, 1))
        let limit = cos(Float(100) * .pi / 180)
        let order = charts.indices.filter { areas[$0] < 0.25 * mean || (charts[$0].count < 8 && areas[$0] < mean) }.sorted { areas[$0] < areas[$1] }
        for c in order where !charts[c].isEmpty {
            var shared: [Int32: Int] = [:]
            for t in charts[c] {
                for j in Int(adj.start[t])..<Int(adj.start[t + 1]) {
                    let u = Int(adj.next[j]), o = chartOf[u]
                    if o != Int32(c) {
                        shared[o, default: 0] += 1
                    }
                }
            }
            let mine = simd_length(sums[c]) > 0 ? simd_normalize(sums[c]) : SIMD3<Float>.zero
            let best = shared.filter { o, _ in
                let theirs = simd_length(sums[Int(o)]) > 0 ? simd_normalize(sums[Int(o)]) : SIMD3<Float>.zero
                return mine == .zero || theirs == .zero || simd_dot(mine, theirs) > limit
            }.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            guard let into = best.map({ Int($0.key) }) else { continue }
            for t in charts[c] { chartOf[t] = Int32(into) }
            charts[into] += charts[c]
            sums[into] += sums[c]
            areas[into] += areas[c]
            charts[c] = []
        }
        return charts.filter { !$0.isEmpty }
    }

    /// A chart's triangles in two connected halves: each triangle goes to the nearer (in steps across edges) of the
    /// two farthest apart. A single triangle is its own chart, and never split.
    static func split(_ tris: [Int], normal: [SIMD3<Float>], adj: (start: [Int32], next: [Int32]), n: Int) -> [[Int]] {
        guard tris.count > 1 else { return [tris] }
        var inChart = [Bool](repeating: false, count: n)
        for t in tris { inChart[t] = true }
        // Steps from `seeds` (multi-source breadth first), and each one's nearest seed.
        func flood(_ seeds: [Int]) -> (steps: [Int32], from: [Int32], last: Int) {
            var steps = [Int32](repeating: -1, count: n), from = [Int32](repeating: -1, count: n)
            var queue = seeds, head = 0, last = seeds[0]
            for (k, s) in seeds.enumerated() { steps[s] = 0; from[s] = Int32(k) }
            while head < queue.count {
                let t = queue[head]; head += 1
                last = t
                for j in Int(adj.start[t])..<Int(adj.start[t + 1]) {
                    let u = Int(adj.next[j])
                    if inChart[u] && steps[u] < 0 { steps[u] = steps[t] + 1; from[u] = from[t]; queue.append(u) }
                }
            }
            return (steps, from, last)
        }
        let a = flood([tris[0]]).last, b = flood([a]).last
        guard a != b else { return [Array(tris[..<(tris.count / 2)]), Array(tris[(tris.count / 2)...])] }
        let (_, from, _) = flood([a, b])
        var halves: [[Int]] = [[], []]
        var orphans: [Int] = []
        for t in tris {
            if from[t] < 0 { orphans.append(t) } else { halves[Int(from[t])].append(t) }
        }
        var out = halves.filter { !$0.isEmpty }
        // Pieces the floods didn't reach (the chart wasn't connected): each its own.
        if !orphans.isEmpty {
            let (chart, count) = components(orphans, adj, n)
            var parts = [[Int]](repeating: [], count: count)
            for t in orphans { parts[Int(chart[t])].append(t) }
            out += parts
        }
        return out
    }

    /// The connected pieces of a set of triangles: each one's piece (over all `n` triangles; -2 outside the set), and how many.
    static func components(_ tris: [Int], _ adj: (start: [Int32], next: [Int32]), _ n: Int) -> ([Int32], Int) {
        var chart = [Int32](repeating: -2, count: n)
        for t in tris { chart[t] = -1 }
        var count = 0
        var stack: [Int] = []
        for t in tris where chart[t] == -1 {
            chart[t] = Int32(count)
            stack.append(t)
            while let u = stack.popLast() {
                for j in Int(adj.start[u])..<Int(adj.start[u + 1]) {
                    let v = Int(adj.next[j])
                    if chart[v] == -1 { chart[v] = Int32(count); stack.append(v) }
                }
            }
            count += 1
        }
        return (chart, count)
    }

    // MARK: - Flattening

    /// A chart's UVs (3 per triangle, in metres: its area as it is), or nil if neither LSCM nor its projection on its
    /// plane lays it out without folding.
    static func flatten(_ tris: [Int], _ mesh: PaintMesh, _ weld: [Int32], normal: [SIMD3<Float>], area: [Float],
                        scratch local: inout [Int32]) -> [SIMD2<Float>]? {
        // Its vertices, numbered from 0 (welded: a seam inside the chart is closed).
        var verts: [Int] = []          // a mesh vertex of each
        var corner = [Int32](repeating: 0, count: 3 * tris.count)
        for (j, t) in tris.enumerated() {
            for k in 0..<3 {
                let v = Int(mesh.indices[3 * t + k]), w = Int(weld[v])
                if local[w] < 0 { local[w] = Int32(verts.count); verts.append(v) }
                corner[3 * j + k] = local[w]
            }
        }
        defer { for v in verts { local[Int(weld[v])] = -1 } }
        // Its plane: the area-weighted mean normal, and a basis on it.
        var sum = SIMD3<Float>.zero
        for t in tris { sum += normal[t] * area[t] }
        let nrm = simd_length(sum) > 1e-20 ? simd_normalize(sum) : (normal[tris[0]] == .zero ? SIMD3(0, 0, 1) : normal[tris[0]])
        let helper: SIMD3<Float> = abs(nrm.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
        let bu = simd_normalize(simd_cross(helper, nrm)), bv = simd_cross(nrm, bu)
        var planar = verts.map { SIMD2<Float>(simd_dot(mesh.positions[$0], bu), simd_dot(mesh.positions[$0], bv)) }
        func perCorner(_ uv: [SIMD2<Float>]) -> [SIMD2<Float>] { corner.map { uv[Int($0)] } }
        // Folded: a triangle turned over (one whose corners the weld made one, of no area, is neither way).
        func folds(_ uv: [SIMD2<Float>]) -> Bool {
            for (j, t) in tris.enumerated() where area[t] > 1e-12 {
                let a = uv[Int(corner[3 * j])], b = uv[Int(corner[3 * j + 1])], c = uv[Int(corner[3 * j + 2])]
                if UVCheck.cross2(b - a, c - a) < -1e-6 * max(simd_length_squared(b - a), simd_length_squared(c - a)) { return true }
            }
            return false
        }
        if tris.count > 2, let conformal = lscm(tris, mesh, corner, count: verts.count, start: planar, verts: verts), !folds(conformal),
           !overlaps(perCorner(conformal), count: tris.count) {
            planar = conformal
        } else if tris.count > 1 && (folds(planar) || overlaps(perCorner(planar), count: tris.count)) {
            return nil
        }
        // Scaled to the chart's area.
        var uvArea: Float = 0, worldArea: Float = 0
        for (j, t) in tris.enumerated() {
            let a = planar[Int(corner[3 * j])], b = planar[Int(corner[3 * j + 1])], c = planar[Int(corner[3 * j + 2])]
            uvArea += UVCheck.cross2(b - a, c - a) / 2
            worldArea += area[t]
        }
        let s = uvArea > 1e-20 ? sqrt(worldArea / uvArea) : 1
        return perCorner(planar.map { $0 * s })
    }

    /// A chart's UVs (3 per triangle) lie over themselves: on a raster of its box (about 8 cells a triangle's side),
    /// more than 1% of the cells inside a triangle are inside another (a surface that turns back over itself, or two
    /// sheets at one place).
    static func overlaps(_ uv: [SIMD2<Float>], count: Int) -> Bool {
        guard count > 1 else { return false }
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for p in uv { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let extent = simd_reduce_max(hi - lo)
        guard extent > 0 else { return false }
        let side = min(max(Int(Double(count).squareRoot() * 8), 16), 512)
        let scale = Float(side) / extent
        var hits = [UInt8](repeating: 0, count: side * side)
        var covered = 0, twice = 0
        for t in 0..<count {
            var p0 = (uv[3 * t] - lo) * scale, p1 = (uv[3 * t + 1] - lo) * scale
            let p2 = (uv[3 * t + 2] - lo) * scale
            if UVCheck.cross2(p1 - p0, p2 - p0) < 0 { swap(&p0, &p1) }
            let a = simd_max(SIMD2<Int>(simd_min(p0, simd_min(p1, p2)).rounded(.down)), .zero)
            let b = simd_min(SIMD2<Int>(simd_max(p0, simd_max(p1, p2)).rounded(.up)), SIMD2(repeating: side - 1))
            guard a.x <= b.x, a.y <= b.y else { continue }
            for y in a.y...b.y {
                for x in a.x...b.x {
                    let q = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    guard UVCheck.cross2(p1 - p0, q - p0) > 0, UVCheck.cross2(p2 - p1, q - p1) > 0, UVCheck.cross2(p0 - p2, q - p2) > 0 else { continue }
                    let i = y * side + x
                    if hits[i] == 0 { covered += 1 } else if hits[i] == 1 { twice += 1 }
                    hits[i] = min(hits[i], 254) + 1
                }
            }
        }
        return twice > max(covered / 100, 0)
    }

    /// LSCM: the UVs whose map from each triangle is as near to a similarity as can be (the Cauchy-Riemann residual,
    /// sum over the corners of the opposite edge x the corner's UV, as complex numbers, per triangle over the square
    /// root of its area), its two farthest vertices pinned where `start` has them. Nil if it doesn't settle.
    static func lscm(_ tris: [Int], _ mesh: PaintMesh, _ corner: [Int32], count n: Int, start: [SIMD2<Float>],
                     verts: [Int]) -> [SIMD2<Float>]? {
        // Each triangle's coefficients: m_k = e_k / sqrt(area), e_k the edge opposite corner k in its own plane.
        var a = [Float](repeating: 0, count: corner.count), b = [Float](repeating: 0, count: corner.count)
        var live = [Bool](repeating: false, count: tris.count)
        for (j, t) in tris.enumerated() {
            let (i0, i1, i2) = mesh.corners(t)
            let p0 = mesh.positions[i0], e1 = mesh.positions[i1] - p0, e2 = mesh.positions[i2] - p0
            let l1 = simd_length(e1)
            let cr = simd_cross(e1, e2)
            let twice = simd_length(cr)
            guard l1 > 0, twice > 1e-14 else { continue }
            let x = e1 / l1, y = simd_cross(simd_normalize(cr), x)
            let z: [SIMD2<Float>] = [.zero, [l1, 0], [simd_dot(e2, x), simd_dot(e2, y)]]
            let w = 1 / sqrt(twice / 2)
            for k in 0..<3 {
                let e = z[(k + 2) % 3] - z[(k + 1) % 3]
                a[3 * j + k] = e.x * w
                b[3 * j + k] = e.y * w
            }
            live[j] = true
        }
        // The pins: the vertex farthest from the first, and the one farthest from that.
        func farthest(from p: SIMD3<Float>) -> Int {
            var best = 0, d: Float = -1
            for (i, v) in verts.enumerated() where simd_distance_squared(mesh.positions[v], p) > d {
                d = simd_distance_squared(mesh.positions[v], p); best = i
            }
            return best
        }
        let pinA = farthest(from: mesh.positions[verts[0]]), pinB = farthest(from: mesh.positions[verts[pinA]])
        guard pinA != pinB else { return nil }
        // x = [u..., v...]; M = A^T A, applied without forming it.
        var x = [Float](repeating: 0, count: 2 * n)
        for i in 0..<n { x[i] = start[i].x; x[n + i] = start[i].y }
        var diag = [Float](repeating: 0, count: 2 * n)
        for j in tris.indices where live[j] {
            for k in 0..<3 {
                let v = Int(corner[3 * j + k]), s = a[3 * j + k] * a[3 * j + k] + b[3 * j + k] * b[3 * j + k]
                diag[v] += s; diag[n + v] += s
            }
        }
        for i in diag.indices where diag[i] <= 0 { diag[i] = 1 }
        let pinned = [pinA, pinB, n + pinA, n + pinB]
        func apply(_ p: [Float], _ out: inout [Float]) {
            for i in out.indices { out[i] = 0 }
            for j in tris.indices where live[j] {
                var re: Float = 0, im: Float = 0
                for k in 0..<3 {
                    let v = Int(corner[3 * j + k]), ak = a[3 * j + k], bk = b[3 * j + k]
                    re += ak * p[v] - bk * p[n + v]
                    im += bk * p[v] + ak * p[n + v]
                }
                for k in 0..<3 {
                    let v = Int(corner[3 * j + k]), ak = a[3 * j + k], bk = b[3 * j + k]
                    out[v] += ak * re + bk * im
                    out[n + v] += -bk * re + ak * im
                }
            }
            for i in pinned { out[i] = 0 }
        }
        var r = [Float](repeating: 0, count: 2 * n)
        apply(x, &r)
        for i in r.indices { r[i] = -r[i] }
        var z = zip(r, diag).map { $0 / $1 }
        var p = z
        var rz = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
        let r0 = sqrt(r.reduce(0) { $0 + $1 * $1 })
        guard r0.isFinite else { return nil }
        var q = [Float](repeating: 0, count: 2 * n)
        let limit = min(4000, 200 + 8 * Int(Double(n).squareRoot()))
        for _ in 0..<limit {
            if sqrt(r.reduce(0) { $0 + $1 * $1 }) <= 1e-5 * max(r0, 1e-20) { break }
            apply(p, &q)
            let pq = zip(p, q).reduce(0) { $0 + $1.0 * $1.1 }
            guard pq > 0 else { break }
            let alpha = rz / pq
            for i in x.indices { x[i] += alpha * p[i]; r[i] -= alpha * q[i] }
            for i in z.indices { z[i] = r[i] / diag[i] }
            let rz2 = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
            let beta = rz2 / max(rz, 1e-30)
            rz = rz2
            for i in p.indices { p[i] = z[i] + beta * p[i] }
        }
        guard x.allSatisfy(\.isFinite) else { return nil }
        return (0..<n).map { SIMD2(x[$0], x[n + $0]) }
    }

    /// A chart's UVs turned to the smallest rectangle round them (over its hull's edges), lying down (wider than
    /// tall), from 0.
    static func upright(_ uv: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let hull = convexHull(uv)
        var best: (area: Float, c: Float, s: Float) = (.infinity, 1, 0)
        let step = max(1, hull.count / 256)
        for i in stride(from: 0, to: hull.count, by: step) {
            let e = hull[(i + 1) % hull.count] - hull[i]
            let l = simd_length(e)
            guard l > 0 else { continue }
            let c = e.x / l, s = e.y / l
            var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
            for p in hull {
                let q = SIMD2(c * p.x + s * p.y, -s * p.x + c * p.y)
                lo = simd_min(lo, q); hi = simd_max(hi, q)
            }
            let area = (hi.x - lo.x) * (hi.y - lo.y)
            if area < best.area { best = (area, c, s) }
        }
        var out = uv.map { SIMD2(best.c * $0.x + best.s * $0.y, -best.s * $0.x + best.c * $0.y) }
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for p in out { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if !lo.x.isFinite { return uv }
        let tall = hi.y - lo.y > hi.x - lo.x
        // A quarter turn the way that keeps the triangles' winding: (x, y) -> (-y, x).
        out = out.map { p in tall ? SIMD2(hi.y - p.y, p.x - lo.x) : p - lo }
        return out
    }

    /// The convex hull, counter-clockwise (Andrew's monotone chain).
    static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard p.count > 2 else { return p }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2 && UVCheck.cross2(lower[lower.count - 1] - lower[lower.count - 2], q - lower[lower.count - 2]) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && UVCheck.cross2(upper[upper.count - 1] - upper[upper.count - 2], q - upper[upper.count - 2]) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A min-heap of (cost, triangle).
    struct Heap {
        private var items: [(Float, Int32)] = []
        mutating func removeAll() { items.removeAll(keepingCapacity: true) }
        mutating func push(_ cost: Float, _ t: Int32) {
            items.append((cost, t))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].0 < items[parent].0 else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }
        mutating func pop() -> (Float, Int32)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count && items[l].0 < items[m].0 { m = l }
                    if r < items.count && items[r].0 < items[m].0 { m = r }
                    if m == i { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }
}
