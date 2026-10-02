import Foundation
import simd

/// Quadric error metric (Garland & Heckbert): the sum of squared distances to a set of planes, area weighted.
struct Quadric {
    var a2: Float = 0, b2: Float = 0, c2: Float = 0, ab: Float = 0, ac: Float = 0, bc: Float = 0
    var ad: Float = 0, bd: Float = 0, cd: Float = 0, d2: Float = 0
    var weight: Float = 0

    /// Plane through `p` with unit normal `n`, weighted by `w`.
    init(plane n: SIMD3<Float>, through p: SIMD3<Float>, weight w: Float) {
        let d = -dot(n, p)
        a2 = n.x * n.x * w; b2 = n.y * n.y * w; c2 = n.z * n.z * w
        ab = n.x * n.y * w; ac = n.x * n.z * w; bc = n.y * n.z * w
        ad = n.x * d * w; bd = n.y * d * w; cd = n.z * d * w; d2 = d * d * w
        weight = w
    }
    init() {}

    static func += (q: inout Quadric, r: Quadric) {
        q.a2 += r.a2; q.b2 += r.b2; q.c2 += r.c2; q.ab += r.ab; q.ac += r.ac; q.bc += r.bc
        q.ad += r.ad; q.bd += r.bd; q.cd += r.cd; q.d2 += r.d2; q.weight += r.weight
    }

    /// Weighted mean squared distance of `p` to the planes.
    func error(_ p: SIMD3<Float>) -> Float {
        let x = p.x, y = p.y, z = p.z
        let e = a2 * x * x + b2 * y * y + c2 * z * z + 2 * (ab * x * y + ac * x * z + bc * y * z + ad * x + bd * y + cd * z) + d2
        return max(e, 0) / max(weight, 1e-20)
    }
}

/// Simplifies a triangle submesh (one cluster group) by half-edge collapses: a vertex only ever moves onto one of its
/// neighbours, so the result indexes a subset of the input vertices and keeps their exact normals and UVs.
///
/// Vertices are "attribute" vertices (position + normal + UV); `posId` maps each to its welded position, so
/// topology is position-level: UV seams (one position, two attribute vertices) are edges, not holes.
/// * Vertices on the group's border (edges with one triangle in the group) or on non-manifold edges are locked, so
///   neighbouring groups, simplified separately, still meet exactly (Nanite's crack-free DAG rule).
/// * Each attribute copy of the moving vertex must map to exactly one copy of the target across the collapsed edge.
///   That lets seam vertices slide along their seam and stops everything else from crossing a seam, so textures
///   don't smear.
/// * Collapses that flip a triangle or break manifoldness (link condition) are rejected.
/// * Cost = mean squared distance of the target to the planes merged into the moving vertex, plus seam-edge planes
///   that keep seams in place. The returned error is the square root of the largest cost accepted: an object-space
///   distance, the LOD DAG's error metric.
enum MeshSimplifier {
    static let debugStuck = ProcessInfo.processInfo.environment["METALRENDERER_VG_DEBUG"] != nil
    /// `locked(posId)`: positions shared with other groups (the group border), which must not move.
    /// `relaxed`: also move vertices where UV charts meet (more than one seam), mapping each UV copy to the target's
    /// nearest one: textures may stretch a little, so the builder only uses it when the strict pass gets stuck,
    /// which happens in coarse levels of meshes with fragmented UV atlases.
    static func simplify(triangles input: [UInt32], positions: UnsafeBufferPointer<SIMD3<Float>>,
                         posId: UnsafeBufferPointer<Int32>, uvs: UnsafeBufferPointer<SIMD2<Float>>, targetTriangles: Int,
                         relaxed: Bool = false, locked groupBorder: (Int32) -> Bool) -> (triangles: [UInt32], error: Float) {
        // Local attribute vertices and positions.
        var attrOf: [UInt32: Int32] = [:], posOf: [Int32: Int32] = [:]
        var attrGlobal: [UInt32] = [], attrPos: [Int32] = [], P: [SIMD3<Float>] = [], posGlobal: [Int32] = []
        attrOf.reserveCapacity(input.count / 2); posOf.reserveCapacity(input.count / 2)
        var tri = [SIMD3<Int32>]()
        tri.reserveCapacity(input.count / 3)
        for t in stride(from: 0, to: input.count, by: 3) {
            var c = SIMD3<Int32>()
            for k in 0..<3 {
                let g = input[t + k]
                if let a = attrOf[g] { c[k] = a; continue }
                let gp = posId[Int(g)]
                let p: Int32
                if let q = posOf[gp] { p = q } else {
                    p = Int32(P.count); posOf[gp] = p; P.append(positions[Int(g)]); posGlobal.append(gp)
                }
                let a = Int32(attrGlobal.count)
                attrOf[g] = a; attrGlobal.append(g); attrPos.append(p)
                c[k] = a
            }
            tri.append(c)
        }
        let np = P.count
        var alive = [Bool](repeating: true, count: tri.count)
        var liveCount = tri.count
        func pos(_ t: Int, _ k: Int) -> Int32 { attrPos[Int(tri[t][k])] }

        // Incident triangles per position (lazy: dead entries are skipped).
        var posTris = [[Int32]](repeating: [], count: np)
        for t in tri.indices { for k in 0..<3 { posTris[Int(pos(t, k))].append(Int32(t)) } }

        // Position-level edges: triangle count, and whether the attribute vertices differ across them (seam).
        struct EdgeInfo { var count = 0; var a0: Int32 = -1; var b0: Int32 = -1; var seam = false }
        var edges: [UInt64: EdgeInfo] = [:]
        edges.reserveCapacity(tri.count * 2)
        func key(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b))) }
        for t in tri.indices {
            for k in 0..<3 {
                let a = tri[t][k], b = tri[t][(k + 1) % 3]
                let pa = attrPos[Int(a)], pb = attrPos[Int(b)]
                let (lo, hi) = pa < pb ? (a, b) : (b, a)   // attribute vertices at the lower / higher position id
                var e = edges[key(pa, pb)] ?? EdgeInfo()
                if e.count == 0 { e.a0 = lo; e.b0 = hi } else if e.a0 != lo || e.b0 != hi { e.seam = true }
                e.count += 1
                edges[key(pa, pb)] = e
            }
        }

        // Classification. Kinds of movable vertex: interior (one attribute copy, closed fan), seam (two copies, on
        // exactly two seam edges: slides along the seam) and border (one copy, on exactly two open edges of the mesh
        // itself: slides along the border, so loose slivers can collapse away). Everything else stays put.
        var locked = [Bool](repeating: false, count: np)
        var wedges = [[Int32]](repeating: [], count: np)
        for a in attrPos.indices { wedges[Int(attrPos[a])].append(Int32(a)) }
        var seamEdges = [Int](repeating: 0, count: np), borderEdges = [Int](repeating: 0, count: np)
        for p in 0..<np where groupBorder(posGlobal[p]) { locked[p] = true }
        for (k, e) in edges {
            let pa = Int(UInt32(k >> 32)), pb = Int(UInt32(k & 0xFFFF_FFFF))
            if e.count > 2 { locked[pa] = true; locked[pb] = true }   // non-manifold
            else if e.count == 1 { borderEdges[pa] += 1; borderEdges[pb] += 1 }
            else if e.seam { seamEdges[pa] += 1; seamEdges[pb] += 1 }
        }
        for p in 0..<np {
            let w = wedges[p].count, b = borderEdges[p], sm = seamEdges[p]
            let ok = (w == 1 && b == 0) || (w == 1 && b == 2) || (w == 2 && sm == 2 && b == 0) || (relaxed && b == 0)
            if !ok { locked[p] = true }
        }

        // Quadrics: triangle planes, plus planes through seam edges perpendicular to their faces.
        var Q = [Quadric](repeating: Quadric(), count: np)
        for t in tri.indices {
            let p0 = P[Int(pos(t, 0))], p1 = P[Int(pos(t, 1))], p2 = P[Int(pos(t, 2))]
            let c = cross(p1 - p0, p2 - p0)
            let area = length(c)
            guard area > 0 else { continue }
            let n = c / area
            let q = Quadric(plane: n, through: p0, weight: area * 0.5)
            for k in 0..<3 { Q[Int(pos(t, k))] += q }
            for k in 0..<3 {
                let pa = pos(t, k), pb = pos(t, (k + 1) % 3)
                guard let e = edges[key(pa, pb)], (e.seam && e.count == 2) || e.count == 1 else { continue }
                let ea = P[Int(pa)], eb = P[Int(pb)]
                let dir = eb - ea
                let len2 = length_squared(dir)
                guard len2 > 0 else { continue }
                let en = normalize(cross(dir, n))
                let eq = Quadric(plane: en, through: ea, weight: len2 * 4)
                Q[Int(pa)] += eq; Q[Int(pb)] += eq
            }
        }

        var maxCost: Float = 0
        var deadPos = [Bool](repeating: false, count: np)
        var touched = [Int32](repeating: -1, count: np)   // pass number that last touched a position
        var pass: Int32 = 0

        func neighbours(_ u: Int32) -> Set<Int32> {
            var s = Set<Int32>()
            for t in posTris[Int(u)] where alive[Int(t)] {
                for k in 0..<3 { let p = pos(Int(t), k); if p != u { s.insert(p) } }
            }
            return s
        }
        /// The target copy for each attribute copy of `u` across the edge to `v`, or nil if a copy has none or several.
        func wedgeMap(_ u: Int32, _ v: Int32) -> [Int32: Int32]? {
            var map: [Int32: Int32] = [:]
            for t in posTris[Int(u)] where alive[Int(t)] {
                var au: Int32 = -1, av: Int32 = -1
                for k in 0..<3 {
                    let a = tri[Int(t)][k]
                    if attrPos[Int(a)] == u { au = a } else if attrPos[Int(a)] == v { av = a }
                }
                guard av >= 0 else { continue }
                if let m = map[au], m != av {
                    if !relaxed { return nil }
                    continue
                }
                map[au] = av
            }
            for w in wedges[Int(u)] where map[w] == nil {
                // A copy of u with no triangle across the edge: fine only if it's no longer used (strict), or mapped
                // to v's copy with the nearest UV (relaxed).
                let used = posTris[Int(u)].contains(where: { t in alive[Int(t)] && (0..<3).contains { k in tri[Int(t)][k] == w } })
                if !used { continue }
                if !relaxed { return nil }
                let uw = uvs[Int(attrGlobal[Int(w)])]
                map[w] = wedges[Int(v)].min { distance_squared(uvs[Int(attrGlobal[Int($0)])], uw) < distance_squared(uvs[Int(attrGlobal[Int($1)])], uw) }
            }
            return map
        }
        func valid(_ u: Int32, _ v: Int32) -> Bool {
            // Link condition: the common neighbours are exactly the apexes of the triangles on edge uv.
            var apexes = Set<Int32>()
            for t in posTris[Int(u)] where alive[Int(t)] {
                let ps = (0..<3).map { pos(Int(t), $0) }
                if ps.contains(v) { for p in ps where p != u && p != v { apexes.insert(p) } }
            }
            if neighbours(u).intersection(neighbours(v)) != apexes { return false }
            // No flipped or degenerate triangles.
            let pv = P[Int(v)]
            for t in posTris[Int(u)] where alive[Int(t)] {
                let ps = (0..<3).map { pos(Int(t), $0) }
                if ps.contains(v) { continue }
                let p = ps.map { P[Int($0)] }
                let n0 = cross(p[1] - p[0], p[2] - p[0])
                let q = ps.map { $0 == u ? pv : P[Int($0)] }
                let n1 = cross(q[1] - q[0], q[2] - q[0])
                if dot(n0, n1) <= 0.05 * length(n0) * length(n1) || length_squared(n1) == 0 { return false }
            }
            return true
        }

        while liveCount > targetTriangles {
            pass += 1
            // Cheapest collapse per movable position.
            var candidates: [(cost: Float, u: Int32, v: Int32)] = []
            for u in 0..<Int32(np) where !locked[Int(u)] && !deadPos[Int(u)] {
                var best: (Float, Int32) = (.infinity, -1)
                for v in neighbours(u) {
                    if relaxed && borderEdges[Int(u)] == 0 {
                        // any neighbour
                    } else if wedges[Int(u)].count == 2 {   // seam vertices slide along their seam only
                        guard let e = edges[key(u, v)], e.seam else { continue }
                    } else if borderEdges[Int(u)] > 0 {   // border vertices along their border only
                        guard let e = edges[key(u, v)], e.count == 1 else { continue }
                    }
                    let c = Q[Int(u)].error(P[Int(v)])
                    if c < best.0 { best = (c, v) }
                }
                if best.1 >= 0 { candidates.append((best.0, u, best.1)) }
            }
            if candidates.isEmpty { break }
            candidates.sort { $0.cost < $1.cost }
            var collapsed = 0
            for c in candidates {
                if liveCount <= targetTriangles { break }
                let u = c.u, v = c.v
                if touched[Int(u)] == pass || touched[Int(v)] == pass || deadPos[Int(v)] { continue }
                guard let map = wedgeMap(u, v), valid(u, v) else { continue }
                let nbrs = neighbours(u)
                // u's edges become v's: same triangles relabelled, so the same count and seam flag. Edges to the
                // apexes of edge uv merge with v's (each loses the triangle that dies).
                for n in nbrs where n != v {
                    guard let eu = edges.removeValue(forKey: key(u, n)) else { continue }
                    if var ev = edges[key(v, n)] {
                        ev.seam = ev.seam || eu.seam
                        ev.count = 2
                        edges[key(v, n)] = ev
                    } else {
                        edges[key(v, n)] = eu
                    }
                }
                edges.removeValue(forKey: key(u, v))
                for t in posTris[Int(u)] where alive[Int(t)] {
                    let ti = Int(t)
                    if (0..<3).contains(where: { pos(ti, $0) == v }) {
                        alive[ti] = false
                        liveCount -= 1
                        continue
                    }
                    for k in 0..<3 where attrPos[Int(tri[ti][k])] == u { tri[ti][k] = map[tri[ti][k]]! }
                    posTris[Int(v)].append(t)
                }
                posTris[Int(u)] = []
                deadPos[Int(u)] = true
                Q[Int(v)] += Q[Int(u)]
                maxCost = max(maxCost, c.cost)
                touched[Int(u)] = pass; touched[Int(v)] = pass
                for n in nbrs { touched[Int(n)] = pass }
                collapsed += 1
            }
            if collapsed == 0 { break }
        }

        if debugStuck && liveCount * 100 > tri.count * 85 {
            let border = (0..<np).filter { p in locked[p] && wedges[p].count <= 2 && !(wedges[p].count == 2 && seamEdges[p] != 2) }.count
            print("stuck group: \(tri.count) tris -> \(liveCount), \(np) positions: \(locked.filter { $0 }.count) locked (\(border) border/non-manifold, \(wedges.filter { $0.count > 2 }.count) >2 wedges, \((0..<np).filter { wedges[$0].count == 2 && seamEdges[$0] != 2 }.count) seam junctions), \(wedges.filter { $0.count == 2 }.count) seam, passes \(pass)")
        }
        var out: [UInt32] = []
        out.reserveCapacity(liveCount * 3)
        for t in tri.indices where alive[t] {
            for k in 0..<3 { out.append(attrGlobal[Int(tri[t][k])]) }
        }
        return (out, maxCost.squareRoot())
    }
}
