import EngineCore
import Foundation
import Modeling
import Physics
import simd

/// Scatter, Copy to Points, Attribute Transfer, Ray, Point Jitter, Voronoi Fracture.
package enum ScatterNodes {
    /// The polygons as triangles, each with the primitive it came from (`sourceprim`) and its vertices' rows.
    struct Triangles {
        var a: [SIMD3<Float>] = [], b: [SIMD3<Float>] = [], c: [SIMD3<Float>] = []
        /// Each triangle's corners as the source's vertex rows, and its primitive.
        var vertices: [SIMD3<Int32>] = []
        var prim: [Int32] = []
        var area: [Float] = []
        var count: Int { prim.count }
    }

    static func triangles(_ g: ProcGeo) -> Triangles {
        var m = EditMesh()
        m.positions = g.P
        m.faceStart = g.primStart
        m.cornerVerts = g.vertexPoint
        var t = Triangles()
        var tri: [Int32] = []
        for p in 0..<g.primCount where g.isPolygon(p) {
            tri.removeAll(keepingCapacity: true)
            m.triangulate(p, into: &tri)
            for k in stride(from: 0, to: tri.count - 2, by: 3) {
                let v = SIMD3(tri[k], tri[k + 1], tri[k + 2])
                let pa = g.P[Int(g.vertexPoint[Int(v.x)])], pb = g.P[Int(g.vertexPoint[Int(v.y)])], pc = g.P[Int(g.vertexPoint[Int(v.z)])]
                t.a.append(pa); t.b.append(pb); t.c.append(pc)
                t.vertices.append(v)
                t.prim.append(Int32(p))
                t.area.append(simd_length(simd_cross(pb - pa, pc - pa)) / 2)
            }
        }
        return t
    }

    // MARK: Scatter

    static func scatter(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let tris = triangles(g)
        guard tris.count > 0 else { throw ProcCookError("The input has no polygons to scatter on") }
        // Each triangle's share: its area, times a density attribute if asked (primitive, or its points' mean).
        var weight = tris.area
        let densityName = c.string("densityattr")
        if !densityName.isEmpty {
            if let d = g.prims.floats(densityName) {
                for t in 0..<tris.count { weight[t] *= max(0, d[Int(tris.prim[t])]) }
            } else if let d = g.points.floats(densityName) {
                for t in 0..<tris.count {
                    let v = tris.vertices[t]
                    let m = (d[Int(g.vertexPoint[Int(v.x)])] + d[Int(g.vertexPoint[Int(v.y)])] + d[Int(g.vertexPoint[Int(v.z)])]) / 3
                    weight[t] *= max(0, m)
                }
            } else {
                throw ProcCookError("No float attribute \"\(densityName)\" on points or primitives")
            }
        }
        var cdf = [Float](repeating: 0, count: tris.count)
        var total: Float = 0
        for t in 0..<tris.count { total += weight[t]; cdf[t] = total }
        guard total > 0 else { throw ProcCookError("The surface has no area (or no density) to scatter on") }
        let count: Int
        if c.bool("usedensity") {
            count = min(10_000_000, Int((total * c.float("density")).rounded()))
        } else {
            count = max(0, c.int("npts"))
        }
        let seed = c.int("seed")
        // Points: a triangle by area (binary search of the running sum), a place in it by two random numbers.
        var P = [SIMD3<Float>](repeating: .zero, count: count)
        var tri = [Int32](repeating: 0, count: count)
        var bary = [SIMD3<Float>](repeating: .zero, count: count)
        P.withUnsafeMutableBufferPointer { P in
            tri.withUnsafeMutableBufferPointer { tri in
                bary.withUnsafeMutableBufferPointer { bary in
                    cdf.withUnsafeBufferPointer { cdf in
                        parallelChunks(count) { range in
                            for i in range {
                                let r = ProcNoise.random(i, seed: seed, 0) * total
                                var lo = 0, hi = cdf.count - 1
                                while lo < hi {
                                    let mid = (lo + hi) / 2
                                    if cdf[mid] < r { lo = mid + 1 } else { hi = mid }
                                }
                                var u = ProcNoise.random(i, seed: seed, 1), v = ProcNoise.random(i, seed: seed, 2)
                                if u + v > 1 { u = 1 - u; v = 1 - v }
                                let w = SIMD3(1 - u - v, u, v)
                                tri[i] = Int32(lo)
                                bary[i] = w
                                P[i] = tris.a[lo] * w.x + tris.b[lo] * w.y + tris.c[lo] * w.z
                            }
                        }
                    }
                }
            }
        }
        var normals = tri.map { t -> SIMD3<Float> in
            let n = simd_cross(tris.b[Int(t)] - tris.a[Int(t)], tris.c[Int(t)] - tris.a[Int(t)])
            return simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
        }
        // Relaxing: each point pushed away from those nearer than the spacing, in its triangle's plane. Each pass reads
        // the last one's places only, so its points move on every core.
        let iterations = max(0, c.int("relaxiterations"))
        if iterations > 0 && count > 1 {
            let spacing = sqrt(total / Float(count)) * 1.1
            var moved = P
            for _ in 0..<iterations {
                let grid = PointGrid(P, cell: spacing)
                P.withUnsafeBufferPointer { P in
                    moved.withUnsafeMutableBufferPointer { moved in
                        normals.withUnsafeBufferPointer { normals in
                            parallelChunks(count, grain: 2048) { range in
                                for i in range {
                                    let p = P[i]
                                    var push = SIMD3<Float>.zero
                                    grid.forEach(within: spacing, of: p) { j in
                                        guard Int(j) != i else { return }
                                        let d = p - P[Int(j)]
                                        let l = simd_length(d)
                                        if l > 1e-9 { push += d / l * (spacing - l) * 0.5 }
                                    }
                                    let n = normals[i]
                                    push -= n * simd_dot(push, n)
                                    moved[i] = p + push * 0.5
                                }
                            }
                        }
                    }
                }
                swap(&P, &moved)
            }
            // Back onto the surface: each point onto the plane of the triangle it started in.
            for i in 0..<count {
                let t = Int(tri[i]), n = normals[i]
                P[i] -= n * simd_dot(P[i] - tris.a[t], n)
            }
        }
        var out = ProcGeo()
        out.P = P
        out.syncCounts()
        // Attributes: the points' and vertices' blended at the place, the primitive's as it is.
        let pattern = c.string("attribs")
        if !pattern.isEmpty {
            var start = [Int32](repeating: 0, count: count + 1), srcP: [Int32] = [], srcV: [Int32] = [], w: [Float] = []
            srcP.reserveCapacity(count * 3); srcV.reserveCapacity(count * 3); w.reserveCapacity(count * 3)
            for i in 0..<count {
                let v = tris.vertices[Int(tri[i])]
                for k in 0..<3 {
                    srcV.append(v[k])
                    srcP.append(g.vertexPoint[Int(v[k])])
                    w.append(bary[i][k])
                }
                start[i + 1] = Int32(srcV.count)
            }
            var pts = g.points.blended(start: start, sources: srcP, weights: w)
            if let n = pts.vectors3("N") { normals = n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) } }
            pts.filter { namePatternMatches(pattern, $0) && $0 != "N" }
            var verts = g.vertices.blended(start: start, sources: srcV, weights: w)
            verts.filter { namePatternMatches(pattern, $0) && pts[$0] == nil }
            var prims = g.prims.gathered(tri.map { tris.prim[Int($0)] })
            prims.filter { namePatternMatches(pattern, $0) && pts[$0] == nil && verts[$0] == nil }
            for t in [pts, verts, prims] {
                for a in t.attributes { out.points.set(a.name, a.values) }
            }
        }
        out.points.set("N", .vector3(normals))
        out.points.set("sourceprim", .int(tri.map { tris.prim[Int($0)] }))
        return out
    }

    // MARK: Copy to Points

    /// A target point's frame: `orient`, else `N` along +Z with `up` along +Y; scaled by `pscale` and `scale`.
    package static func frames(_ pts: ProcGeo) -> [float4x4] {
        let N = pts.points.vectors3("N"), up = pts.points.vectors3("up"), orient = pts.points.vectors4("orient")
        let pscale = pts.points.floats("pscale"), scale = pts.points.vectors3("scale")
        return (0..<pts.pointCount).map { i in
            var r = matrix_identity_float3x3
            if let o = orient {
                r = float3x3(simd_quatf(vector: o[i]).normalized)
            } else if let N, simd_length(N[i]) > 0 {
                let z = simd_normalize(N[i])
                var u = up?[i] ?? SIMD3(0, 1, 0)
                if abs(simd_dot(simd_normalize(u), z)) > 0.999 { u = abs(z.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0) }
                let x = simd_normalize(simd_cross(u, z))
                let y = simd_cross(z, x)
                r = float3x3(x, y, z)
            }
            let s = (scale?[i] ?? SIMD3(1, 1, 1)) * (pscale?[i] ?? 1)
            let m = r * float3x3(diagonal: s)
            return float4x4(SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0), SIMD4(pts.P[i], 1))
        }
    }

    static func copyToPoints(_ c: ProcCook) throws -> ProcGeo {
        let src = try c.input(0)
        let target = try c.input(1)
        let picked = try c.group("targetgroup", in: target, .point)
        let ids = (0..<target.pointCount).filter { picked[$0] }
        let frame = frames(target)
        let n = ids.count, np = src.pointCount, nv = src.vertexCount, nq = src.primCount
        var out = ProcGeo()
        // Positions: every copy's, on every core.
        out.P = [SIMD3<Float>](repeating: .zero, count: n * np)
        out.P.withUnsafeMutableBufferPointer { P in
            src.P.withUnsafeBufferPointer { S in
                parallelChunks(n, grain: max(1, 16384 / max(np, 1))) { range in
                    for k in range {
                        let m = frame[ids[k]]
                        for i in 0..<np {
                            let q = m * SIMD4(S[i], 1)
                            P[k * np + i] = SIMD3(q.x, q.y, q.z)
                        }
                    }
                }
            }
        }
        // Topology: the source's, offset per copy.
        out.vertexPoint.reserveCapacity(n * nv)
        out.primStart.reserveCapacity(n * nq + 1)
        for k in 0..<n {
            let po = Int32(k * np), vo = Int32(k * nv)
            for v in src.vertexPoint { out.vertexPoint.append(v + po) }
            for s in src.primStart.dropFirst() { out.primStart.append(s + vo) }
            out.primClosed += src.primClosed
        }
        func rows(_ m: Int) -> [Int32] { (0..<(n * m)).map { Int32($0 % max(m, 1)) } }
        out.points = src.points.gathered(rows(np))
        out.vertices = src.vertices.gathered(rows(nv))
        out.prims = src.prims.gathered(rows(nq))
        out.detail = src.detail
        // Vectors turned with each copy.
        for name in ["N", "up", "v"] {
            guard var a = out.points.vectors3(name) else { continue }
            for k in 0..<n {
                let m = frame[ids[k]]
                let l = float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                 SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                let nm = name == "N" && l.determinant != 0 ? l.inverse.transpose : l
                for i in 0..<np {
                    let v = nm * a[k * np + i]
                    a[k * np + i] = name == "v" || simd_length(v) == 0 ? v : simd_normalize(v)
                }
            }
            out.points.set(name, .vector3(a))
        }
        // The target points' attributes onto their copies (not those that place them).
        let pattern = c.string("attribs")
        if !pattern.isEmpty {
            let placing: Set<String> = ["N", "up", "orient", "pscale", "scale", "P"]
            let names = target.points.attributes.map(\.name).filter { namePatternMatches(pattern, $0) && !placing.contains($0) }
            if !names.isEmpty {
                let pointCopy = (0..<(n * np)).map { Int32(ids[$0 / max(np, 1)]) }
                let primCopy = (0..<(n * nq)).map { Int32(ids[$0 / max(nq, 1)]) }
                let onPoints = target.points.gathered(pointCopy), onPrims = target.points.gathered(primCopy)
                let toPrims = c.string("attribclass") == "primitive"
                for name in names {
                    if toPrims { out.prims.set(name, onPrims[name]!) } else { out.points.set(name, onPoints[name]!) }
                }
            }
        }
        if c.bool("copyattrib") {
            out.prims.set("copynum", .int((0..<(n * nq)).map { Int32($0 / max(nq, 1)) }))
        }
        return out
    }

    // MARK: Attribute Transfer

    static func attribtransfer(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input(0)
        let s = try c.input(1)
        let cls = c.attributeClass()
        let pattern = c.string("attribs")
        let maxDist = c.float("distance") > 0 ? c.float("distance") : Float.infinity
        let from = cls == .primitive ? (0..<s.primCount).map { s.primCenter($0) } : s.P
        let to = cls == .primitive ? (0..<g.primCount).map { g.primCenter($0) } : g.P
        guard !from.isEmpty else { throw ProcCookError("The second input has no \(cls.rawValue)s to transfer from") }
        let grid = PointGrid(from)
        var rows = [Int32](repeating: -1, count: to.count)
        rows.withUnsafeMutableBufferPointer { rows in
            parallelChunks(to.count, grain: 1024) { range in
                for i in range { rows[i] = grid.nearest(to[i], maxDistance: maxDist) }
            }
        }
        let table = s.table(cls).gathered(rows)
        let keepOld = g.table(cls)
        g.modify(cls) { t in
            for a in table.attributes where namePatternMatches(pattern, a.name) {
                // Out of reach: the element keeps its own value (or the default).
                var v = a.values
                if let old = keepOld[a.name], rows.contains(-1) {
                    for i in 0..<rows.count where rows[i] < 0 { v.set(i, old.vector(i)) }
                }
                t.set(a.name, v)
            }
        }
        return g
    }

    // MARK: Ray

    /// The nearest hit of a ray from `o` along `d` (both ways if `both`) on the triangles: its distance and triangle.
    static func cast(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ t: Triangles, both: Bool) -> (Float, Int)? {
        var best: (Float, Int)?
        for k in 0..<t.count {
            let e1 = t.b[k] - t.a[k], e2 = t.c[k] - t.a[k]
            let p = simd_cross(d, e2)
            let det = simd_dot(e1, p)
            if abs(det) < 1e-12 { continue }
            let inv = 1 / det
            let s = o - t.a[k]
            let u = simd_dot(s, p) * inv
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1)
            let v = simd_dot(d, q) * inv
            if v < 0 || u + v > 1 { continue }
            let dist = simd_dot(e2, q) * inv
            if dist < 0 && !both { continue }
            if abs(dist) < abs(best?.0 ?? .infinity) { best = (dist, k) }
        }
        return best
    }

    /// The nearest point of triangle (a, b, c) to `p` (Ericson's).
    static func closest(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    static func ray(_ c: inout ProcCook) throws -> ProcGeo {
        var g = try c.input(0)
        let surface = try c.input(1)
        let t = triangles(surface)
        guard t.count > 0 else { throw ProcCookError("The second input has no polygons to hit") }
        let picked = try c.group(in: g, .point)
        let nearest = c.string("method") == "minimum"
        let dir = simd_length(c.vec3("dir")) > 0 ? simd_normalize(c.vec3("dir")) : SIMD3<Float>(0, -1, 0)
        let N = c.bool("usenormal") ? g.points.vectors3("N") : nil
        let both = c.bool("bothways")
        let offset = c.float("offset")
        var P = g.P
        var hitN = g.points.vectors3("N") ?? [SIMD3<Float>](repeating: [0, 1, 0], count: g.pointCount)
        var hit = [Int32](repeating: 0, count: g.pointCount)
        let n = g.pointCount
        P.withUnsafeMutableBufferPointer { P in
            hitN.withUnsafeMutableBufferPointer { HN in
                hit.withUnsafeMutableBufferPointer { H in
                    parallelChunks(n, grain: 256) { range in
                        for i in range where picked[i] {
                            var k = -1
                            var at = P[i]
                            if nearest {
                                var best = Float.infinity
                                for j in 0..<t.count {
                                    let q = closest(P[i], t.a[j], t.b[j], t.c[j])
                                    let d = simd_distance_squared(q, P[i])
                                    if d < best { best = d; k = j; at = q }
                                }
                            } else {
                                let d = N.map { simd_length($0[i]) > 0 ? simd_normalize($0[i]) : dir } ?? dir
                                if let (dist, j) = cast(P[i], d, t, both: both) { k = j; at = P[i] + d * dist }
                            }
                            guard k >= 0 else { continue }
                            var fn = simd_cross(t.b[k] - t.a[k], t.c[k] - t.a[k])
                            fn = simd_length(fn) > 0 ? simd_normalize(fn) : SIMD3(0, 1, 0)
                            P[i] = at + fn * offset
                            HN[i] = fn
                            H[i] = 1
                        }
                    }
                }
            }
        }
        g.P = P
        if c.bool("putnormal") { g.points.set("N", .vector3(hitN)) }
        g.points.set("hitprim", .int(hit.map { $0 }))
        if !hit.contains(1) && n > 0 { c.warn("No point hit the surface") }
        return g
    }

    // MARK: Point Jitter

    static func pointjitter(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let picked = try c.group(in: g, .point)
        let s = c.vec3("scale") * c.float("amount"), seed = c.int("seed")
        for i in 0..<g.pointCount where picked[i] {
            g.P[i] += SIMD3(ProcNoise.random(i, seed: seed, 0) - 0.5, ProcNoise.random(i, seed: seed, 1) - 0.5,
                            ProcNoise.random(i, seed: seed, 2) - 0.5) * s
        }
        return g
    }

    // MARK: Voronoi Fracture

    static func voronoi(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input(0)
        let seeds = try c.input(1).P
        guard !seeds.isEmpty else { throw ProcCookError("No points on the second input to fracture by") }
        let b = g.bounds
        guard !b.isEmpty else { throw ProcCookError("Nothing to fracture") }
        let pad = (b.hi - b.lo) * 0.01 + 1e-4
        let grid = PointGrid(seeds)
        let cut = c.bool("cutinput")
        let insideName = c.string("interiorgroup")
        var out = ProcGeo()
        var near: [Int32] = []
        let mesh = cut ? g.editMesh().mesh : EditMesh()
        for (i, s) in seeds.enumerated() {
            // The cell: the box, cut by the bisector with each neighbour that could reach it (ConvexCell's planes:
            // n . p > w is outside).
            var cell = ConvexCell(box: b.lo - pad, b.hi + pad)
            let reach = simd_length(b.hi - b.lo) * 2
            grid.within(s, radius: reach, into: &near)
            near.sort { simd_distance_squared(seeds[Int($0)], s) < simd_distance_squared(seeds[Int($1)], s) }
            for j in near where Int(j) != i {
                let o = seeds[Int(j)]
                let d = o - s
                guard simd_length(d) > 1e-7 else { continue }
                // Farther than twice the cell's reach: no plane of it can cut the cell.
                if simd_length(d) / 2 > cell.vertices.map({ simd_distance($0, s) }).max() ?? .infinity { break }
                let n = simd_normalize(d)
                let mid = (s + o) / 2
                guard let next = cell.clipped(by: SIMD4(n, simd_dot(n, mid)), tag: Int32(j)) else { cell = ConvexCell(faces: []); break }
                cell = next
            }
            guard !cell.isEmpty else { continue }
            var piece = ProcGeo()
            var interior: [Bool] = []
            for f in cell.faces where f.polygon.count >= 3 {
                let base = Int32(piece.P.count)
                piece.P += f.polygon
                piece.vertexPoint += (0..<Int32(f.polygon.count)).map { base + $0 }
                piece.primStart.append(Int32(piece.vertexPoint.count))
                piece.primClosed.append(true)
                interior.append(f.tag >= 0)
            }
            piece.syncCounts()
            // Each face's corners round its plane's normal (outward): turn those that run the other way.
            for p in 0..<piece.primCount {
                let f = cell.faces.filter { $0.polygon.count >= 3 }[p]
                if simd_dot(piece.primNormal(p), SIMD3(f.plane.x, f.plane.y, f.plane.z)) < 0 { piece.vertexPoint[piece.vertexRange(p)].reverse() }
            }
            if cut {
                let cellMesh = piece.editMesh().mesh
                let planes = cell.faces.filter { $0.tag >= 0 }.map(\.plane)
                piece = ProcGeo(BooleanOps.apply(mesh, cellMesh, operation: .intersect, solver: .exact, voxel: 0.02))
                piece.prims.remove("material")
                interior = (0..<piece.primCount).map { p in
                    let q = piece.primCenter(p)
                    return planes.contains { abs(simd_dot(SIMD3($0.x, $0.y, $0.z), q) - $0.w) < 1e-3 * max(1, simd_length(b.hi - b.lo)) }
                }
                piece.transferAttributes(from: g)
            } else {
                piece.prims.setGroup(insideName.isEmpty ? "inside" : insideName, interior)
            }
            if cut && !insideName.isEmpty { piece.prims.setGroup(insideName, interior) }
            piece.prims.set("name", .string([Int32](repeating: 1, count: piece.primCount), table: ["", "piece\(i)"]))
            piece.points.set("piece", .int([Int32](repeating: Int32(i), count: piece.pointCount)))
            out.merge(piece)
        }
        return out
    }
}
