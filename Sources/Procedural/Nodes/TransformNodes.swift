import Foundation
import simd

/// Transform, Merge, Copy and Transform, Mirror; and moving geometry by a matrix, which more nodes use.
enum TransformNodes {
    /// A transform's matrix from Houdini's parameters: translate, rotate (degrees), scale, pivot, the order of the
    /// three and of the rotations; scale and rotation are about the pivot.
    static func matrix(t: SIMD3<Float>, r: SIMD3<Float>, s: SIMD3<Float>, pivot p: SIMD3<Float>,
                       order: String = "SRT", rotateOrder: String = "XYZ") -> float4x4 {
        let rad = r * (.pi / 180)
        var rot = matrix_identity_float4x4
        for axis in rotateOrder {
            let m: float4x4
            switch axis {
            case "X": m = float4x4(simd_quatf(angle: rad.x, axis: [1, 0, 0]))
            case "Y": m = float4x4(simd_quatf(angle: rad.y, axis: [0, 1, 0]))
            default: m = float4x4(simd_quatf(angle: rad.z, axis: [0, 0, 1]))
            }
            rot = m * rot
        }
        let toPivot = translation(p), fromPivot = translation(-p)
        var out = matrix_identity_float4x4
        for step in order {
            let m: float4x4
            switch step {
            case "S": m = toPivot * float4x4(diagonal: SIMD4(s, 1)) * fromPivot
            case "R": m = toPivot * rot * fromPivot
            default: m = translation(t)
            }
            out = m * out
        }
        return out
    }

    static func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Moves points by `m` (all, or those `picked` flags) and turns the vectors that go with them: normals by the
    /// inverse transpose, `up` and `v` by the matrix, `orient` by its rotation. A matrix that mirrors turns the
    /// polygons round, so their fronts stay outside.
    static func apply(_ m: float4x4, to g: inout ProcGeo, points picked: [Bool]? = nil) {
        let l = float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                         SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                         SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let normalMatrix = l.determinant != 0 ? l.inverse.transpose : l
        let n = g.pointCount
        g.P.withUnsafeMutableBufferPointer { P in
            parallelChunks(n) { range in
                for i in range where picked?[i] ?? true {
                    let q = m * SIMD4(P[i], 1)
                    P[i] = SIMD3(q.x, q.y, q.z)
                }
            }
        }
        func turn(_ table: inout AttributeTable, _ name: String, _ mat: float3x3, normalize: Bool, rows: [Bool]?) {
            guard var a = table.vectors3(name) else { return }
            for i in a.indices where rows?[i] ?? true {
                let v = mat * a[i]
                a[i] = normalize && simd_length(v) > 0 ? simd_normalize(v) : v
            }
            table.set(name, .vector3(a))
        }
        let vertexPicked = picked.map { p in g.vertexPoint.map { p[Int($0)] } }
        let primsPicked = picked.map { GroupPattern.prims(ofPoints: $0, in: g) }
        turn(&g.points, "N", normalMatrix, normalize: true, rows: picked)
        turn(&g.vertices, "N", normalMatrix, normalize: true, rows: vertexPicked)
        turn(&g.prims, "N", normalMatrix, normalize: true, rows: primsPicked)
        for name in ["up", "v"] { turn(&g.points, name, l, normalize: name == "up", rows: picked) }
        if var o = g.points.vectors4("orient") {
            // The rotation part (columns of unit length) as a quaternion.
            let rot = float3x3(simd_normalize(l.columns.0), simd_normalize(l.columns.1), simd_normalize(l.columns.2))
            let q = simd_quatf(rot)
            for i in o.indices where picked?[i] ?? true {
                let r = q * simd_quatf(vector: o[i])
                o[i] = r.vector
            }
            g.points.set("orient", .vector4(o))
        }
        if l.determinant < 0 { reverse(&g, prims: primsPicked) }
    }

    /// Reverses the primitives' vertex order (all, or those flagged), vertex attributes with them.
    static func reverse(_ g: inout ProcGeo, prims picked: [Bool]? = nil) {
        var rows = (0..<Int32(g.vertexCount)).map { $0 }
        for p in 0..<g.primCount where picked?[p] ?? true { rows[g.vertexRange(p)].reverse() }
        g.vertexPoint = rows.map { g.vertexPoint[Int($0)] }
        g.vertices = g.vertices.gathered(rows)
    }

    static func transform(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        var m = matrix(t: c.vec3("t"), r: c.vec3("r"), s: c.vec3("s") * c.float("scale"), pivot: c.vec3("p"),
                       order: c.string("xord"), rotateOrder: c.string("rord"))
        if c.bool("invert") { m = m.inverse }
        var picked: [Bool]?
        if !GroupPattern.isEverything(c.string("group")) {
            let cls = c.attributeClass("grouptype")
            let sel = try c.group(in: g, cls)
            picked = cls == .primitive ? GroupPattern.points(ofPrims: sel, in: g) : sel
        }
        apply(m, to: &g, points: picked)
        return g
    }

    static func merge(_ c: ProcCook) -> ProcGeo {
        var out = ProcGeo()
        for case let g? in c.inputs { out.merge(g) }
        return out
    }

    static func copyTransform(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let n = max(1, c.int("ncy"))
        let step = matrix(t: c.vec3("t"), r: c.vec3("r"), s: c.vec3("s") * c.float("scale"), pivot: c.vec3("p"))
        var out = ProcGeo()
        var m = matrix_identity_float4x4
        for i in 0..<n {
            var copy = g
            if i > 0 { apply(m, to: &copy, points: nil) }
            if c.bool("copynum") {
                copy.points.set("copynum", .int([Int32](repeating: Int32(i), count: copy.pointCount)))
                copy.prims.set("copynum", .int([Int32](repeating: Int32(i), count: copy.primCount)))
            }
            out.merge(copy)
            m = step * m
        }
        return out
    }

    static func mirror(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let o = c.vec3("origin")
        let d = simd_length(c.vec3("dir")) > 0 ? simd_normalize(c.vec3("dir")) : SIMD3<Float>(1, 0, 0)
        let picked = try c.group(in: g, .primitive)
        // The mirrored half: the picked primitives, their points reflected.
        let half0 = g.keeping(prims: picked)
        var half = half0
        let h = float3x3(diagonal: [1, 1, 1]) - 2 * float3x3(rows: [d * d.x, d * d.y, d * d.z])
        var m = float4x4(SIMD4(h.columns.0, 0), SIMD4(h.columns.1, 0), SIMD4(h.columns.2, 0), SIMD4(0, 0, 0, 1))
        m = TransformNodes.translation(o) * m * TransformNodes.translation(-o)
        apply(m, to: &half, points: nil)
        guard c.bool("keeporiginal") else { return half }
        var out = g
        let base = Int32(out.pointCount)
        out.merge(half)
        if c.bool("consolidate") {
            // A mirrored point on the plane is its original: the seam's halves share it.
            let eps = c.float("distance")
            var map = (0..<Int32(out.pointCount)).map { $0 }
            // The kept half's points in the original: find them by position (the half was cut from `g`).
            let grid = PointGrid(g.P)
            for i in 0..<half0.pointCount where abs(simd_dot(half0.P[i] - o, d)) <= eps {
                let j = grid.nearest(half0.P[i], maxDistance: max(eps, 1e-6))
                if j >= 0 { map[Int(base) + i] = j }
            }
            for v in 0..<out.vertexCount { out.vertexPoint[v] = map[Int(out.vertexPoint[v])] }
            out.removeUnusedPoints()
        }
        return out
    }
}
