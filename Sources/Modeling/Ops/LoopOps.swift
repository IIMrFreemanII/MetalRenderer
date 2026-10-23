import Foundation
import simd

/// Edge loops and rings (Alt-click, Ctrl-Alt-click), and Loop Cut (Ctrl-R): walking quads from edge to edge.
extension EditMesh {
    /// The edge opposite `e` in the quad `f`, and its end on `start`'s side: in quad a b c d with e = ab, the
    /// opposite is cd, and a is joined to d.
    private func opposite(_ e: Int, start: Int32, in f: Int) -> (edge: Int, start: Int32)? {
        guard faceSize(f) == 4 else { return nil }
        let r = corners(f)
        guard let k = r.first(where: { Int(cornerEdges[$0]) == e }) else { return nil }
        let i = k - r.lowerBound
        let ca = r.lowerBound + i, cb = r.lowerBound + (i + 1) % 4, cc = r.lowerBound + (i + 2) % 4, cd = r.lowerBound + (i + 3) % 4
        let a = cornerVerts[ca], c = cornerVerts[cc], dv = cornerVerts[cd]
        _ = cb
        let opp = Int(cornerEdges[cc])   // c → d
        // a ↔ d, b ↔ c.
        return (opp, start == a ? dv : c)
    }

    /// The edge ring through `e`: edges opposite each other across quads, in order, each with the end on the ring's
    /// one side (so a loop cut puts its points the same way along all of them); whether it closes.
    package func edgeRing(from e: Int, topology t: MeshTopology? = nil) -> (edges: [(edge: Int, start: Int32)], faces: [Int], closed: Bool) {
        let t = t ?? MeshTopology(self)
        var out: [(edge: Int, start: Int32)] = [(e, edges[e].x)]
        var faces: [Int] = []
        var seen: Set<Int> = [e]
        // Forward through one face of e, then back through the other.
        let fs = t.faces(ofEdge: e)
        var closed = false
        func walk(_ first: Int) -> [(edge: Int, start: Int32, face: Int)] {
            var path: [(edge: Int, start: Int32, face: Int)] = []
            var edge = e, start = edges[e].x, face = first
            while let o = opposite(edge, start: start, in: face) {
                path.append((o.edge, o.start, face))
                if o.edge == e { closed = true; break }
                if seen.contains(o.edge) { break }
                seen.insert(o.edge)
                edge = o.edge
                start = o.start
                guard let next = t.faces(ofEdge: edge).first(where: { $0 != face }), t.faceCount(ofEdge: edge) == 2 else { break }
                face = next
            }
            return path
        }
        guard let f0 = fs.first else { return (out, [], false) }
        let fwd = walk(f0)
        for p in fwd where p.edge != e { out.append((p.edge, p.start)) }
        faces += fwd.map(\.face)
        if !closed, fs.count == 2 {
            let back = walk(fs[1])
            for p in back where p.edge != e { out.insert((p.edge, p.start), at: 0) }
            faces = back.map(\.face).reversed() + faces
        }
        return (out, faces, closed)
    }

    /// The edge loop through `e`: across vertices with four edges (and four faces), to the edge that shares no face
    /// with the one before; along the boundary for a boundary edge.
    package func edgeLoop(from e: Int, topology t: MeshTopology? = nil) -> [Int] {
        let t = t ?? MeshTopology(self)
        var loop: [Int] = [e]
        var seen: Set<Int> = [e]
        let boundary = t.isBoundary(e)
        for end in [edges[e].y, edges[e].x] {
            var edge = e, v = end
            while true {
                let es = t.edges(ofVertex: Int(v)).map { Int($0) }
                var next: Int?
                if boundary {
                    next = es.first { $0 != edge && t.isBoundary($0) }
                    if es.filter({ t.isBoundary($0) }).count != 2 { next = nil }
                } else if es.count == 4 && t.corners(ofVertex: Int(v)).count == 4 {
                    let facesOfEdge = Set(t.faces(ofEdge: edge))
                    next = es.first { $0 != edge && Set(t.faces(ofEdge: $0)).isDisjoint(with: facesOfEdge) }
                }
                guard let n = next, !seen.contains(n) else { break }
                seen.insert(n)
                if end == edges[e].y { loop.append(n) } else { loop.insert(n, at: 0) }
                edge = n
                v = MeshTopology.other(self, edge: n, from: v)
            }
        }
        return loop
    }

    /// Select the loop (or ring) through `e`; added to the selection if `extend`.
    package mutating func selectLoop(_ e: Int, ring: Bool, extend: Bool) {
        let t = MeshTopology(self)
        let picked = ring ? edgeRing(from: e, topology: t).edges.map(\.edge) : edgeLoop(from: e, topology: t)
        if !extend { for i in 0..<edgeCount { edgeFlags[i] &= ~Flag.select }; for v in 0..<vertexCount { vertFlags[v] &= ~Flag.select } }
        let allOn = picked.allSatisfy { isSelected(edge: $0) }
        for i in picked {
            setSelected(edge: i, !(extend && allOn))
            setSelected(vertex: Int(edges[i].x), !(extend && allOn))
            setSelected(vertex: Int(edges[i].y), !(extend && allOn))
        }
        flushSelection(from: .vertex)
    }

    /// Loop Cut (Ctrl-R): `cuts` new loops across the ring through `e`, evenly along its edges (`slide`, −1…1, moves
    /// a single cut toward either side). Quads on the ring are split; any other face with a cut edge gets the new
    /// points in that edge. The new edge loops are selected.
    package mutating func loopCut(_ e: Int, cuts: Int = 1, slide: Float = 0) {
        guard cuts >= 1, e < edgeCount else { return }
        let t = MeshTopology(self)
        let ring = edgeRing(from: e, topology: t)
        var d = draft()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        // New points along each ring edge, from its start.
        var points: [Int: (start: Int32, verts: [Int32])] = [:]
        for (edge, start) in ring.edges {
            let a = start, b = MeshTopology.other(self, edge: edge, from: start)
            var verts: [Int32] = []
            for k in 1...cuts {
                var f = Float(k) / Float(cuts + 1)
                if cuts == 1 { f = 0.5 + 0.5 * max(-0.999, min(0.999, slide)) }
                verts.append(d.addVertex(simd_mix(positions[Int(a)], positions[Int(b)], SIMD3(repeating: f)), flags: Flag.select))
            }
            points[edge] = (a, verts)
        }
        // Where the k-th point of a cut edge is along it from `from` (0…1).
        func fraction(_ p: (start: Int32, verts: [Int32]), from: Int32, _ k: Int) -> Float {
            let f = cuts == 1 ? 0.5 + 0.5 * max(-0.999, min(0.999, slide)) : Float(k + 1) / Float(cuts + 1)
            return p.start == from ? f : (cuts == 1 ? 1 - f : f)
        }
        // A point's UV in a face: along the face's corners at the edge's two ends.
        func uvAlong(_ f: Int, _ a: Int32, _ b: Int32, _ x: Float) -> SIMD2<Float> {
            let r = corners(f)
            let ua = r.first { cornerVerts[$0] == a }.map { cornerUVs[$0] } ?? .zero
            let ub = r.first { cornerVerts[$0] == b }.map { cornerUVs[$0] } ?? .zero
            return simd_mix(ua, ub, SIMD2(repeating: x))
        }
        let ringFaces = Set(ring.faces)
        d.clearFaces()
        for f in 0..<faceCount {
            let r = corners(f)
            let flags = faceFlags[f] & ~Flag.select
            if ringFaces.contains(f) && faceSize(f) == 4 {
                // The quad a b c d with ring edges ab and cd: strips across from ab to dc.
                guard let k = r.first(where: { points[Int(cornerEdges[$0])] != nil && points[Int(cornerEdges[r.lowerBound + ($0 - r.lowerBound + 2) % 4])] != nil })
                else { d.addFace(faceVerts(f), uvs: Array(cornerUVs[r]), material: faceMaterial[f], set: faceSet[f], flags: flags); continue }
                let i = k - r.lowerBound
                let ca = r.lowerBound + i, cb = r.lowerBound + (i + 1) % 4, cc = r.lowerBound + (i + 2) % 4, cd = r.lowerBound + (i + 3) % 4
                let a = cornerVerts[ca], b = cornerVerts[cb], c = cornerVerts[cc], dv = cornerVerts[cd]
                let ab = points[Int(cornerEdges[ca])]!, dc = points[Int(cornerEdges[cc])]!
                // Points from a to b, and from d to c.
                let pab = ab.start == a ? ab.verts : ab.verts.reversed()
                let pdc = dc.start == dv ? dc.verts : dc.verts.reversed()
                let uab = (0..<cuts).map { k in simd_mix(cornerUVs[ca], cornerUVs[cb], SIMD2(repeating: fraction(ab, from: a, k))) }
                let udc = (0..<cuts).map { k in simd_mix(cornerUVs[cd], cornerUVs[cc], SIMD2(repeating: fraction(dc, from: dv, k))) }
                let rowA = [(a, cornerUVs[ca])] + zip(pab, uab).map { ($0, $1) } + [(b, cornerUVs[cb])]
                let rowD = [(dv, cornerUVs[cd])] + zip(pdc, udc).map { ($0, $1) } + [(c, cornerUVs[cc])]
                for s in 0...cuts {
                    d.addFace([rowA[s], rowA[s + 1], rowD[s + 1], rowD[s]].map { (v: $0.0, uv: $0.1) }, material: faceMaterial[f], set: faceSet[f], flags: flags)
                }
                continue
            }
            // Any other face: the new points in its cut edges.
            var out: [(v: Int32, uv: SIMD2<Float>)] = []
            for c in r {
                out.append((cornerVerts[c], cornerUVs[c]))
                let edge = Int(cornerEdges[c])
                guard let p = points[edge] else { continue }
                let a = cornerVerts[c], b = cornerVerts[nextCorner(c, face: f)]
                let along = p.start == a ? p.verts : p.verts.reversed()
                for (k, v) in along.enumerated() { out.append((v, uvAlong(f, a, b, fraction(p, from: a, k)))) }
            }
            d.addFace(out, material: faceMaterial[f], set: faceSet[f], flags: flags)
        }
        // Loose ring edges (none: rings run through faces).
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .vertex)
        self = mesh
    }
}
