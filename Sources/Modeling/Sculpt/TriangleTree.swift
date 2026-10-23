import EngineCore
import Foundation
import simd

/// A tree over triangles for distance queries: the nearest point on the surface to a point, its signed distance
/// (outside positive, by the smooth normal there), and the gradient (the unit direction from the nearest point),
/// as voxel remeshing and the voxel boolean sample them.
package final class TriangleTree {
    package let positions: [SIMD3<Float>]
    package let normals: [SIMD3<Float>]
    package let indices: [UInt32]
    private var nodes: [SculptNode]
    private var order: [Int32]

    package init(positions: [SIMD3<Float>], indices: [UInt32]) {
        self.positions = positions
        self.indices = indices
        let nt = indices.count / 3
        var centroid = [SIMD3<Float>](repeating: .zero, count: nt)
        var vn = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in 0..<nt {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
            centroid[t] = (a + b + c) / 3
            let n = simd_cross(b - a, c - a)
            for k in 0..<3 { vn[Int(indices[3 * t + k])] += n }
        }
        normals = vn.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        (nodes, order) = SculptMesh.buildTree(centroid, leafSize: 4)
        // Boxes, children before parents (they come after them in the array).
        for n in stride(from: nodes.count - 1, through: 0, by: -1) {
            if nodes[n].isLeaf {
                var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
                for k in Int(nodes[n].triStart)..<Int(nodes[n].triStart + nodes[n].triCount) {
                    let t = Int(order[k])
                    for j in 0..<3 { let p = positions[Int(indices[3 * t + j])]; lo = simd_min(lo, p); hi = simd_max(hi, p) }
                }
                nodes[n].lo = lo
                nodes[n].hi = hi
            } else {
                let l = Int(nodes[n].left), r = Int(nodes[n].right)
                nodes[n].lo = simd_min(nodes[l].lo, nodes[r].lo)
                nodes[n].hi = simd_max(nodes[l].hi, nodes[r].hi)
            }
        }
    }

    package var isEmpty: Bool { indices.isEmpty }

    /// The nearest point on the surface: its triangle, position and barycentric weights.
    package func nearest(_ p: SIMD3<Float>) -> (triangle: Int, point: SIMD3<Float>, bary: SIMD3<Float>, distance2: Float) {
        var best = (triangle: -1, point: p, bary: SIMD3<Float>(1, 0, 0), distance2: Float.infinity)
        guard !nodes.isEmpty, !indices.isEmpty else { return best }
        var stack = [Int32](repeating: 0, count: 64)
        var top = 1
        stack[0] = 0
        while top > 0 {
            top -= 1
            let n = Int(stack[top])
            let node = nodes[n]
            let e = simd_max(simd_max(node.lo - p, p - node.hi), .zero)
            guard simd_length_squared(e) < best.distance2 else { continue }
            if node.isLeaf {
                for k in Int(node.triStart)..<Int(node.triStart + node.triCount) {
                    let t = Int(order[k])
                    let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
                    let (q, w) = TriangleTree.closest(p, a, b, c)
                    let d2 = simd_length_squared(p - q)
                    if d2 < best.distance2 { best = (t, q, w, d2) }
                }
            } else if top + 2 <= stack.count {
                // The nearer child last, so it's taken first.
                let l = nodes[Int(node.left)], r = nodes[Int(node.right)]
                let dl = simd_length_squared(simd_max(simd_max(l.lo - p, p - l.hi), .zero))
                let dr = simd_length_squared(simd_max(simd_max(r.lo - p, p - r.hi), .zero))
                if dl < dr { stack[top] = node.right; stack[top + 1] = node.left } else { stack[top] = node.left; stack[top + 1] = node.right }
                top += 2
            } else {
                stack.append(node.left)
                stack.append(node.right)
                top = stack.count
            }
        }
        return best
    }

    /// The signed distance (negative inside) and its gradient.
    package func signedDistance(_ p: SIMD3<Float>) -> (d: Float, gradient: SIMD3<Float>) {
        let h = nearest(p)
        guard h.triangle >= 0 else { return (.infinity, SIMD3(0, 1, 0)) }
        let t = h.triangle
        let n = normals[Int(indices[3 * t])] * h.bary.x + normals[Int(indices[3 * t + 1])] * h.bary.y + normals[Int(indices[3 * t + 2])] * h.bary.z
        let off = p - h.point
        let d = h.distance2.squareRoot()
        let inside = simd_dot(off, n) < 0
        var g = d > 1e-9 ? off / d : simd_normalize(n)
        if inside { g = -g }
        return (inside ? -d : d, g)
    }

    /// The point of triangle abc nearest p, and its barycentric weights (Ericson's Real-Time Collision Detection).
    @inline(__always) package static func closest(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>)
        -> (SIMD3<Float>, SIMD3<Float>) {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (a, SIMD3(1, 0, 0)) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (b, SIMD3(0, 1, 0)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return (a + ab * v, SIMD3(1 - v, v, 0))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (c, SIMD3(0, 0, 1)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return (a + ac * w, SIMD3(1 - w, 0, w))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (b + (c - b) * w, SIMD3(0, 1 - w, w))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return (a + ab * v + ac * w, SIMD3(1 - v - w, v, w))
    }
}

/// Voxel remesh (Ctrl-R in sculpt mode, the Remesh modifier's voxel mode) and the voxel boolean: a surface rebuilt as
/// quads of about `voxel` a side from a distance field (surface nets on a sparse grid round the surface).
package enum VoxelRemesh {
    /// The surface where `field` is zero, inside the box, as quads. `field` gives the signed distance and gradient.
    package static func surface(lo: SIMD3<Float>, hi: SIMD3<Float>, voxel: Float, field: @escaping (SIMD3<Float>) -> (Float, SIMD3<Float>))
        -> EditMesh {
        let size = max(voxel, 1e-5)
        let start = lo - size * 2
        let counts = SIMD3<Int>(((hi - lo) / size).rounded(.up)) &+ 5
        let (p, ix) = SurfaceNetsBridge.sparseMesh(lo: start, size: size, counts: counts, field: field)
        // Two triangles a quad (as the nets make them): quads again.
        var d = EditMesh.Draft()
        d.positions = p
        d.vertFlags = [UInt8](repeating: 0, count: p.count)
        var q = 0
        while q + 6 <= ix.count {
            let t = (0..<6).map { Int32(ix[q + $0]) }
            if t[3] == t[0] && t[4] == t[2] {
                d.addFace([t[0], t[1], t[2], t[5]], flags: EditMesh.Flag.smooth)        // (a b c)(a c e)
            } else if t[3] == t[0] && t[5] == t[1] {
                d.addFace([t[0], t[4], t[1], t[2]], flags: EditMesh.Flag.smooth)        // (a c b)(a e c)
            } else {
                d.addFace([t[0], t[1], t[2]], flags: EditMesh.Flag.smooth)
                d.addFace([t[3], t[4], t[5]], flags: EditMesh.Flag.smooth)
            }
            q += 6
        }
        var m = EditMesh(d)
        m.removeUnusedVertices()
        return m
    }

    /// A mesh's surface rebuilt at `voxel` (closed meshes: the inside is by their normals).
    package static func remesh(positions: [SIMD3<Float>], indices: [UInt32], voxel: Float) -> EditMesh {
        let tree = TriangleTree(positions: positions, indices: indices)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return surface(lo: lo, hi: hi, voxel: voxel) { p in tree.signedDistance(p) }
    }
}

/// Surface nets with a field that gives the distance and its gradient from one query.
enum SurfaceNetsBridge {
    static func sparseMesh(lo: SIMD3<Float>, size: Float, counts: SIMD3<Int>, field: @escaping (SIMD3<Float>) -> (Float, SIMD3<Float>))
        -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        SurfaceNets.sparseMesh(lo: lo, size: size, counts: counts, distance: { field($0).0 }, gradient: { field($0).1 })
    }
}
