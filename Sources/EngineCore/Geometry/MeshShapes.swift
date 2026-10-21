import Foundation
import ImageIO
import simd

/// A mesh as positions, normals and triangles' indices.
package typealias MeshGeometry = (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])

/// Unit meshes the scenes and the builders make shapes from (Scene.quadMesh and the rest forward here).
package enum MeshShapes {

    /// Unit quad in the XZ plane, facing +Y.
    package static func quadMesh() -> MeshGeometry {
        let p: [SIMD3<Float>] = [[-0.5, 0, -0.5], [0.5, 0, -0.5], [0.5, 0, 0.5], [-0.5, 0, 0.5]]
        let n = [SIMD3<Float>](repeating: [0, 1, 0], count: 4)
        return (p, n, [0, 1, 2, 0, 2, 3])
    }

    /// Unit cube centered at the origin with flat face normals.
    package static func cubeMesh() -> MeshGeometry {
        let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            ([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [0, 1, 0], [1, 0, 0]),
        ]
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        for f in faces {
            let base = UInt32(p.count)
            let c = f.n * 0.5
            p += [c - f.u * 0.5 - f.v * 0.5, c + f.u * 0.5 - f.v * 0.5,
                  c + f.u * 0.5 + f.v * 0.5, c - f.u * 0.5 + f.v * 0.5]
            n += [SIMD3<Float>](repeating: f.n, count: 4)
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (p, n, idx)
    }

    /// Capsule along Y: a cylinder of `halfLength` either side of the origin with hemispherical caps, smooth normals.
    package static func capsuleMesh(halfLength: Float, radius: Float, segments: Int = 24, rings: Int = 6) -> MeshGeometry {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        // Rows from the bottom pole to the top pole; the two equator rows sit at -halfLength and +halfLength.
        var rows: [(y: Float, r: Float, ny: Float)] = []
        for i in 0...rings {   // bottom cap
            let a = -Float.pi / 2 + Float.pi / 2 * Float(i) / Float(rings)
            rows.append((-halfLength + radius * sin(a), radius * cos(a), sin(a)))
        }
        for i in 0...rings {   // top cap
            let a = Float.pi / 2 * Float(i) / Float(rings)
            rows.append((halfLength + radius * sin(a), radius * cos(a), sin(a)))
        }
        for row in rows {
            for s in 0...segments {
                let phi = 2 * Float.pi * Float(s) / Float(segments)
                let dir = SIMD3<Float>(cos(phi), 0, sin(phi))
                p.append(SIMD3(dir.x * row.r, row.y, dir.z * row.r))
                let r = (1 - row.ny * row.ny).squareRoot()
                n.append(normalize(SIMD3(dir.x * r, row.ny, dir.z * r) + [0, 1e-6, 0]))
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<UInt32(rows.count - 1) {
            for s in 0..<UInt32(segments) {
                let a = r * stride + s, b = a + stride
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (p, n, idx)
    }

    /// Unit-radius icosphere with smooth normals.
    package static func icosphere(subdivisions: Int) -> MeshGeometry {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        let base: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
            [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
            [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ]
        var verts = base.map { normalize($0) }
        var tris: [UInt32] = [
            0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
            1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
            3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
            4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
        ]
        for _ in 0..<subdivisions {
            var cache: [UInt64: UInt32] = [:]
            func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                if let i = cache[key] { return i }
                verts.append(normalize((verts[Int(a)] + verts[Int(b)]) * 0.5))
                let i = UInt32(verts.count - 1)
                cache[key] = i
                return i
            }
            var next: [UInt32] = []
            next.reserveCapacity(tris.count * 4)
            for f in stride(from: 0, to: tris.count, by: 3) {
                let a = tris[f], b = tris[f + 1], c = tris[f + 2]
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next += [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]
            }
            tris = next
        }
        return (verts, verts, tris)
    }
}
