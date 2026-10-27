import EngineCore
import Foundation
import Modeling
import simd

/// The nodes that change polygons: extrude, subdivide, boolean, bevel, reduce, divide, fuse, clean, facet, normal,
/// reverse, smooth, thicken, UV unwrap.
enum PolygonNodes {
    // MARK: PolyExtrude

    private struct EdgeKey: Hashable { var region: Int32; var a: Int32; var b: Int32 }
    private struct PointKey: Hashable { var region: Int32; var point: Int32 }

    static func polyextrude(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        var picked = try c.group(in: g, .primitive)
        for p in 0..<g.primCount where !g.isPolygon(p) { picked[p] = false }
        let individual = c.string("split") == "individual"
        let dist = c.float("dist"), inset = c.float("inset"), divs = max(1, c.int("divs"))
        // Regions: one for all the picked polygons (connected), or one each (individual).
        var region = [Int32](repeating: -1, count: g.primCount)
        for p in 0..<g.primCount where picked[p] { region[p] = individual ? Int32(p) : 0 }
        // Sides a region's polygons use once are its boundary.
        var sideCount: [EdgeKey: Int] = [:]
        for p in 0..<g.primCount where picked[p] {
            let r = g.vertexRange(p)
            for (k, v) in r.enumerated() {
                let a = g.vertexPoint[v], b = g.vertexPoint[r.lowerBound + (k + 1) % r.count]
                sideCount[EdgeKey(region: region[p], a: min(a, b), b: max(a, b)), default: 0] += 1
            }
        }
        // The front's points: a copy of each region's points, moved along their polygons' mean normal.
        var b = GeoBuilder(points: g)
        var front: [PointKey: Int32] = [:]
        var normal: [PointKey: SIMD3<Float>] = [:]
        var insetDir: [PointKey: SIMD3<Float>] = [:]
        for p in 0..<g.primCount where picked[p] {
            let n = g.primNormal(p), area = max(g.primArea(p), 1e-12)
            let r = g.vertexRange(p)
            let centre = g.primCenter(p)
            for (k, v) in r.enumerated() {
                let key = PointKey(region: region[p], point: g.vertexPoint[v])
                normal[key, default: .zero] += n * area
                if front[key] == nil { front[key] = b.addPoint(g.P[Int(key.point)], from: key.point) }
                guard inset != 0 else { continue }
                if individual {
                    insetDir[key] = centre - g.P[Int(key.point)]
                } else {
                    // A boundary side pulls its ends inward, across it within the polygon's plane.
                    let w = r.lowerBound + (k + 1) % r.count
                    let a = g.vertexPoint[v], bb = g.vertexPoint[w]
                    if sideCount[EdgeKey(region: region[p], a: min(a, bb), b: max(a, bb))] == 1 {
                        let side = simd_normalize(g.P[Int(bb)] - g.P[Int(a)])
                        let inward = simd_cross(n, side)
                        insetDir[PointKey(region: region[p], point: a), default: .zero] += inward
                        insetDir[PointKey(region: region[p], point: bb), default: .zero] += inward
                    }
                }
            }
        }
        for (key, i) in front {
            var pos = g.P[Int(key.point)]
            if let d = insetDir[key], simd_length(d) > 0 {
                pos += individual ? d * min(inset / max(simd_length(d), 1e-9), 1) : simd_normalize(d) * inset
            }
            if let n = normal[key], simd_length(n) > 0 { pos += simd_normalize(n) * dist }
            b.P[Int(i)] = pos
        }
        // Every primitive not extruded, as it was (the extruded ones' backs if asked, turned round).
        let outputBack = c.bool("outputback")
        for p in 0..<g.primCount where !picked[p] || outputBack { b.copyPrim(p, of: g, reversed: picked[p]) }
        // Fronts: the polygons on their new points.
        var frontPrims: [Int] = []
        for p in 0..<g.primCount where picked[p] {
            let r = Array(g.vertexRange(p))
            frontPrims.append(b.primRows.count)
            b.addPrim(r.map { front[PointKey(region: region[p], point: g.vertexPoint[$0])]! }, vertices: r.map { Int32($0) }, from: Int32(p))
        }
        // Sides: a wall of `divs` quads on each boundary side, from the old points up to the front's.
        var columns: [PointKey: [Int32]] = [:]
        func column(_ key: PointKey) -> [Int32] {
            if let c = columns[key] { return c }
            let lo = g.P[Int(key.point)], hi = b.P[Int(front[key]!)]
            var col = [key.point]
            for k in 1..<divs { col.append(b.addPoint(lo + (hi - lo) * (Float(k) / Float(divs)), from: key.point)) }
            col.append(front[key]!)
            columns[key] = col
            return col
        }
        var sidePrims: [Int] = []
        for p in 0..<g.primCount where picked[p] {
            let r = g.vertexRange(p)
            for (k, v) in r.enumerated() {
                let w = r.lowerBound + (k + 1) % r.count
                let a = g.vertexPoint[v], bb = g.vertexPoint[w]
                guard sideCount[EdgeKey(region: region[p], a: min(a, bb), b: max(a, bb))] == 1 else { continue }
                let ca = column(PointKey(region: region[p], point: a)), cb = column(PointKey(region: region[p], point: bb))
                for level in 0..<divs {
                    sidePrims.append(b.primRows.count)
                    b.addPrim([ca[level], cb[level], cb[level + 1], ca[level + 1]],
                              vertices: [Int32(v), Int32(w), Int32(w), Int32(v)], from: Int32(p))
                }
            }
        }
        var out = b.build(from: g)
        out.removeUnusedPoints()
        func group(_ name: String, _ prims: [Int]) {
            guard !name.isEmpty else { return }
            var m = [Bool](repeating: false, count: out.primCount)
            for p in prims where p < m.count { m[p] = true }
            out.prims.setGroup(name, m)
        }
        group(c.string("frontgroup"), frontPrims)
        group(c.string("sidegroup"), sidePrims)
        return out
    }

    // MARK: Through the modeller's operations

    /// Runs a modeller operation on the geometry as a mesh, then gives the result the attributes it didn't keep from
    /// the nearest elements of the input.
    static func bridged(_ g: ProcGeo, selectPoints: [Bool]? = nil, _ op: (EditMesh) throws -> EditMesh) rethrows -> ProcGeo {
        let (m, materials) = g.editMesh(selectPoints: selectPoints)
        var out = ProcGeo(try op(m), materials: g.prims["material"] == nil ? [] : materials)
        if g.prims["material"] == nil { out.prims.remove("material") }
        if g.vertices["uv"] == nil { out.vertices.remove("uv") }
        out.transferAttributes(from: g)
        return out
    }

    static func subdivide(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let levels = max(0, min(6, c.int("iterations")))
        guard levels > 0 else { return g }
        return bridged(g) { CatmullClark.subdivide($0, levels: levels, sharpCreases: c.bool("creases")) }
    }

    static func boolean(_ c: ProcCook) throws -> ProcGeo {
        let a = try c.input(0), b = try c.input(1)
        let op: Modifier.BooleanOperation = switch c.string("operation") {
        case "union": .union
        case "intersect": .intersect
        default: .difference
        }
        let solver: Modifier.BooleanSolver = c.string("solver") == "voxel" ? .voxel : .exact
        var both = a
        both.merge(b)
        let mb = b.editMesh().mesh
        var out = ProcGeo(BooleanOps.apply(a.editMesh().mesh, mb, operation: op, solver: solver, voxel: max(1e-4, c.float("voxel"))))
        if a.vertices["uv"] == nil { out.vertices.remove("uv") }
        out.prims.remove("material")
        out.transferAttributes(from: both)
        return out
    }

    static func polybevel(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let width = c.float("dist"), segments = max(1, c.int("divs"))
        if GroupPattern.isEverything(c.string("group")) {
            return bridged(g) { ModifierOps.bevel($0, width: width, segments: segments, angle: c.float("angle") * .pi / 180) }
        }
        let pts = try c.group(in: g, .point)
        return bridged(g) { m in
            var m = m
            let edges = (0..<m.edgeCount).filter { pts[Int(m.edges[$0].x)] && pts[Int(m.edges[$0].y)] }
            m.selectAll(false)
            m.select(edges: edges)
            m.bevelEdges(width: width, segments: segments, onlySelected: true)
            return m
        }
    }

    static func polyreduce(_ c: ProcCook) throws -> ProcGeo {
        let g = try divided(try c.input(), picked: nil)
        let keep = max(0.01, min(1, c.float("percentage") / 100))
        let target = max(4, Int(Float(g.primCount) * keep))
        guard g.primCount > target else { return g }
        // The simplifier's vertices are ours (a vertex's UV with it); its positions, our points.
        let positions = g.vertexPoint.map { g.P[Int($0)] }
        let uvs = g.vertices.vectors2("uv") ?? [SIMD2<Float>](repeating: .zero, count: g.vertexCount)
        // Vertices of one point with one UV are one of the simplifier's (others are seams it keeps).
        struct Wedge: Hashable { var point: Int32; var uv: SIMD2<UInt32> }
        var wedge: [Wedge: UInt32] = [:]
        var tris: [UInt32] = []
        tris.reserveCapacity(g.vertexCount)
        for p in 0..<g.primCount where g.primSize(p) == 3 {
            for v in g.vertexRange(p) {
                let key = Wedge(point: g.vertexPoint[v], uv: SIMD2(uvs[v].x.bitPattern, uvs[v].y.bitPattern))
                if let w = wedge[key] { tris.append(w) } else { wedge[key] = UInt32(v); tris.append(UInt32(v)) }
            }
        }
        let kept = positions.withUnsafeBufferPointer { pos in
            g.vertexPoint.withUnsafeBufferPointer { ids in
                uvs.withUnsafeBufferPointer { uv in
                    MeshSimplifier.simplify(triangles: tris, positions: pos, posId: ids, uvs: uv, targetTriangles: target, locked: { _ in false }).triangles
                }
            }
        }
        let primOf = g.vertexPrims()
        var b = GeoBuilder(points: g)
        for t in stride(from: 0, to: kept.count - 2, by: 3) {
            let vs = [Int32(kept[t]), Int32(kept[t + 1]), Int32(kept[t + 2])]
            b.addPrim(vs.map { g.vertexPoint[Int($0)] }, vertices: vs, from: primOf[Int(vs[0])])
        }
        var out = b.build(from: g)
        out.removeUnusedPoints()
        return out
    }

    static func thicken(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        return bridged(g) { ModifierOps.solidify($0, thickness: c.float("thickness"), offset: c.float("offset"), even: c.bool("even"), rim: c.bool("rim")) }
    }

    static func uvunwrap(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        var (m, _) = g.editMesh()
        m.unwrap(c.string("method") == "seams" ? .seams : .smart(angle: c.float("angle") * .pi / 180), onlySelected: false)
        // Faces are the polygons in order (none was degenerate): their corners' UVs are the vertices'.
        let polygons = (0..<g.primCount).filter { g.isPolygon($0) }
        guard m.faceCount == polygons.count else {
            var out = ProcGeo(m)
            out.transferAttributes(from: g, skipping: ["P", "uv"])
            return out
        }
        var uv = g.vertices.vectors2("uv") ?? [SIMD2<Float>](repeating: .zero, count: g.vertexCount)
        for (f, p) in polygons.enumerated() {
            let r = g.vertexRange(p), cr = m.corners(f)
            for k in 0..<min(r.count, cr.count) { uv[r.lowerBound + k] = m.cornerUVs[cr.lowerBound + k] }
        }
        g.vertices.set("uv", .vector2(uv))
        return g
    }

    // MARK: Divide

    /// The polygons `picked` flags (all if nil) as triangles; vertex attributes kept exactly (a triangle's corners
    /// are the polygon's vertices).
    static func divided(_ g: ProcGeo, picked: [Bool]?) throws -> ProcGeo {
        var m = EditMesh()
        m.positions = g.P
        m.faceStart = g.primStart
        m.cornerVerts = g.vertexPoint
        var b = GeoBuilder(points: g)
        var tri: [Int32] = []
        for p in 0..<g.primCount {
            guard g.isPolygon(p), g.primSize(p) > 3, picked?[p] ?? true else { b.copyPrim(p, of: g); continue }
            tri.removeAll(keepingCapacity: true)
            m.triangulate(p, into: &tri)
            for t in stride(from: 0, to: tri.count - 2, by: 3) {
                let vs = [tri[t], tri[t + 1], tri[t + 2]]
                b.addPrim(vs.map { g.vertexPoint[Int($0)] }, vertices: vs, from: Int32(p))
            }
        }
        return b.build(from: g)
    }

    static func divide(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        return try divided(g, picked: GroupPattern.isEverything(c.string("group")) ? nil : try c.group(in: g, .primitive))
    }

    // MARK: Fuse, Clean, Facet

    /// Primitives without repeated points next to each other; those left with too few points go (a polygon below 3,
    /// a polyline below 2).
    static func removeDegenerate(_ g: ProcGeo) -> ProcGeo {
        var b = GeoBuilder(points: g)
        for p in 0..<g.primCount {
            var vs: [Int32] = []
            for v in g.vertexRange(p) where vs.last.map({ g.vertexPoint[Int($0)] }) != g.vertexPoint[v] { vs.append(Int32(v)) }
            if g.primClosed[p] { while vs.count > 1 && g.vertexPoint[Int(vs[0])] == g.vertexPoint[Int(vs[vs.count - 1])] { vs.removeLast() } }
            if vs.count < (g.primClosed[p] ? 3 : 2) { continue }
            b.addPrim(vs.map { g.vertexPoint[Int($0)] }, vertices: vs, from: Int32(p), closed: g.primClosed[p])
        }
        return b.build(from: g)
    }

    static func fuse(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let picked = try c.group(in: g, .point)
        let d = max(0, c.float("dist"))
        let ids = (0..<g.pointCount).filter { picked[$0] }
        let grid = PointGrid(ids.map { g.P[$0] }, cell: max(d, 1e-6) * 2)
        // Each point onto the first (lowest) picked point within reach that kept its own place.
        var map = (0..<Int32(g.pointCount)).map { $0 }
        var near: [Int32] = []
        for (k, i) in ids.enumerated() {
            grid.within(g.P[i], radius: d, into: &near)
            var target = Int32(i)
            for j in near where Int(j) < k {
                let o = Int32(ids[Int(j)])
                if map[Int(o)] == o && o < target { target = o }
            }
            map[i] = target
        }
        for v in 0..<g.vertexCount { g.vertexPoint[v] = map[Int(g.vertexPoint[v])] }
        if c.bool("removedegen") { g = removeDegenerate(g) }
        g.removeUnusedPoints()
        return g
    }

    static func clean(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        if c.bool("removedegen") { g = removeDegenerate(g) }
        if c.bool("removeunused") { g.removeUnusedPoints() }
        return g
    }

    static func facet(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        if c.bool("unique") {
            var b = GeoBuilder()
            for p in 0..<g.primCount {
                let r = Array(g.vertexRange(p))
                let pts = r.map { b.addPoint(g.P[Int(g.vertexPoint[$0])], from: g.vertexPoint[$0]) }
                b.addPrim(pts, vertices: r.map { Int32($0) }, from: Int32(p), closed: g.primClosed[p])
            }
            g = b.build(from: g)
        }
        if c.bool("removenormals") {
            g.points.remove("N")
            g.vertices.remove("N")
        }
        return g
    }

    // MARK: Normals

    /// For each point, the primitives that use it (CSR: `start[p]..<start[p+1]` into `prims`).
    static func pointPrims(_ g: ProcGeo) -> (start: [Int32], prims: [Int32]) {
        var start = [Int32](repeating: 0, count: g.pointCount + 1)
        for v in g.vertexPoint { start[Int(v) + 1] += 1 }
        for i in 0..<g.pointCount { start[i + 1] += start[i] }
        var fill = start
        var prims = [Int32](repeating: 0, count: g.vertexCount)
        for p in 0..<g.primCount { for v in g.vertexRange(p) { let pt = Int(g.vertexPoint[v]); prims[Int(fill[pt])] = Int32(p); fill[pt] += 1 } }
        return (start, prims)
    }

    /// Point normals: the area-weighted (or plain) mean of the normals of the polygons round each point.
    static func pointNormals(_ g: ProcGeo, equal: Bool = false) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: g.pointCount)
        for p in 0..<g.primCount where g.isPolygon(p) {
            let fn = g.primNormal(p) * (equal ? 1 : g.primArea(p))
            for v in g.vertexRange(p) { n[Int(g.vertexPoint[v])] += fn }
        }
        return n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    static func normal(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let equal = c.string("weighting") == "equal"
        switch c.string("type") {
        case "points":
            g.points.set("N", .vector3(pointNormals(g, equal: equal)))
            g.vertices.remove("N")
        case "primitives":
            g.prims.set("N", .vector3((0..<g.primCount).map { g.primNormal($0) }))
        default:
            let cusp = cos(c.float("cusp") * .pi / 180)
            let fn = (0..<g.primCount).map { g.primNormal($0) }
            let w = (0..<g.primCount).map { equal ? 1 : g.primArea($0) }
            let (start, prims) = pointPrims(g)
            var out = [SIMD3<Float>](repeating: .zero, count: g.vertexCount)
            let vp = g.vertexPrims()
            for v in 0..<g.vertexCount {
                let p = Int(vp[v]), pt = Int(g.vertexPoint[v])
                var n = SIMD3<Float>.zero
                for k in Int(start[pt])..<Int(start[pt + 1]) {
                    let q = Int(prims[k])
                    if q == p || simd_dot(fn[q], fn[p]) >= cusp { n += fn[q] * w[q] }
                }
                out[v] = simd_length(n) > 0 ? simd_normalize(n) : fn[p]
            }
            g.vertices.set("N", .vector3(out))
            g.points.remove("N")
        }
        return g
    }

    static func reverse(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        TransformNodes.reverse(&g, prims: GroupPattern.isEverything(c.string("group")) ? nil : try c.group(in: g, .primitive))
        return g
    }

    // MARK: Smooth

    static func smooth(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let picked = try c.group(in: g, .point)
        let strength = c.float("strength"), iterations = max(0, c.int("iterations"))
        // Neighbours: the points next to each along its primitives' sides.
        var pairs: [(Int32, Int32)] = []
        for p in 0..<g.primCount {
            let r = g.vertexRange(p)
            guard r.count > 1 else { continue }
            let last = g.primClosed[p] ? r.count : r.count - 1
            for k in 0..<last {
                let a = g.vertexPoint[r.lowerBound + k], b = g.vertexPoint[r.lowerBound + (k + 1) % r.count]
                pairs.append((min(a, b), max(a, b)))
            }
        }
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var start = [Int32](repeating: 0, count: g.pointCount + 1)
        var unique: [(Int32, Int32)] = []
        for e in pairs where unique.last.map({ $0 != e }) ?? true { unique.append(e) }
        for (a, b) in unique { start[Int(a) + 1] += 1; start[Int(b) + 1] += 1 }
        for i in 0..<g.pointCount { start[i + 1] += start[i] }
        var fill = start
        var nb = [Int32](repeating: 0, count: Int(start[g.pointCount]))
        for (a, b) in unique {
            nb[Int(fill[Int(a)])] = b; fill[Int(a)] += 1
            nb[Int(fill[Int(b)])] = a; fill[Int(b)] += 1
        }
        let n = g.pointCount
        var next = g.P
        for _ in 0..<iterations {
            let cur = g.P
            cur.withUnsafeBufferPointer { P in
                next.withUnsafeMutableBufferPointer { out in
                    parallelChunks(n) { range in
                        for i in range where picked[i] {
                            let r = Int(start[i])..<Int(start[i + 1])
                            guard !r.isEmpty else { continue }
                            var avg = SIMD3<Float>.zero
                            for k in r { avg += P[Int(nb[k])] }
                            avg /= Float(r.count)
                            out[i] = P[i] + (avg - P[i]) * strength
                        }
                    }
                }
            }
            g.P = next
        }
        return g
    }
}
