import Foundation
import simd

/// Bevel (Ctrl-B edges, Ctrl-Shift-B vertices), and the Bevel modifier: each selected edge becomes a strip of
/// `segments` faces of `width` either side, its ends closed where they meet.
///
/// Round a vertex with beveled edges each face's corner is replaced: by a point inside the face `width` from both
/// edges if both are beveled; by a point on the face's other edge if one is (an edge that isn't beveled gets one point
/// near the vertex, shared by its two faces); the vertex itself stays only where a face touches no beveled edge and
/// one of its edges got no point. The corners round the vertex, in order, close the hole with one face (a cube's
/// corner: a triangle). With more segments the strip's ends are arcs (a quadratic curve round the old corner), and
/// every face along an arc's two ends takes its points.
extension EditMesh {
    package mutating func bevelEdges(width: Float, segments: Int = 1, onlySelected: Bool = true, angleLimit: Float? = nil) {
        let t = MeshTopology(self)
        let fn = faceNormals()
        var beveled = [Bool](repeating: false, count: edgeCount)
        for e in 0..<edgeCount where t.faceCount(ofEdge: e) == 2 {
            if onlySelected && !isSelected(edge: e) { continue }
            if let limit = angleLimit {
                let fs = t.faces(ofEdge: e)
                let angle = acos(max(-1, min(1, simd_dot(fn[fs[0]], fn[fs[1]]))))
                if angle < limit { continue }
            }
            beveled[e] = true
        }
        guard beveled.contains(true), width > 0 else { return }
        bevel(beveled: beveled, vertexOnly: [], width: width, segments: max(1, segments), topology: t, faceNormals: fn)
    }

    package mutating func bevelVertices(width: Float, segments: Int = 1) {
        let t = MeshTopology(self)
        let verts = (0..<vertexCount).filter { isSelected(vertex: $0) && !t.corners(ofVertex: $0).isEmpty }
        guard !verts.isEmpty, width > 0 else { return }
        bevel(beveled: [Bool](repeating: false, count: edgeCount), vertexOnly: Set(verts), width: width, segments: max(1, segments),
              topology: t, faceNormals: faceNormals())
    }

    private mutating func bevel(beveled: [Bool], vertexOnly: Set<Int>, width w: Float, segments s: Int, topology t: MeshTopology,
                                faceNormals fn: [SIMD3<Float>]) {
        var d = draft()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        // Vertices the bevel touches.
        var touched = [Bool](repeating: false, count: vertexCount)
        for e in 0..<edgeCount where beveled[e] { touched[Int(edges[e].x)] = true; touched[Int(edges[e].y)] = true }
        for v in vertexOnly { touched[v] = true }
        func inEdge(_ c: Int) -> Int { Int(cornerEdges[prevCorner(c, face: Int(t.cornerFace[c]))]) }
        func outEdge(_ c: Int) -> Int { Int(cornerEdges[c]) }
        func dir(_ v: Int, _ e: Int) -> SIMD3<Float> {
            let o = MeshTopology.other(self, edge: e, from: Int32(v))
            let l = simd_distance(positions[Int(o)], positions[v])
            return l > 0 ? (positions[Int(o)] - positions[v]) / l : .zero
        }
        func cornerSin(_ c: Int, _ v: Int) -> Float {
            let s = simd_length(simd_cross(dir(v, inEdge(c)), dir(v, outEdge(c))))
            return max(s, 0.2)
        }
        // Points on edges that aren't beveled: (vertex, edge) → new vertex; summed distances to average.
        var edgePoint: [Int: [Int: Int32]] = [:]           // v → edge → vertex
        var edgeDistance: [Int: [Int: (sum: Float, n: Int)]] = [:]
        var rep: [Int: [(v: Int32, uv: SIMD2<Float>)]] = [:]   // corner → what replaces it
        var fans: [Int: (corners: [Int], closed: Bool)] = [:]
        for v in 0..<vertexCount where touched[v] {
            let fan = fan(v, topology: t)
            fans[v] = fan
            let all = vertexOnly.contains(v)
            for c in t.corners(ofVertex: v).map({ Int($0) }) {
                let ei = inEdge(c), eo = outEdge(c)
                let bi = beveled[ei], bo = beveled[eo]
                if all || (bi && !bo) || (!bi && bo) {
                    let sn = all ? 1 : cornerSin(c, v)
                    for e in all ? [ei, eo] : [bi ? eo : ei] {
                        var cur = edgeDistance[v, default: [:]][e] ?? (0, 0)
                        cur.sum += w / sn
                        cur.n += 1
                        edgeDistance[v, default: [:]][e] = cur
                    }
                }
            }
        }
        // Make the edge points, never past the middle of their edge.
        for (v, es) in edgeDistance {
            for (e, sd) in es {
                let o = Int(MeshTopology.other(self, edge: e, from: Int32(v)))
                let len = simd_distance(positions[o], positions[v])
                let limit = touched[o] ? len * 0.48 : len * 0.95
                let dist = min(sd.sum / Float(sd.n), limit)
                edgePoint[v, default: [:]][e] = d.addVertex(positions[v] + dir(v, e) * dist, flags: Flag.select)
            }
        }
        // Each corner's replacement, in the face's order.
        for v in 0..<vertexCount where touched[v] {
            let all = vertexOnly.contains(v)
            for c in t.corners(ofVertex: v).map({ Int($0) }) {
                let f = Int(t.cornerFace[c])
                let ei = inEdge(c), eo = outEdge(c)
                let uv = cornerUVs[c]
                let uvPrev = cornerUVs[prevCorner(c, face: f)], uvNext = cornerUVs[nextCorner(c, face: f)]
                func uvOn(_ e: Int, toward other: SIMD2<Float>, _ p: Int32) -> SIMD2<Float> {
                    let len = max(edgeLength(e), 1e-9)
                    let x = simd_distance(d.positions[Int(p)], positions[v]) / len
                    return simd_mix(uv, other, SIMD2(repeating: x))
                }
                if !all && beveled[ei] && beveled[eo] {
                    let sn = cornerSin(c, v)
                    let p = positions[v] + (dir(v, ei) + dir(v, eo)) * (w / sn)
                    rep[c] = [(d.addVertex(p, flags: Flag.select), uv)]
                    continue
                }
                var r: [(v: Int32, uv: SIMD2<Float>)] = []
                let pi = beveled[ei] ? nil : edgePoint[v]?[ei], po = beveled[eo] ? nil : edgePoint[v]?[eo]
                if let pi { r.append((pi, uvOn(ei, toward: uvPrev, pi))) }
                if !all && (pi == nil || po == nil) && !beveled[ei] && !beveled[eo] { r.append((Int32(v), uv)) }
                if let po { r.append((po, uvOn(eo, toward: uvNext, po))) }
                if r.isEmpty { r = [(Int32(v), uv)] }
                rep[c] = r
            }
        }
        // Each beveled edge's ends: the two sides' points and the arcs between them.
        var arcs: [SIMD2<Int32>: [(v: Int32, uv: SIMD2<Float>)]] = [:]   // (from, to) → the points between, from → to
        func arc(_ x: (v: Int32, uv: SIMD2<Float>), _ y: (v: Int32, uv: SIMD2<Float>), round v: Int) -> [(v: Int32, uv: SIMD2<Float>)] {
            if x.v == y.v { return [] }
            if let a = arcs[SIMD2(x.v, y.v)] { return a }
            if let a = arcs[SIMD2(y.v, x.v)] { return a.reversed() }
            var out: [(v: Int32, uv: SIMD2<Float>)] = []
            let px = d.positions[Int(x.v)], py = d.positions[Int(y.v)], pc = positions[v]
            for k in 1..<s {
                let u = Float(k) / Float(s)
                let p = (1 - u) * (1 - u) * px + 2 * u * (1 - u) * pc + u * u * py
                out.append((d.addVertex(p, flags: Flag.select), simd_mix(x.uv, y.uv, SIMD2(repeating: u))))
            }
            arcs[SIMD2(x.v, y.v)] = out
            return out
        }
        var strips: [(f: Int, corners: [(v: Int32, uv: SIMD2<Float>)])] = []
        for e in 0..<edgeCount where beveled[e] {
            let cs = t.corners(ofEdge: e).map { Int($0) }
            guard cs.count == 2 else { continue }
            // F has a → b at corner cs[0]; G the other way.
            let cF = cs[0], cG = cs[1]
            let fF = Int(t.cornerFace[cF]), fG = Int(t.cornerFace[cG])
            let a = Int(cornerVerts[cF]), b = Int(cornerVerts[nextCorner(cF, face: fF)])
            let cFb = nextCorner(cF, face: fF)
            guard cornerVerts[cG] == Int32(b) else { continue }   // faces disagree on front: leave it
            let cGa = nextCorner(cG, face: fG)
            guard let rFa = rep[cF], let rFb = rep[cFb], let rGb = rep[cG], let rGa = rep[cGa] else { continue }
            let aF = rFa.last!, bF = rFb.first!, bG = rGb.last!, aG = rGa.first!
            let rowA = [aF] + arc(aF, aG, round: a) + [aG]
            let rowB = [bF] + arc(bF, bG, round: b) + [bG]
            for k in 0..<s {
                strips.append((fF, [rowB[k], rowA[k], rowA[k + 1], rowB[k + 1]]))
            }
        }
        // Insert arcs into a polygon wherever two consecutive points are an arc's ends.
        func withArcs(_ poly: [(v: Int32, uv: SIMD2<Float>)]) -> [(v: Int32, uv: SIMD2<Float>)] {
            guard s > 1 else { return poly }
            var out: [(v: Int32, uv: SIMD2<Float>)] = []
            for i in 0..<poly.count {
                let x = poly[i], y = poly[(i + 1) % poly.count]
                out.append(x)
                if let a = arcs[SIMD2(x.v, y.v)] { out += a } else if let a = arcs[SIMD2(y.v, x.v)] { out += a.reversed() }
            }
            return out
        }
        func dedup(_ poly: [(v: Int32, uv: SIMD2<Float>)]) -> [(v: Int32, uv: SIMD2<Float>)] {
            var out: [(v: Int32, uv: SIMD2<Float>)] = []
            for p in poly where out.last?.v != p.v { out.append(p) }
            while out.count > 1 && out.first!.v == out.last!.v { out.removeLast() }
            return out
        }
        d.clearFaces()
        for f in 0..<faceCount {
            var poly: [(v: Int32, uv: SIMD2<Float>)] = []
            for c in corners(f) {
                if let r = rep[c] { poly += r } else { poly.append((cornerVerts[c], cornerUVs[c])) }
            }
            poly = withArcs(dedup(poly))
            if poly.count >= 3 { d.addFace(poly, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select) }
        }
        for strip in strips {
            d.addFace(strip.corners, material: faceMaterial[strip.f], set: faceSet[strip.f], flags: (faceFlags[strip.f] & ~Flag.select) | Flag.select)
        }
        // The holes round the vertices: one face each, turned to face out.
        for (v, fan) in fans where fan.closed {
            var poly: [(v: Int32, uv: SIMD2<Float>)] = []
            for c in fan.corners { poly += rep[c] ?? [] }
            poly = withArcs(dedup(poly))
            guard poly.count >= 3, Set(poly.map(\.v)).count == poly.count else { continue }
            // Its normal against the vertex's.
            var n = SIMD3<Float>.zero
            for c in fan.corners { n += fn[Int(t.cornerFace[c])] }
            var pn = SIMD3<Float>.zero
            for i in 0..<poly.count {
                let p = d.positions[Int(poly[i].v)], q = d.positions[Int(poly[(i + 1) % poly.count].v)]
                pn += simd_cross(p, q)
            }
            if simd_dot(pn, n) < 0 { poly.reverse() }
            let f = Int(t.cornerFace[fan.corners[0]])
            d.addFace(poly, material: faceMaterial[f], set: faceSet[f], flags: (faceFlags[f] & ~Flag.select) | Flag.select)
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        // The old vertices the bevel replaced.
        mesh.removeUnusedVertices(used: looseVertexMask(of: self, count: mesh.vertexCount))
        self = mesh
    }
}
