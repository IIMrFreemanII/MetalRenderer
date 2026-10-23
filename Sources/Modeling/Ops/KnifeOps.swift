import Foundation
import simd

/// Knife (K): a line drawn over the view cuts the faces under it. Each stroke of the line is a plane (through the
/// eye and the stroke's two ends, or along the view in orthographic); where it crosses the edges of faces that face
/// the camera, between the stroke's ends on screen, the edges get a new vertex. A point placed inside a face is a new
/// vertex there. Followed along the line, the cut goes face by face: each stretch inside a face (from an edge or a
/// point, through the points in it, to an edge or a point) splits the face along it. A stretch that ends inside the
/// face goes on to the face's nearest corner (a face has no loose ends), as one that is wholly inside it does at
/// both ends.
extension EditMesh {
    /// What the line meets, in order along it: an edge it crosses (at `fraction` from the edge's first vertex), or a
    /// point inside a face (at `position`, in the mesh's space).
    private enum KnifeEvent {
        case crossing(edge: Int, fraction: Float)
        case inside(face: Int, position: SIMD3<Float>)
    }

    /// Cuts along `points` (view points, top left), with the object at `objectMatrix`. Returns how many faces split.
    @discardableResult
    package mutating func knife(_ points: [SIMD2<Float>], camera: ViewportCamera, viewSize: SIMD2<Float>, objectMatrix: float4x4,
                                throughAll: Bool = false) -> Int {
        guard points.count >= 2 else { return 0 }
        let world = positions.map { p -> SIMD3<Float> in let q = objectMatrix * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
        let screen = world.map { camera.project($0, size: viewSize) }
        let toLocal = objectMatrix.inverse
        // Faces that face the camera (all if cutting through).
        var front = [Bool](repeating: true, count: faceCount)
        for f in 0..<faceCount {
            if isHidden(face: f) { front[f] = false; continue }
            guard !throughAll else { continue }
            let c = corners(f).reduce(SIMD3<Float>.zero) { $0 + world[Int(cornerVerts[$1])] } / Float(faceSize(f))
            let toEye = camera.orthographic ? -camera.forward : camera.eye - c
            front[f] = simd_dot(worldNormal(f, world), toEye) > 0
        }
        let t = MeshTopology(self)
        // Along each stroke: the point it starts from if that is on a face, then the edges it crosses in order.
        var events: [KnifeEvent] = []
        var crossed = Set<Int>()
        for s in 0..<points.count {
            if let hit = faceUnder(points[s], camera: camera, viewSize: viewSize, world: world, front: front) {
                let q = toLocal * SIMD4(hit.point, 1)
                events.append(.inside(face: hit.face, position: SIMD3(q.x, q.y, q.z)))
            }
            guard s + 1 < points.count else { break }
            let p0 = points[s], p1 = points[s + 1]
            guard simd_distance(p0, p1) > 0.5 else { continue }
            let r0 = camera.ray(at: p0, size: viewSize), r1 = camera.ray(at: p1, size: viewSize)
            var n = camera.orthographic ? simd_cross(r1.origin - r0.origin, camera.forward) : simd_cross(r0.direction, r1.direction)
            guard simd_length(n) > 1e-9 else { continue }
            n = simd_normalize(n)
            let o = r0.origin
            let seg = p1 - p0, segLen2 = simd_length_squared(seg)
            var here: [(u: Float, edge: Int, fraction: Float)] = []
            for e in 0..<edgeCount where !crossed.contains(e) {
                guard t.faces(ofEdge: e).contains(where: { front[$0] }) else { continue }
                let a = Int(edges[e].x), b = Int(edges[e].y)
                let da = simd_dot(world[a] - o, n), db = simd_dot(world[b] - o, n)
                guard (da < 0) != (db < 0), abs(da - db) > 1e-12 else { continue }
                let f = da / (da - db)
                guard f > 1e-4, f < 1 - 1e-4 else { continue }
                // On screen, between the stroke's ends.
                guard let sa = screen[a], let sb = screen[b] else { continue }
                let x = simd_mix(SIMD2(sa.x, sa.y), SIMD2(sb.x, sb.y), SIMD2(repeating: f))
                let u = simd_dot(x - p0, seg) / segLen2
                guard u >= 0, u <= 1 else { continue }
                here.append((u, e, f))
            }
            for c in here.sorted(by: { $0.u < $1.u }) {
                crossed.insert(c.edge)
                events.append(.crossing(edge: c.edge, fraction: c.fraction))
            }
        }
        guard !crossed.isEmpty || events.count >= 2 else { return 0 }

        var d = draft()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        // The new vertices: one per crossed edge, one per point inside a face.
        var edgeVertex: [Int: Int32] = [:], crossing: [Int: Float] = [:]
        var eventVertex: [Int32] = []
        for ev in events {
            switch ev {
            case .crossing(let e, let f):
                let a = positions[Int(edges[e].x)], b = positions[Int(edges[e].y)]
                let v = d.addVertex(simd_mix(a, b, SIMD3(repeating: f)), flags: Flag.select)
                edgeVertex[e] = v
                crossing[e] = f
                eventVertex.append(v)
            case .inside(_, let p):
                eventVertex.append(d.addVertex(p, flags: Flag.select))
            }
        }
        func faces(of k: Int) -> [Int] {
            switch events[k] {
            case .crossing(let e, _): return t.faces(ofEdge: e).filter { front[$0] }
            case .inside(let f, _): return [f]
            }
        }
        func isInside(_ k: Int) -> Bool { if case .inside = events[k] { return true }; return false }
        // Each face's outline with the crossings in its edges: the pieces it is split into start from it.
        var pieces: [[[(v: Int32, uv: SIMD2<Float>)]]] = []
        for f in 0..<faceCount {
            var poly: [(v: Int32, uv: SIMD2<Float>)] = []
            for c in corners(f) {
                poly.append((cornerVerts[c], cornerUVs[c]))
                let e = Int(cornerEdges[c])
                if let nv = edgeVertex[e], let fr = crossing[e] {
                    let x = cornerVerts[c] == edges[e].x ? fr : 1 - fr
                    poly.append((nv, simd_mix(cornerUVs[c], cornerUVs[nextCorner(c, face: f)], SIMD2(repeating: x))))
                }
            }
            pieces.append([poly])
        }
        // The stretches: events one after another in the same face, through points inside it (an edge's crossing
        // ends one and starts the next).
        var stretches: [(face: Int, events: [Int])] = []
        var current: (face: Int, events: [Int])?
        for k in 0..<max(0, events.count - 1) {
            guard let f = faces(of: k).first(where: { faces(of: k + 1).contains($0) }) else {
                if let c = current { stretches.append(c) }
                current = nil
                continue
            }
            if var c = current, c.face == f, c.events.last == k, isInside(k) {
                c.events.append(k + 1)
                current = c
            } else {
                if let c = current { stretches.append(c) }
                current = (f, [k, k + 1])
            }
        }
        if let c = current { stretches.append(c) }
        var split = 0
        for s in stretches {
            let f = s.face
            // Its ends on the outline: a crossing's vertex, else (a point inside) the nearest corner.
            let inner = s.events.filter { isInside($0) }.map { eventVertex[$0] }
            let firstInside = isInside(s.events.first!), lastInside = isInside(s.events.last!)
            func nearestCorner(to v: Int32, not other: Int32?) -> Int32? {
                corners(f).map { cornerVerts[$0] }.filter { $0 != other }
                    .min { simd_distance(positions[Int($0)], d.positions[Int(v)]) < simd_distance(positions[Int($1)], d.positions[Int(v)]) }
            }
            let otherEnd: Int32? = lastInside ? nil : eventVertex[s.events.last!]
            guard let start = firstInside ? nearestCorner(to: inner.first!, not: otherEnd) : eventVertex[s.events.first!] else { continue }
            guard let end = lastInside ? nearestCorner(to: inner.last!, not: start) : eventVertex[s.events.last!], end != start else { continue }
            let path = inner.map { (v: $0, uv: uvAt(face: f, d.positions[Int($0)])) }
            // The piece with both ends on its outline, cut in two between them.
            guard let p = pieces[f].firstIndex(where: { piece in piece.contains { $0.v == start } && piece.contains { $0.v == end } }) else { continue }
            let loop = pieces[f][p]
            let i = loop.firstIndex { $0.v == start }!, j = loop.firstIndex { $0.v == end }!
            func around(_ from: Int, _ to: Int) -> [(v: Int32, uv: SIMD2<Float>)] {
                var out: [(v: Int32, uv: SIMD2<Float>)] = []
                var k = from
                while true {
                    out.append(loop[k])
                    if k == to { break }
                    k = (k + 1) % loop.count
                }
                return out
            }
            let one = around(i, j) + path.reversed(), two = around(j, i) + path
            guard one.count >= 3, two.count >= 3 else { continue }
            pieces[f].replaceSubrange(p...p, with: [one, two])
            split += 1
        }
        // A face crossed twice that no stretch went through (cutting through, its crossings aren't one after another
        // on screen): split straight between them.
        let cut = Set(stretches.map(\.face))
        for f in 0..<faceCount where front[f] && !cut.contains(f) && pieces[f].count == 1 {
            let loop = pieces[f][0]
            let at = loop.indices.filter { k in loop[k].v >= Int32(vertexCount) }
            guard at.count == 2 else { continue }
            let i = at[0], j = at[1]
            pieces[f] = [Array(loop[i...j]), Array(loop[j...] + loop[...i])]
            split += 1
        }
        d.clearFaces()
        for f in 0..<faceCount {
            for piece in pieces[f] { d.addFace(piece, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select) }
        }
        // Points inside a face that no stretch used stay out (a face has no loose vertices).
        var mesh = EditMesh(d)
        mesh.removeUnusedVertices(used: looseVertexMask(of: self, count: mesh.vertexCount))
        mesh.flushSelection(from: .vertex)
        self = mesh
        return split
    }

    /// A face's normal from world positions (its corners' cross products summed).
    private func worldNormal(_ f: Int, _ world: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>.zero
        let r = corners(f)
        var prev = world[Int(cornerVerts[r.upperBound - 1])]
        for k in r {
            let p = world[Int(cornerVerts[k])]
            n += simd_cross(prev, p)
            prev = p
        }
        return n
    }

    /// The nearest of `front`'s faces under a view point, and where on it (world space).
    private func faceUnder(_ p: SIMD2<Float>, camera: ViewportCamera, viewSize: SIMD2<Float>, world: [SIMD3<Float>],
                           front: [Bool]) -> (face: Int, point: SIMD3<Float>)? {
        let ray = camera.ray(at: p, size: viewSize)
        var best: (face: Int, point: SIMD3<Float>, t: Float)?
        for f in 0..<faceCount where front[f] {
            let len = simd_length(worldNormal(f, world))
            guard len > 1e-12 else { continue }
            let n = worldNormal(f, world) / len
            let o = world[Int(cornerVerts[corners(f).lowerBound])]
            let den = simd_dot(ray.direction, n)
            guard abs(den) > 1e-9 else { continue }
            let tt = simd_dot(o - ray.origin, n) / den
            guard tt > 0, tt < (best?.t ?? .infinity) else { continue }
            let x = ray.origin + ray.direction * tt
            // Inside the polygon, in its plane (and not on its outline, where a crossing is).
            let u = simd_normalize(abs(n.y) < 0.9 ? simd_cross(n, [0, 1, 0]) : simd_cross(n, [1, 0, 0])), v = simd_cross(n, u)
            let poly = corners(f).map { c -> SIMD2<Float> in let q = world[Int(cornerVerts[c])] - x; return SIMD2(simd_dot(q, u), simd_dot(q, v)) }
            var inside = false, nearEdge = Float.infinity
            for k in poly.indices {
                let a = poly[k], b = poly[(k + 1) % poly.count]
                if (a.y > 0) != (b.y > 0), a.x + (0 - a.y) / (b.y - a.y) * (b.x - a.x) > 0 { inside.toggle() }
                let ab = b - a, w = max(0, min(1, simd_dot(-a, ab) / max(simd_length_squared(ab), 1e-20)))
                nearEdge = min(nearEdge, simd_length(a + ab * w))
            }
            let size = poly.reduce(0) { max($0, simd_length($1)) }
            guard inside, nearEdge > size * 1e-3 else { continue }
            best = (f, x, tt)
        }
        return best.map { ($0.face, $0.point) }
    }

    /// The UV at a point in face `f` (the mesh's space): from the triangle of its fan the point is in.
    func uvAt(face f: Int, _ p: SIMD3<Float>) -> SIMD2<Float> {
        let r = corners(f)
        var best: (uv: SIMD2<Float>, score: Float)?
        for k in (r.lowerBound + 1)..<(r.upperBound - 1) {
            let a = positions[Int(cornerVerts[r.lowerBound])], b = positions[Int(cornerVerts[k])], c = positions[Int(cornerVerts[k + 1])]
            let v0 = b - a, v1 = c - a, v2 = p - a
            let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1), d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
            let den = d00 * d11 - d01 * d01
            guard abs(den) > 1e-20 else { continue }
            let y = (d11 * d20 - d01 * d21) / den, z = (d00 * d21 - d01 * d20) / den, x = 1 - y - z
            let score = min(x, y, z)
            if score > (best?.score ?? -.infinity) {
                best = (cornerUVs[r.lowerBound] * x + cornerUVs[k] * y + cornerUVs[k + 1] * z, score)
            }
        }
        return best?.uv ?? cornerUVs[r.lowerBound]
    }
}
