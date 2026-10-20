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
        var group = Group(triangles: input, positions: positions, posId: posId, uvs: uvs, relaxed: relaxed, locked: groupBorder)
        group.collapse(to: targetTriangles)
        return group.result()
    }

    /// One group's simplification. Its state is a struct's, and the steps are its mutating methods: Swift checks
    /// their accesses to it when compiling. (As local functions over local arrays, every access paid a runtime
    /// exclusivity check, and each neighbour list, link test and copy map was a new set or dictionary.) The lists a
    /// step needs are kept and reused, and a position's neighbours are told apart by marks instead of a set, so they
    /// come in the order they are met: ties between equal costs fall the same way in every run.
    private struct Group {
        struct EdgeInfo { var count = 0; var a0: Int32 = -1; var b0: Int32 = -1; var seam = false }
        let relaxed: Bool
        let uvs: UnsafeBufferPointer<SIMD2<Float>>
        // Local attribute vertices (their global index, their position) and positions (where, their global id).
        var attrGlobal: [UInt32] = [], attrPos: [Int32] = [], P: [SIMD3<Float>] = [], posGlobal: [Int32] = []
        var tri: [SIMD3<Int32>] = []
        var alive: [Bool]
        var liveCount: Int
        /// Incident triangles per position (lazy: dead entries are skipped).
        var posTris: [[Int32]]
        /// Position-level edges: triangle count, and whether the attribute vertices differ across them (seam).
        var edges: [UInt64: EdgeInfo] = [:]
        var locked: [Bool], wedges: [[Int32]], seamEdges: [Int], borderEdges: [Int]
        var Q: [Quadric]
        var maxCost: Float = 0
        var deadPos: [Bool]
        var touched: [Int32]                // pass number that last touched a position
        var pass: Int32 = 0
        // Reused lists: the pass's candidates, a collapse's neighbours, the link test's apexes, a copy map (u's -> v's).
        var candidates: [(cost: Float, u: Int32, v: Int32)] = []
        var nbrs: [Int32] = [], apexes: [Int32] = [], mapFrom: [Int32] = [], mapTo: [Int32] = []
        // Marks, by position: met as a neighbour of the position marked with that stamp.
        var markU: [UInt32], markV: [UInt32]
        var stamp: UInt32 = 0

        init(triangles input: [UInt32], positions: UnsafeBufferPointer<SIMD3<Float>>, posId: UnsafeBufferPointer<Int32>,
             uvs: UnsafeBufferPointer<SIMD2<Float>>, relaxed: Bool, locked groupBorder: (Int32) -> Bool) {
            self.relaxed = relaxed
            self.uvs = uvs
            var attrOf: [UInt32: Int32] = [:], posOf: [Int32: Int32] = [:]
            attrOf.reserveCapacity(input.count / 2); posOf.reserveCapacity(input.count / 2)
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
            alive = [Bool](repeating: true, count: tri.count)
            liveCount = tri.count
            posTris = [[Int32]](repeating: [], count: np)
            for t in tri.indices { for k in 0..<3 { posTris[Int(attrPos[Int(tri[t][k])])].append(Int32(t)) } }

            edges.reserveCapacity(tri.count * 2)
            for t in tri.indices {
                for k in 0..<3 {
                    let a = tri[t][k], b = tri[t][(k + 1) % 3]
                    let pa = attrPos[Int(a)], pb = attrPos[Int(b)]
                    let (lo, hi) = pa < pb ? (a, b) : (b, a)   // attribute vertices at the lower / higher position id
                    var e = edges[Group.key(pa, pb)] ?? EdgeInfo()
                    if e.count == 0 { e.a0 = lo; e.b0 = hi } else if e.a0 != lo || e.b0 != hi { e.seam = true }
                    e.count += 1
                    edges[Group.key(pa, pb)] = e
                }
            }

            // Classification. Kinds of movable vertex: interior (one attribute copy, closed fan), seam (two copies, on
            // exactly two seam edges: slides along the seam) and border (one copy, on exactly two open edges of the mesh
            // itself: slides along the border, so loose slivers can collapse away). Everything else stays put.
            locked = [Bool](repeating: false, count: np)
            wedges = [[Int32]](repeating: [], count: np)
            for a in attrPos.indices { wedges[Int(attrPos[a])].append(Int32(a)) }
            seamEdges = [Int](repeating: 0, count: np)
            borderEdges = [Int](repeating: 0, count: np)
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
            Q = [Quadric](repeating: Quadric(), count: np)
            for t in tri.indices {
                let c3 = tri[t]
                let ps = SIMD3(attrPos[Int(c3[0])], attrPos[Int(c3[1])], attrPos[Int(c3[2])])
                let p0 = P[Int(ps[0])], p1 = P[Int(ps[1])], p2 = P[Int(ps[2])]
                let c = cross(p1 - p0, p2 - p0)
                let area = length(c)
                guard area > 0 else { continue }
                let n = c / area
                let q = Quadric(plane: n, through: p0, weight: area * 0.5)
                for k in 0..<3 { Q[Int(ps[k])] += q }
                for k in 0..<3 {
                    let pa = ps[k], pb = ps[(k + 1) % 3]
                    guard let e = edges[Group.key(pa, pb)], (e.seam && e.count == 2) || e.count == 1 else { continue }
                    let ea = P[Int(pa)], eb = P[Int(pb)]
                    let dir = eb - ea
                    let len2 = length_squared(dir)
                    guard len2 > 0 else { continue }
                    let en = normalize(cross(dir, n))
                    let eq = Quadric(plane: en, through: ea, weight: len2 * 4)
                    Q[Int(pa)] += eq; Q[Int(pb)] += eq
                }
            }
            deadPos = [Bool](repeating: false, count: np)
            touched = [Int32](repeating: -1, count: np)
            markU = [UInt32](repeating: 0, count: np)
            markV = [UInt32](repeating: 0, count: np)
        }

        static func key(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b))) }
        func pos(_ t: Int, _ k: Int) -> Int32 { attrPos[Int(tri[t][k])] }

        /// Marks u's neighbours (the positions across its live triangles) in `markU` with a new stamp; `list`: also
        /// into `nbrs`, in the order met.
        mutating func markNeighbours(_ u: Int32, list: Bool = false) {
            stamp &+= 1
            if list { nbrs.removeAll(keepingCapacity: true) }
            for t in posTris[Int(u)] where alive[Int(t)] {
                for k in 0..<3 {
                    let p = pos(Int(t), k)
                    if p != u && markU[Int(p)] != stamp {
                        markU[Int(p)] = stamp
                        if list { nbrs.append(p) }
                    }
                }
            }
        }

        /// The target copy for each attribute copy of `u` across the edge to `v` (`mapFrom` -> `mapTo`), or false if a
        /// copy has none or several.
        mutating func wedgeMap(_ u: Int32, _ v: Int32) -> Bool {
            mapFrom.removeAll(keepingCapacity: true)
            mapTo.removeAll(keepingCapacity: true)
            for t in posTris[Int(u)] where alive[Int(t)] {
                var au: Int32 = -1, av: Int32 = -1
                for k in 0..<3 {
                    let a = tri[Int(t)][k]
                    if attrPos[Int(a)] == u { au = a } else if attrPos[Int(a)] == v { av = a }
                }
                guard av >= 0 else { continue }
                if let i = mapFrom.firstIndex(of: au) {
                    if mapTo[i] != av && !relaxed { return false }
                    continue
                }
                mapFrom.append(au); mapTo.append(av)
            }
            for w in wedges[Int(u)] where !mapFrom.contains(w) {
                // A copy of u with no triangle across the edge: fine only if it's no longer used (strict), or mapped
                // to v's copy with the nearest UV (relaxed).
                var used = false
                for t in posTris[Int(u)] where alive[Int(t)] {
                    let c = tri[Int(t)]
                    if c[0] == w || c[1] == w || c[2] == w { used = true; break }
                }
                if !used { continue }
                if !relaxed { return false }
                let uw = uvs[Int(attrGlobal[Int(w)])]
                var nearest: Int32 = -1, best = Float.infinity
                for x in wedges[Int(v)] {
                    let d = distance_squared(uvs[Int(attrGlobal[Int(x)])], uw)
                    if d < best { best = d; nearest = x }
                }
                mapFrom.append(w); mapTo.append(nearest)
            }
            return true
        }

        /// Whether collapsing u onto v keeps the mesh manifold (the link condition) and flips no triangle.
        mutating func valid(_ u: Int32, _ v: Int32) -> Bool {
            // Link condition: the common neighbours are exactly the apexes of the triangles on edge uv.
            apexes.removeAll(keepingCapacity: true)
            for t in posTris[Int(u)] where alive[Int(t)] {
                let ps = SIMD3(pos(Int(t), 0), pos(Int(t), 1), pos(Int(t), 2))
                guard ps[0] == v || ps[1] == v || ps[2] == v else { continue }
                for k in 0..<3 where ps[k] != u && ps[k] != v && !apexes.contains(ps[k]) { apexes.append(ps[k]) }
            }
            markNeighbours(u)
            let uStamp = stamp
            stamp &+= 1
            var common = 0
            for t in posTris[Int(v)] where alive[Int(t)] {
                for k in 0..<3 {
                    let p = pos(Int(t), k)
                    guard p != v, markV[Int(p)] != stamp else { continue }
                    markV[Int(p)] = stamp
                    if markU[Int(p)] == uStamp {
                        if !apexes.contains(p) { return false }
                        common += 1
                    }
                }
            }
            if common != apexes.count { return false }
            // No flipped or degenerate triangles.
            let pv = P[Int(v)]
            for t in posTris[Int(u)] where alive[Int(t)] {
                let ps = SIMD3(pos(Int(t), 0), pos(Int(t), 1), pos(Int(t), 2))
                if ps[0] == v || ps[1] == v || ps[2] == v { continue }
                let p0 = P[Int(ps[0])], p1 = P[Int(ps[1])], p2 = P[Int(ps[2])]
                let n0 = cross(p1 - p0, p2 - p0)
                let q0 = ps[0] == u ? pv : p0, q1 = ps[1] == u ? pv : p1, q2 = ps[2] == u ? pv : p2
                let n1 = cross(q1 - q0, q2 - q0)
                if dot(n0, n1) <= 0.05 * length(n0) * length(n1) || length_squared(n1) == 0 { return false }
            }
            return true
        }

        /// Collapses until `targetTriangles` are left or nothing more can go.
        mutating func collapse(to targetTriangles: Int) {
            let np = P.count
            while liveCount > targetTriangles {
                pass += 1
                // Cheapest collapse per movable position.
                candidates.removeAll(keepingCapacity: true)
                for u in 0..<Int32(np) where !locked[Int(u)] && !deadPos[Int(u)] {
                    var best: (Float, Int32) = (.infinity, -1)
                    stamp &+= 1
                    for t in posTris[Int(u)] where alive[Int(t)] {
                        for k in 0..<3 {
                            let v = pos(Int(t), k)
                            guard v != u, markU[Int(v)] != stamp else { continue }
                            markU[Int(v)] = stamp
                            if relaxed && borderEdges[Int(u)] == 0 {
                                // any neighbour
                            } else if wedges[Int(u)].count == 2 {   // seam vertices slide along their seam only
                                guard let e = edges[Group.key(u, v)], e.seam else { continue }
                            } else if borderEdges[Int(u)] > 0 {   // border vertices along their border only
                                guard let e = edges[Group.key(u, v)], e.count == 1 else { continue }
                            }
                            let c = Q[Int(u)].error(P[Int(v)])
                            if c < best.0 { best = (c, v) }
                        }
                    }
                    if best.1 >= 0 { candidates.append((best.0, u, best.1)) }
                }
                if candidates.isEmpty { break }
                candidates.sort { $0.cost < $1.cost }
                var collapsed = 0
                for i in candidates.indices {
                    if liveCount <= targetTriangles { break }
                    let c = candidates[i], u = c.u, v = c.v
                    if touched[Int(u)] == pass || touched[Int(v)] == pass || deadPos[Int(v)] { continue }
                    guard wedgeMap(u, v), valid(u, v) else { continue }
                    markNeighbours(u, list: true)
                    // u's edges become v's: same triangles relabelled, so the same count and seam flag. Edges to the
                    // apexes of edge uv merge with v's (each loses the triangle that dies).
                    for j in nbrs.indices where nbrs[j] != v {
                        let n = nbrs[j]
                        guard let eu = edges.removeValue(forKey: Group.key(u, n)) else { continue }
                        if var ev = edges[Group.key(v, n)] {
                            ev.seam = ev.seam || eu.seam
                            ev.count = 2
                            edges[Group.key(v, n)] = ev
                        } else {
                            edges[Group.key(v, n)] = eu
                        }
                    }
                    edges.removeValue(forKey: Group.key(u, v))
                    for t in posTris[Int(u)] where alive[Int(t)] {
                        let ti = Int(t)
                        if pos(ti, 0) == v || pos(ti, 1) == v || pos(ti, 2) == v {
                            alive[ti] = false
                            liveCount -= 1
                            continue
                        }
                        for k in 0..<3 where attrPos[Int(tri[ti][k])] == u {
                            tri[ti][k] = mapTo[mapFrom.firstIndex(of: tri[ti][k])!]
                        }
                        posTris[Int(v)].append(t)
                    }
                    posTris[Int(u)] = []
                    deadPos[Int(u)] = true
                    Q[Int(v)] += Q[Int(u)]
                    maxCost = max(maxCost, c.cost)
                    touched[Int(u)] = pass; touched[Int(v)] = pass
                    for j in nbrs.indices { touched[Int(nbrs[j])] = pass }
                    collapsed += 1
                }
                if collapsed == 0 { break }
            }
        }

        func result() -> (triangles: [UInt32], error: Float) {
            let np = P.count
            if MeshSimplifier.debugStuck && liveCount * 100 > tri.count * 85 {
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
}
