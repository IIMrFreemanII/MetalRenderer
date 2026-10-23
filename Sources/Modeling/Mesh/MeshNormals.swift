import Foundation
import simd

/// A mesh's faces as triangles, and a normal per corner: what the viewport draws and the engine traces.
///
/// A flat face's corners have its normal. A smooth face's corner has the angle-weighted mean of the faces round its
/// vertex that it is joined to: smooth faces across edges that aren't sharp (Blender's fans, "auto smooth" by marked
/// edges).
extension EditMesh {
    /// The face's corners as triangles (corner indices), counter-clockwise like the face: a fan for a convex face,
    /// ear clipping in its plane for one that isn't.
    package func triangulate(_ f: Int, into out: inout [Int32]) {
        let r = corners(f)
        let n = r.count
        if n == 3 { out += [Int32(r.lowerBound), Int32(r.lowerBound + 1), Int32(r.lowerBound + 2)]; return }
        let normal = faceNormal(f)
        // Convex (every turn the normal's way): a fan.
        var convex = true
        for k in 0..<n {
            let a = positions[Int(cornerVerts[r.lowerBound + k])]
            let b = positions[Int(cornerVerts[r.lowerBound + (k + 1) % n])]
            let c = positions[Int(cornerVerts[r.lowerBound + (k + 2) % n])]
            if simd_dot(simd_cross(b - a, c - b), normal) < -1e-12 { convex = false; break }
        }
        if convex || normal == .zero {
            if n == 4 {
                // A quad along its shorter diagonal (as Blender's beauty split), so a bent one folds the flatter way.
                let p = r.map { positions[Int(cornerVerts[$0])] }
                let c = Int32(r.lowerBound)
                if simd_distance_squared(p[0], p[2]) <= simd_distance_squared(p[1], p[3]) {
                    out += [c, c + 1, c + 2, c, c + 2, c + 3]
                } else {
                    out += [c, c + 1, c + 3, c + 1, c + 2, c + 3]
                }
                return
            }
            for k in 1..<(n - 1) { out += [Int32(r.lowerBound), Int32(r.lowerBound + k), Int32(r.lowerBound + k + 1)] }
            return
        }
        // Ear clipping in the plane.
        let u = simd_normalize(abs(normal.x) < 0.9 ? simd_cross(normal, [1, 0, 0]) : simd_cross(normal, [0, 1, 0]))
        let v = simd_cross(normal, u)
        let p2 = r.map { c -> SIMD2<Float> in
            let p = positions[Int(cornerVerts[c])]
            return SIMD2(simd_dot(p, u), simd_dot(p, v))
        }
        var ring = Array(0..<n)
        func cross2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        var guardCount = 0
        while ring.count > 3 && guardCount < n * n {
            guardCount += 1
            var clipped = false
            for i in 0..<ring.count {
                let ia = ring[(i + ring.count - 1) % ring.count], ib = ring[i], ic = ring[(i + 1) % ring.count]
                let a = p2[ia], b = p2[ib], c = p2[ic]
                if cross2(b - a, c - b) <= 0 { continue }   // reflex
                var inside = false
                for j in ring where j != ia && j != ib && j != ic {
                    let p = p2[j]
                    if cross2(b - a, p - a) >= 0 && cross2(c - b, p - b) >= 0 && cross2(a - c, p - c) >= 0 { inside = true; break }
                }
                if inside { continue }
                out += [Int32(r.lowerBound + ia), Int32(r.lowerBound + ib), Int32(r.lowerBound + ic)]
                ring.remove(at: i)
                clipped = true
                break
            }
            if !clipped {   // degenerate: a fan of what's left
                for k in 1..<(ring.count - 1) {
                    out += [Int32(r.lowerBound + ring[0]), Int32(r.lowerBound + ring[k]), Int32(r.lowerBound + ring[k + 1])]
                }
                return
            }
        }
        out += ring.map { Int32(r.lowerBound + $0) }
    }

    /// Every face's triangles, and the face each triangle is of.
    package func triangles() -> (corners: [Int32], face: [Int32]) {
        var out: [Int32] = []
        out.reserveCapacity((cornerCount - faceCount) * 3)
        var face: [Int32] = []
        face.reserveCapacity(cornerCount - faceCount)
        for f in 0..<faceCount {
            let before = out.count
            triangulate(f, into: &out)
            for _ in 0..<((out.count - before) / 3) { face.append(Int32(f)) }
        }
        return (out, face)
    }

    package func faceNormals() -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: faceCount)
        DispatchQueue.concurrentPerform(iterations: max(1, (faceCount + 4095) / 4096)) { part in
            let lo = part * 4096, hi = min(faceCount, lo + 4096)
            n.withUnsafeMutableBufferPointer { out in
                for f in lo..<hi { out[f] = faceNormal(f) }
            }
        }
        return n
    }

    /// The angle-weighted mean normal of each vertex's faces (all of them: no fans).
    package func vertexNormals(faceNormals fn: [SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
        let fn = fn ?? faceNormals()
        var n = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for f in 0..<faceCount {
            for c in corners(f) { n[Int(cornerVerts[c])] += fn[f] * cornerAngle(c, face: f) }
        }
        for v in 0..<vertexCount {
            let l = simd_length(n[v])
            n[v] = l > 0 ? n[v] / l : SIMD3(0, 1, 0)
        }
        return n
    }

    /// The angle of a face at its corner.
    package func cornerAngle(_ c: Int, face f: Int) -> Float {
        let p = positions[Int(cornerVerts[c])]
        let a = positions[Int(cornerVerts[prevCorner(c, face: f)])] - p
        let b = positions[Int(cornerVerts[nextCorner(c, face: f)])] - p
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0, lb > 0 else { return 0 }
        return acos(max(-1, min(1, simd_dot(a, b) / (la * lb))))
    }

    /// A normal for each corner: the face's for a flat face; for a smooth one, the angle-weighted mean of the smooth
    /// faces round its vertex that are joined to it across edges that aren't sharp.
    package func cornerNormals(topology t: MeshTopology? = nil, faceNormals fn: [SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
        let fn = fn ?? faceNormals()
        var out = [SIMD3<Float>](repeating: .zero, count: cornerCount)
        // Flat faces first; if every face is smooth and no edge is sharp, the vertex normals.
        var anyFlat = false
        for f in 0..<faceCount where faceFlags[f] & Flag.smooth == 0 {
            anyFlat = true
            for c in corners(f) { out[c] = fn[f] }
        }
        let anySharp = edgeFlags.contains { $0 & Flag.sharp != 0 }
        if !anySharp {
            let vn = vertexNormalsOfSmooth(fn)
            for f in 0..<faceCount where faceFlags[f] & Flag.smooth != 0 {
                for c in corners(f) { out[c] = vn[Int(cornerVerts[c])] }
            }
            _ = anyFlat
            return out
        }
        let t = t ?? MeshTopology(self)
        // Per vertex: its smooth corners in groups joined across smooth, non-sharp edges (union-find over the few).
        var group: [Int] = [], ids: [Int] = []
        for v in 0..<vertexCount {
            let cs = t.corners(ofVertex: v)
            ids.removeAll(keepingCapacity: true)
            for c in cs where faceFlags[Int(t.cornerFace[Int(c)])] & Flag.smooth != 0 { ids.append(Int(c)) }
            if ids.isEmpty { continue }
            group = Array(0..<ids.count)
            func find(_ i: Int) -> Int { var i = i; while group[i] != i { group[i] = group[group[i]]; i = group[i] }; return i }
            for i in 0..<ids.count {
                let ci = ids[i], fi = Int(t.cornerFace[ci])
                let ei = [cornerEdges[ci], cornerEdges[prevCorner(ci, face: fi)]]
                for j in (i + 1)..<ids.count where j < ids.count {
                    let cj = ids[j], fj = Int(t.cornerFace[cj])
                    let ej = [cornerEdges[cj], cornerEdges[prevCorner(cj, face: fj)]]
                    for e in ei where ej.contains(e) && edgeFlags[Int(e)] & Flag.sharp == 0 {
                        let a = find(i), b = find(j)
                        if a != b { group[a] = b }
                    }
                }
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: ids.count)
            for i in 0..<ids.count {
                let c = ids[i], f = Int(t.cornerFace[c])
                sums[find(i)] += fn[f] * cornerAngle(c, face: f)
            }
            for i in 0..<ids.count {
                let s = sums[find(i)], l = simd_length(s)
                out[ids[i]] = l > 0 ? s / l : fn[Int(t.cornerFace[ids[i]])]
            }
        }
        return out
    }

    /// Vertex normals over the smooth faces only.
    private func vertexNormalsOfSmooth(_ fn: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for f in 0..<faceCount where faceFlags[f] & Flag.smooth != 0 {
            for c in corners(f) { n[Int(cornerVerts[c])] += fn[f] * cornerAngle(c, face: f) }
        }
        for v in 0..<vertexCount {
            let l = simd_length(n[v])
            n[v] = l > 0 ? n[v] / l : SIMD3(0, 1, 0)
        }
        return n
    }
}

/// A mesh as triangles to draw or trace: a vertex per corner (its position, normal and UV), and the face of each
/// triangle. Corners with the same vertex, normal and UV are one vertex when `weld`.
package struct TriangleMesh {
    package var positions: [SIMD3<Float>] = []
    package var normals: [SIMD3<Float>] = []
    package var uvs: [SIMD2<Float>] = []
    package var indices: [UInt32] = []
    package var triangleFace: [Int32] = []
    package var triangleMaterial: [UInt16] = []
    /// The mesh vertex each of these vertices is.
    package var sourceVertex: [Int32] = []
    package var triangleCount: Int { indices.count / 3 }

    package init() {}

    package init(_ m: EditMesh, weld: Bool = true, skipHidden: Bool = false) {
        let (tri, face) = m.triangles()
        let cn = m.cornerNormals()
        var map = [Int32](repeating: -1, count: m.cornerCount)
        var seen: [Key: UInt32] = [:]
        if weld { seen.reserveCapacity(m.vertexCount) }
        struct Key: Hashable { var v: Int32; var n: SIMD3<Float>; var uv: SIMD2<Float> }
        for c in 0..<m.cornerCount {
            let v = m.cornerVerts[c]
            if weld {
                let k = Key(v: v, n: cn[c], uv: m.cornerUVs[c])
                if let i = seen[k] { map[c] = Int32(i); continue }
                seen[k] = UInt32(positions.count)
            }
            map[c] = Int32(positions.count)
            positions.append(m.positions[Int(v)])
            normals.append(cn[c])
            uvs.append(m.cornerUVs[c])
            sourceVertex.append(v)
        }
        indices.reserveCapacity(tri.count)
        for t in 0..<face.count {
            let f = Int(face[t])
            if skipHidden && m.faceFlags[f] & EditMesh.Flag.hide != 0 { continue }
            indices += [UInt32(map[Int(tri[3 * t])]), UInt32(map[Int(tri[3 * t + 1])]), UInt32(map[Int(tri[3 * t + 2])])]
            triangleFace.append(face[t])
            triangleMaterial.append(m.faceMaterial[f])
        }
    }
}
