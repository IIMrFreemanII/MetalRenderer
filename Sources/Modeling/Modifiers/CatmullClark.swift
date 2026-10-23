import Foundation
import simd

/// Catmull-Clark subdivision, one level: every face becomes quads round a new face point, every edge gets an edge
/// point, every vertex moves to its smoothed place. Boundary and sharp edges (crease 1, or marked sharp when
/// `sharpCreases`) follow the curve rules (they stay put as curves); creases between 0 and 1 blend the two. UVs are
/// interpolated linearly (Blender's "Keep Corners" is the closest of its options). Face materials, sets and flags,
/// and edge marks, go to the faces and edges they become.
///
/// Built straight into the output's arrays: vertex points first (the old vertices' indices), then an edge point per
/// edge, then a face point per face; positions in parallel. Edges come out in the order they are made, not sorted.
package enum CatmullClark {
    package static func subdivide(_ m: EditMesh, sharpCreases: Bool = false) -> EditMesh {
        let nv = m.vertexCount, ne = m.edgeCount, nf = m.faceCount, nc = m.cornerCount
        guard nf > 0 else { return m }
        let t = MeshTopology(m)
        var out = EditMesh()
        // Topology.
        out.faceStart = [Int32](repeating: 0, count: nc + 1)
        out.cornerVerts = [Int32](repeating: 0, count: 4 * nc)
        out.cornerEdges = [Int32](repeating: 0, count: 4 * nc)
        out.cornerUVs = [SIMD2<Float>](repeating: .zero, count: 4 * nc)
        out.faceMaterial = [UInt16](repeating: 0, count: nc)
        out.faceSet = [Int32](repeating: 0, count: nc)
        out.faceFlags = [UInt8](repeating: 0, count: nc)
        out.edges = [SIMD2<Int32>](repeating: .zero, count: 2 * ne + nc)
        out.edgeFlags = [UInt8](repeating: 0, count: 2 * ne + nc)
        out.edgeCrease = [Float](repeating: 0, count: 2 * ne + nc)
        let ev = Int32(nv), fv = Int32(nv + ne)
        for e in 0..<ne {
            let a = m.edges[e].x, b = m.edges[e].y
            out.edges[2 * e] = SIMD2(a, ev + Int32(e))
            out.edges[2 * e + 1] = SIMD2(b, ev + Int32(e))
            for k in 0...1 {
                out.edgeFlags[2 * e + k] = m.edgeFlags[e] & ~EditMesh.Flag.select
                out.edgeCrease[2 * e + k] = m.edgeCrease[e]
            }
        }
        for f in 0..<nf {
            let r = m.corners(f)
            let n = r.count
            var faceUV = SIMD2<Float>.zero
            for c in r { faceUV += m.cornerUVs[c] }
            faceUV /= Float(n)
            for (i, c) in r.enumerated() {
                let cp = r.lowerBound + (i + n - 1) % n, cn = r.lowerBound + (i + 1) % n
                let q = c   // one output face per input corner
                let ei = Int(m.cornerEdges[c]), ep = Int(m.cornerEdges[cp])
                let v = m.cornerVerts[c]
                // Interior edge of this corner: its edge point to the face point.
                out.edges[2 * ne + c] = SIMD2(ev + Int32(ei), fv + Int32(f))
                let o = 4 * q
                out.cornerVerts[o] = v
                out.cornerVerts[o + 1] = ev + Int32(ei)
                out.cornerVerts[o + 2] = fv + Int32(f)
                out.cornerVerts[o + 3] = ev + Int32(ep)
                out.cornerEdges[o] = Int32(2 * ei + (m.edges[ei].x == v ? 0 : 1))
                out.cornerEdges[o + 1] = Int32(2 * ne + c)
                out.cornerEdges[o + 2] = Int32(2 * ne + cp)
                out.cornerEdges[o + 3] = Int32(2 * ep + (m.edges[ep].x == v ? 0 : 1))
                let uv = m.cornerUVs[c]
                out.cornerUVs[o] = uv
                out.cornerUVs[o + 1] = (uv + m.cornerUVs[cn]) / 2
                out.cornerUVs[o + 2] = faceUV
                out.cornerUVs[o + 3] = (uv + m.cornerUVs[cp]) / 2
                out.faceStart[q + 1] = Int32(o + 4)
                out.faceMaterial[q] = m.faceMaterial[f]
                out.faceSet[q] = m.faceSet[f]
                out.faceFlags[q] = m.faceFlags[f]
            }
        }
        // The output faces are numbered by input corner, which runs face by face: their ranges are in order already.
        out.vertFlags = [UInt8](repeating: 0, count: nv + ne + nf)
        for v in 0..<nv { out.vertFlags[v] = m.vertFlags[v] & EditMesh.Flag.hide }
        out.positions = positions(m, topology: t, sharpCreases: sharpCreases)
        out.touch()
        return out
    }

    /// How sharp an edge is for the rules: 1 for the boundary or a full crease, its crease between.
    @inline(__always) static func sharpness(_ m: EditMesh, _ t: MeshTopology, _ e: Int, _ sharpCreases: Bool) -> Float {
        if t.faceCount(ofEdge: e) != 2 { return 1 }
        if sharpCreases && m.edgeFlags[e] & EditMesh.Flag.sharp != 0 { return 1 }
        return m.edgeCrease[e]
    }

    /// The new positions: vertex points, edge points, face points.
    package static func positions(_ m: EditMesh, topology t: MeshTopology, sharpCreases: Bool) -> [SIMD3<Float>] {
        let nv = m.vertexCount, ne = m.edgeCount, nf = m.faceCount
        var out = [SIMD3<Float>](repeating: .zero, count: nv + ne + nf)
        var face = [SIMD3<Float>](repeating: .zero, count: nf)
        let grain = 4096
        // Face points.
        face.withUnsafeMutableBufferPointer { fb in
            let fp = fb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: (nf + grain - 1) / grain) { part in
                for f in (part * grain)..<min(nf, part * grain + grain) { fp[f] = m.faceCenter(f) }
            }
        }
        out.withUnsafeMutableBufferPointer { o in
            let op = o.baseAddress!
            for f in 0..<nf { op[nv + ne + f] = face[f] }
            // Edge points.
            DispatchQueue.concurrentPerform(iterations: (ne + grain - 1) / grain) { part in
                for e in (part * grain)..<min(ne, part * grain + grain) {
                    let a = m.positions[Int(m.edges[e].x)], b = m.positions[Int(m.edges[e].y)]
                    let mid = (a + b) / 2
                    let s = sharpness(m, t, e, sharpCreases)
                    var smooth = mid
                    let fs = t.corners(ofEdge: e)
                    if fs.count == 2 {
                        let f0 = Int(t.cornerFace[Int(fs[fs.startIndex])]), f1 = Int(t.cornerFace[Int(fs[fs.startIndex + 1])])
                        smooth = (a + b + face[f0] + face[f1]) / 4
                    }
                    op[nv + e] = simd_mix(smooth, mid, SIMD3(repeating: min(1, s)))
                }
            }
            // Vertex points.
            DispatchQueue.concurrentPerform(iterations: (nv + grain - 1) / grain) { part in
                for v in (part * grain)..<min(nv, part * grain + grain) {
                    let p = m.positions[v]
                    let es = t.edges(ofVertex: v)
                    let cs = t.corners(ofVertex: v)
                    if es.isEmpty || cs.isEmpty { op[v] = p; continue }
                    // Sharp edges round it: 0 or 1 smooth, 2 a crease curve, more a corner.
                    var sharpSum: Float = 0, sharpCount = 0
                    var sharpMid = SIMD3<Float>.zero
                    for e in es {
                        let s = sharpness(m, t, Int(e), sharpCreases)
                        if s > 0 {
                            sharpCount += 1
                            sharpSum += s
                            sharpMid += m.positions[Int(MeshTopology.other(m, edge: Int(e), from: Int32(v)))]
                        }
                    }
                    let n = Float(es.count)
                    var fsum = SIMD3<Float>.zero
                    for c in cs { fsum += face[Int(t.cornerFace[Int(c)])] }
                    var rsum = SIMD3<Float>.zero
                    for e in es { rsum += (p + m.positions[Int(MeshTopology.other(m, edge: Int(e), from: Int32(v)))]) / 2 }
                    let F = fsum / Float(cs.count), R = rsum / n
                    let smooth = (F + 2 * R + (n - 3) * p) / n
                    if sharpCount < 2 { op[v] = smooth; continue }
                    // A corner of the boundary (two edges, both open): it stays (Blender's Keep Corners).
                    if es.count == 2 && sharpSum >= 2 { op[v] = p; continue }
                    if sharpCount > 2 { op[v] = simd_mix(smooth, p, SIMD3(repeating: min(1, sharpSum / Float(sharpCount)))); continue }
                    let crease = (sharpMid + 6 * p) / 8
                    op[v] = simd_mix(smooth, crease, SIMD3(repeating: min(1, sharpSum / 2)))
                }
            }
        }
        return out
    }

    /// `levels` subdivisions.
    package static func subdivide(_ m: EditMesh, levels: Int, sharpCreases: Bool = false) -> EditMesh {
        var mesh = m
        for _ in 0..<max(0, levels) { mesh = subdivide(mesh, sharpCreases: sharpCreases) }
        return mesh
    }
}
