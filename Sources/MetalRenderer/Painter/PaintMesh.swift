import Foundation
import simd

/// A mesh as the Material Painter sees it: its own vertices (object space, a character's bind pose), its triangles,
/// and the UVs it came with. The painter unwraps it (UVUnwrap) when those aren't fit to paint into (UVCheck), and its
/// texture set is laid out by the unwrap's corner UVs.
struct PaintMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]          // per vertex: the mesh's own (zeros: it has none)
    var indices: [UInt32]            // into its own vertices
    var triangleCount: Int { indices.count / 3 }

    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>]? = nil, indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.uvs = uvs ?? [SIMD2<Float>](repeating: .zero, count: positions.count)
        self.indices = indices
    }

    /// Mesh `m` of a scene, out of the shared arrays: the vertices its triangles name (a pose slot's bind pose: the
    /// ones before its `vertexOffset`), renumbered from 0.
    init(scene: Scene, mesh m: Int) {
        let mesh = scene.meshes[m]
        let range = Int(mesh.firstIndex)..<Int(mesh.firstIndex + mesh.indexCount)
        let own = scene.indices[range]
        let lo = Int(own.min() ?? 0), hi = Int(own.max() ?? 0)
        positions = Array(scene.positions[lo...hi])
        normals = Array(scene.normals[lo...hi])
        uvs = Array(scene.uvs[lo...hi])
        indices = own.map { $0 - UInt32(lo) }
    }

    /// A triangle's corners.
    @inline(__always) func corners(_ t: Int) -> (Int, Int, Int) {
        (Int(indices[3 * t]), Int(indices[3 * t + 1]), Int(indices[3 * t + 2]))
    }

    /// A triangle's world (object-space) area.
    func area(_ t: Int) -> Float {
        let (a, b, c) = corners(t)
        return simd_length(simd_cross(positions[b] - positions[a], positions[c] - positions[a])) / 2
    }

    /// The same mesh, said in full, as a short name: what the unwrap and a painted document of it are filed under.
    var fingerprint: String {
        var hasher = GeneratedCache.Hasher()
        hasher.add([UInt32(positions.count), UInt32(indices.count)])
        hasher.add(positions)
        hasher.add(indices)
        return hasher.name()
    }

    /// Each vertex's weld group: vertices at the same place (a seam's two sides) are one, so the unwrap sees through
    /// the seams the mesh was cut along. Positions are compared on a grid of a millionth of the mesh's size.
    func welded() -> (group: [Int32], count: Int) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let step = max(simd_reduce_max(hi - lo), 1e-6) * 1e-6
        var seen: [SIMD3<Int32>: Int32] = [:]
        seen.reserveCapacity(positions.count)
        var group = [Int32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let q = SIMD3<Int32>(((p - lo) / step).rounded(.toNearestOrEven))
            if let g = seen[q] { group[i] = g } else {
                group[i] = Int32(seen.count)
                seen[q] = group[i]
            }
        }
        return (group, seen.count)
    }

    /// Triangles that share an edge (of welded vertices), as CSR: `start[t]..<start[t + 1]` of `next`. An edge of
    /// more than two triangles links each of them to the others.
    func adjacency(_ weld: [Int32]) -> (start: [Int32], next: [Int32]) {
        var edges: [(UInt64, Int32)] = []
        edges.reserveCapacity(indices.count)
        for t in 0..<triangleCount {
            for k in 0..<3 {
                let a = UInt64(UInt32(weld[Int(indices[3 * t + k])])), b = UInt64(UInt32(weld[Int(indices[3 * t + (k + 1) % 3])]))
                guard a != b else { continue }
                edges.append((min(a, b) << 32 | max(a, b), Int32(t)))
            }
        }
        edges.sort { $0.0 < $1.0 }
        var pairs: [(Int32, Int32)] = []
        var i = 0
        while i < edges.count {
            var j = i + 1
            while j < edges.count && edges[j].0 == edges[i].0 { j += 1 }
            if j - i <= 8 {
                for a in i..<j { for b in i..<j where a != b && edges[a].1 != edges[b].1 { pairs.append((edges[a].1, edges[b].1)) } }
            }
            i = j
        }
        var start = [Int32](repeating: 0, count: triangleCount + 1)
        for (a, _) in pairs { start[Int(a) + 1] += 1 }
        for t in 0..<triangleCount { start[t + 1] += start[t] }
        var fill = start
        var next = [Int32](repeating: 0, count: pairs.count)
        for (a, b) in pairs {
            next[Int(fill[Int(a)])] = b
            fill[Int(a)] += 1
        }
        return (start, next)
    }
}
