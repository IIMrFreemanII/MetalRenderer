import Foundation
import simd

/// Knife (K): a line drawn over the view cuts the faces under it. Each stroke of the line is a plane (through the
/// eye and the stroke's two ends, or along the view in orthographic); where it crosses the edges of faces that face
/// the camera, between the stroke's ends on screen, the edges get a new vertex, and a face crossed twice is split in
/// two between them.
extension EditMesh {
    /// Cuts along `points` (view points, top left), with the object at `objectMatrix`. Returns how many faces split.
    @discardableResult
    package mutating func knife(_ points: [SIMD2<Float>], camera: ViewportCamera, viewSize: SIMD2<Float>, objectMatrix: float4x4,
                                throughAll: Bool = false) -> Int {
        guard points.count >= 2 else { return 0 }
        let world = positions.map { p -> SIMD3<Float> in let q = objectMatrix * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
        let screen = world.map { camera.project($0, size: viewSize) }
        // Faces that face the camera (all if cutting through).
        var front = [Bool](repeating: true, count: faceCount)
        if !throughAll {
            for f in 0..<faceCount {
                var n = SIMD3<Float>.zero, c = SIMD3<Float>.zero
                let r = corners(f)
                var prev = world[Int(cornerVerts[r.upperBound - 1])]
                for k in r {
                    let p = world[Int(cornerVerts[k])]
                    n += simd_cross(prev, p)
                    c += p
                    prev = p
                }
                c /= Float(r.count)
                let toEye = camera.orthographic ? -camera.forward : camera.eye - c
                front[f] = simd_dot(n, toEye) > 0 && !isHidden(face: f)
            }
        }
        // Crossings: edge → fraction from its first vertex.
        var crossing: [Int: Float] = [:]
        let t = MeshTopology(self)
        for s in 0..<(points.count - 1) {
            let p0 = points[s], p1 = points[s + 1]
            guard simd_distance(p0, p1) > 0.5 else { continue }
            let r0 = camera.ray(at: p0, size: viewSize), r1 = camera.ray(at: p1, size: viewSize)
            var n = camera.orthographic ? simd_cross(r1.origin - r0.origin, camera.forward) : simd_cross(r0.direction, r1.direction)
            guard simd_length(n) > 1e-9 else { continue }
            n = simd_normalize(n)
            let o = r0.origin
            let seg = p1 - p0, segLen2 = simd_length_squared(seg)
            for e in 0..<edgeCount where crossing[e] == nil {
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
                crossing[e] = f
            }
        }
        guard !crossing.isEmpty else { return 0 }
        var d = draft()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        var newVertex: [Int: Int32] = [:]
        for (e, f) in crossing {
            let a = positions[Int(edges[e].x)], b = positions[Int(edges[e].y)]
            newVertex[e] = d.addVertex(simd_mix(a, b, SIMD3(repeating: f)), flags: Flag.select)
        }
        d.clearFaces()
        var split = 0
        for f in 0..<faceCount {
            var poly: [(v: Int32, uv: SIMD2<Float>)] = []
            var cutAt: [Int] = []
            for c in corners(f) {
                poly.append((cornerVerts[c], cornerUVs[c]))
                let e = Int(cornerEdges[c])
                if let nv = newVertex[e], let fr = crossing[e] {
                    let a = cornerVerts[c]
                    let x = a == edges[e].x ? fr : 1 - fr
                    let uv = simd_mix(cornerUVs[c], cornerUVs[nextCorner(c, face: f)], SIMD2(repeating: x))
                    cutAt.append(poly.count)
                    poly.append((nv, uv))
                }
            }
            if cutAt.count == 2 && front[f] {
                let i = cutAt[0], j = cutAt[1]
                d.addFace(Array(poly[i...j]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
                d.addFace(Array(poly[j...] + poly[...i]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
                split += 1
            } else {
                d.addFace(poly, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
            }
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .vertex)
        self = mesh
        return split
    }
}
