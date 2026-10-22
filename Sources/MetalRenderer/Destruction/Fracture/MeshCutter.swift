import EngineCore
import Foundation
import Plants
import simd

/// A triangle mesh's piece inside a convex cell (a fractured statue's, Scene+Fracture.swift): its triangles clipped
/// by the cell's planes (their normals, texture coordinates and materials kept), and caps on the cell's cut faces
/// where the mesh's inside is: marching squares of the mesh's distance on each face's plane, the squares clipped to
/// the face. Distances, not loops of cut edges: a generated model is rarely closed (open patches, shells inside
/// shells), and a cap made from its distance doesn't care.
struct MeshCutter {
    /// A mesh in one space: per vertex its place, normal and texture coordinate; per triangle its material offset.
    struct Mesh {
        package var positions: [SIMD3<Float>] = []
        package var normals: [SIMD3<Float>] = []
        package var uvs: [SIMD2<Float>] = []
        package var indices: [UInt32] = []
        package var materials: [UInt8] = []
        package var triangleCount: Int { indices.count / 3 }

        package var bounds: AABB {
            var b = AABB()
            for p in positions { b.grow(p) }
            return b
        }

        /// A vertex at the end, its index.
        package mutating func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>) -> UInt32 {
            positions.append(p)
            normals.append(n)
            uvs.append(uv)
            return UInt32(positions.count - 1)
        }
    }

    let mesh: Mesh
    /// The mesh's distance (negative inside): its baked grid's.
    let inside: (SIMD3<Float>) -> Float
    /// Each triangle's box, for the cells to skip what they don't meet.
    private let boxes: [AABB]

    package init(_ mesh: Mesh, inside: @escaping (SIMD3<Float>) -> Float) {
        self.mesh = mesh
        self.inside = inside
        boxes = (0..<mesh.triangleCount).map { t in
            var b = AABB()
            for k in 0..<3 { b.grow(mesh.positions[Int(mesh.indices[3 * t + k])]) }
            return b
        }
    }

    private struct Corner {
        var p: SIMD3<Float>
        var n: SIMD3<Float>
        var uv: SIMD2<Float>
        func lerp(_ o: Corner, _ t: Float) -> Corner {
            Corner(p: p + (o.p - p) * t, n: n + (o.n - n) * t, uv: uv + (o.uv - uv) * t)
        }
    }

    /// The piece inside `cell`: the mesh's triangles there, and caps on the faces whose tag `capped` says, with
    /// material offset `interior` and texture coordinates `uvScale` per metre across them. `cellSize`: the caps'
    /// squares' size (m).
    func piece(_ cell: ConvexCell, capped: (Int32) -> Bool, interior: UInt8, uvScale: Float = 1, cellSize: Float) -> Mesh {
        var out = Mesh()
        let box = cell.bounds
        let planes = cell.faces.map(\.plane)
        let eps = max(cell.size * 1e-5, 1e-6)
        for t in 0..<mesh.triangleCount {
            let b = boxes[t]
            guard b.lo.x <= box.hi.x + eps, b.hi.x >= box.lo.x - eps, b.lo.y <= box.hi.y + eps, b.hi.y >= box.lo.y - eps,
                  b.lo.z <= box.hi.z + eps, b.hi.z >= box.lo.z - eps else { continue }
            var poly = (0..<3).map { k -> Corner in
                let i = Int(mesh.indices[3 * t + k])
                return Corner(p: mesh.positions[i], n: mesh.normals[i], uv: mesh.uvs[i])
            }
            for plane in planes where poly.count >= 3 {
                let n = SIMD3(plane.x, plane.y, plane.z)
                var next: [Corner] = []
                for i in poly.indices {
                    let a = poly[i], c = poly[(i + 1) % poly.count]
                    let sa = dot(n, a.p) - plane.w, sc = dot(n, c.p) - plane.w
                    if sa <= 0 { next.append(a) }
                    if (sa < 0 && sc > 0) || (sa > 0 && sc < 0) { next.append(a.lerp(c, sa / (sa - sc))) }
                }
                poly = next
            }
            guard poly.count >= 3 else { continue }
            let first = out.add(poly[0].p, poly[0].n, poly[0].uv)
            var previous = out.add(poly[1].p, poly[1].n, poly[1].uv)
            for k in 2..<poly.count {
                let v = out.add(poly[k].p, poly[k].n, poly[k].uv)
                out.indices += [first, previous, v]
                out.materials.append(mesh.materials[t])
                previous = v
            }
        }
        for face in cell.faces where capped(face.tag) { cap(face, into: &out, interior: interior, uvScale: uvScale, size: cellSize) }
        return out
    }

    /// Face `face`'s cap: where the mesh's inside meets it.
    private func cap(_ face: ConvexCell.Face, into out: inout Mesh, interior: UInt8, uvScale: Float, size: Float) {
        let n = SIMD3(face.plane.x, face.plane.y, face.plane.z)
        let (u, v) = ConvexCell.basis(n)
        let origin = face.polygon[0]
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for p in face.polygon {
            let q = SIMD2(dot(p - origin, u), dot(p - origin, v))
            lo = simd_min(lo, q)
            hi = simd_max(hi, q)
        }
        let extent = hi - lo
        let h = max(size, simd_reduce_max(extent) / 96)
        let nx = max(Int((extent.x / h).rounded(.up)), 1), ny = max(Int((extent.y / h).rounded(.up)), 1)
        func point(_ i: Int, _ j: Int) -> SIMD3<Float> { origin + u * (lo.x + Float(i) * h) + v * (lo.y + Float(j) * h) }
        // The distance at the grid's points, a hair inside the cell (the face is the cell's boundary).
        var d = [Float](repeating: 0, count: (nx + 1) * (ny + 1))
        for j in 0...ny { for i in 0...nx { d[j * (nx + 1) + i] = inside(point(i, j) - n * (h * 0.01)) } }
        // The face's edges as half-planes in its plane (inward normals), to clip each square's inside by.
        var edges: [(SIMD3<Float>, Float)] = []
        for k in face.polygon.indices {
            let a = face.polygon[k], b = face.polygon[(k + 1) % face.polygon.count]
            let inward = cross(n, b - a)
            let l = length(inward)
            guard l > 0 else { continue }
            edges.append((-inward / l, dot(-inward / l, a)))
        }
        for j in 0..<ny {
            for i in 0..<nx {
                let corners = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)]   // counter-clockwise about n
                let values = corners.map { d[$0.1 * (nx + 1) + $0.0] }
                guard values.contains(where: { $0 < 0 }) else { continue }
                // The square less what is outside the mesh (marching squares as a clip: corners in, crossings).
                var poly: [SIMD3<Float>] = []
                for k in 0..<4 {
                    let a = point(corners[k].0, corners[k].1), b = point(corners[(k + 1) % 4].0, corners[(k + 1) % 4].1)
                    let va = values[k], vb = values[(k + 1) % 4]
                    if va < 0 { poly.append(a) }
                    if (va < 0) != (vb < 0) { poly.append(a + (b - a) * (va / (va - vb))) }
                }
                for (en, ed) in edges where poly.count >= 3 { poly = ConvexCell.clip(poly, normal: en, offset: ed) }
                guard poly.count >= 3 else { continue }
                func vertex(_ p: SIMD3<Float>) -> UInt32 {
                    out.add(p, n, SIMD2(dot(p, u), dot(p, v)) * uvScale)
                }
                let first = vertex(poly[0])
                var previous = vertex(poly[1])
                for k in 2..<poly.count {
                    let w = vertex(poly[k])
                    out.indices += [first, previous, w]
                    out.materials.append(interior)
                    previous = w
                }
            }
        }
    }
}
