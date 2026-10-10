import Foundation
import simd

/// A mesh made fine enough for a material's height to move its vertices (displacement: Scene+Displacement.swift):
/// every edge longer than the detail asked for split at its middle, again and again, until none is (or the triangles
/// would pass the cap). Whether an edge is split depends on that edge alone, so the two triangles that share it split
/// it alike and no crack opens, even across a hard edge whose vertices are doubled (each side's copy of the edge is
/// as long, and its middle the same point).
///
/// The vertices that sit at one point (a hard edge's, a UV seam's, the original mesh's doubled ones) are then a group:
/// they move together, along the group's normal (its triangles', angle-weighted), by the average of the heights their
/// UVs read, so the surface stays closed where its UVs or normals jump.
struct MeshSubdivider {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    var indices: [UInt32]
    /// The cap was reached before every edge was short enough.
    private(set) var capped = false

    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        precondition(normals.count == positions.count && uvs.count == positions.count && indices.count % 3 == 0, "a vertex's arrays, whole triangles")
        (self.positions, self.normals, self.uvs, self.indices) = (positions, normals, uvs, indices)
    }

    var triangleCount: Int { indices.count / 3 }

    /// The longest edge (in the mesh's units).
    var longestEdge: Float {
        var longest: Float = 0
        for t in 0..<triangleCount {
            for k in 0..<3 {
                longest = max(longest, simd_distance(positions[Int(indices[3 * t + k])], positions[Int(indices[3 * t + (k + 1) % 3])]))
            }
        }
        return longest
    }

    /// Splits the edges longer than `edge` until none is, or until a round of splits would make more than `cap`
    /// triangles (then it stops before that round: `capped`).
    mutating func subdivide(edge: Float, cap: Int) {
        guard edge > 0 else { return }
        while true {
            // This round's splits: an edge's middle vertex, by its two ends.
            var middles: [UInt64: UInt32] = [:]
            var split = [UInt8](repeating: 0, count: triangleCount)   // bit k: edge k (from corner k to k + 1)
            var extra = 0
            for t in 0..<triangleCount {
                for k in 0..<3 {
                    let a = indices[3 * t + k], b = indices[3 * t + (k + 1) % 3]
                    guard simd_distance(positions[Int(a)], positions[Int(b)]) > edge else { continue }
                    split[t] |= 1 << k
                    let key = MeshSubdivider.key(a, b)
                    if middles[key] == nil { middles[key] = UInt32.max }
                }
                extra += split[t].nonzeroBitCount
            }
            guard !middles.isEmpty else { return }
            // n split edges make n + 1 triangles of one.
            guard triangleCount + extra <= cap else { capped = true; return }
            for (key, _) in middles {
                let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
                middles[key] = UInt32(positions.count)
                positions.append((positions[a] + positions[b]) * 0.5)
                let n = normals[a] + normals[b]
                normals.append(simd_length_squared(n) > 1e-12 ? simd_normalize(n) : normals[a])
                uvs.append((uvs[a] + uvs[b]) * 0.5)
            }
            var next: [UInt32] = []
            next.reserveCapacity(3 * (triangleCount + extra))
            for t in 0..<triangleCount {
                let v = SIMD3(indices[3 * t], indices[3 * t + 1], indices[3 * t + 2])
                let s = split[t]
                func m(_ k: Int) -> UInt32 { middles[MeshSubdivider.key(v[k], v[(k + 1) % 3])]! }
                switch s.nonzeroBitCount {
                case 0:
                    next += [v.x, v.y, v.z]
                case 3:
                    let (ab, bc, ca) = (m(0), m(1), m(2))
                    next += [v[0], ab, ca, ab, v[1], bc, ca, bc, v[2], ab, bc, ca]
                case 1:
                    // The split edge from corner k: (k, mid, k + 2), (mid, k + 1, k + 2).
                    let k = s.trailingZeroBitCount
                    let (a, b, c, mid) = (v[k], v[(k + 1) % 3], v[(k + 2) % 3], m(k))
                    next += [a, mid, c, mid, b, c]
                default:
                    // Two split edges, the whole one from corner k + 2 to k: the corner between the splits cut off,
                    // and the quad left split along its shorter diagonal.
                    let k = (0..<3).first { s & (1 << (($0 + 2) % 3)) == 0 }!
                    let (a, b, c) = (v[k], v[(k + 1) % 3], v[(k + 2) % 3])
                    let (ab, bc) = (m(k), m((k + 1) % 3))
                    next += [ab, b, bc]
                    if simd_distance(positions[Int(a)], positions[Int(bc)]) <= simd_distance(positions[Int(ab)], positions[Int(c)]) {
                        next += [a, ab, bc, a, bc, c]
                    } else {
                        next += [a, ab, c, ab, bc, c]
                    }
                }
            }
            indices = next
        }
    }

    /// An edge's key: its ends, the lower first.
    private static func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(min(a, b)) << 32 | UInt64(max(a, b))
    }

    /// The vertices at one point, as groups: per vertex, where its group's members start in `members` and how many
    /// they are; the members (vertex indices); and per vertex the direction its group moves along.
    struct Welds {
        var start: [UInt32]
        var count: [UInt32]
        var members: [UInt32]
        var direction: [SIMD3<Float>]
    }

    /// The groups of vertices at the same point (bit for bit: a split's middles are computed alike on both sides).
    func welds() -> Welds {
        var group: [SIMD3<UInt32>: Int] = [:]
        var groupOf = [Int](repeating: 0, count: positions.count)
        var groups: [[UInt32]] = []
        for (i, p) in positions.enumerated() {
            let q = p + SIMD3(repeating: 0)   // -0 as 0
            let key = SIMD3(q.x.bitPattern, q.y.bitPattern, q.z.bitPattern)
            if let g = group[key] { groupOf[i] = g; groups[g].append(UInt32(i)) } else {
                group[key] = groups.count
                groupOf[i] = groups.count
                groups.append([UInt32(i)])
            }
        }
        // Each group's normal: its triangles', each weighted by its angle at the group (a cube's corner: the diagonal,
        // however its faces are cut), else (they cancel: a sheet's two sides) its first vertex's.
        var sum = [SIMD3<Float>](repeating: .zero, count: groups.count)
        for t in 0..<triangleCount {
            let i = [Int(indices[3 * t]), Int(indices[3 * t + 1]), Int(indices[3 * t + 2])]
            let c = simd_cross(positions[i[1]] - positions[i[0]], positions[i[2]] - positions[i[0]])
            guard simd_length_squared(c) > 0 else { continue }
            let n = simd_normalize(c)
            for k in 0..<3 {
                let e1 = positions[i[(k + 1) % 3]] - positions[i[k]], e2 = positions[i[(k + 2) % 3]] - positions[i[k]]
                let cosine = simd_dot(e1, e2) / max(simd_length(e1) * simd_length(e2), 1e-30)
                sum[groupOf[i[k]]] += n * acos(min(max(cosine, -1), 1))
            }
        }
        var starts: [Int] = [], members: [UInt32] = []
        for g in groups { starts.append(members.count); members += g }
        var w = Welds(start: [], count: [], members: members, direction: [])
        w.start.reserveCapacity(positions.count)
        for i in positions.indices {
            let g = groupOf[i]
            w.start.append(UInt32(starts[g]))
            w.count.append(UInt32(groups[g].count))
            let n = sum[g]
            let fallback = simd_length_squared(normals[Int(groups[g][0])]) > 1e-12 ? simd_normalize(normals[Int(groups[g][0])]) : SIMD3<Float>(0, 1, 0)
            w.direction.append(simd_length_squared(n) > 1e-20 ? simd_normalize(n) : fallback)
        }
        return w
    }

    /// UVs for a mesh without any: per triangle its positions (times `scale`: metres) along the axis it faces most, a
    /// tile a metre (as the shading's planarUV), its vertices made its own so each triangle keeps its projection.
    static func planarUVs(_ positions: [SIMD3<Float>], _ normals: [SIMD3<Float>], _ indices: [UInt32], scale: Float)
        -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        var seen: [SIMD4<UInt32>: UInt32] = [:]   // (vertex, axis): its copy, shared by the triangles projected alike
        for t in 0..<(indices.count / 3) {
            let i = (0..<3).map { Int(indices[3 * t + $0]) }
            let a = simd_abs(simd_cross(positions[i[1]] - positions[i[0]], positions[i[2]] - positions[i[0]]))
            let axis: UInt32 = a.y >= a.x && a.y >= a.z ? 1 : a.x >= a.z ? 0 : 2
            for v in i {
                let key = SIMD4(UInt32(v), axis, 0, 0)
                if let k = seen[key] { idx.append(k); continue }
                let w = positions[v] * scale
                seen[key] = UInt32(p.count)
                idx.append(UInt32(p.count))
                p.append(positions[v])
                n.append(normals[v])
                uv.append(axis == 1 ? SIMD2(w.x, w.z) : axis == 0 ? SIMD2(w.z, -w.y) : SIMD2(w.x, -w.y))
            }
        }
        return (p, n, uv, idx)
    }
}
