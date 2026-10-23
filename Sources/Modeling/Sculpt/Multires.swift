import Foundation
import simd

/// Multires: shape_0 is the base; shape_k = S(shape_k−1) + D_k, S one Catmull-Clark subdivision and D_k level k's
/// displacements in the frames of S(shape_k−1). Sculpting level k changes D_k only, so finer levels keep their detail
/// on top of it (Blender's reshape, without its grids: every level's points are a mesh's vertices).
package enum Multires {
    /// The mesh of a level: the base subdivided `level` times, each level's displacements added.
    package static func levelMesh(_ base: EditMesh, _ r: MultiresData, level: Int) -> EditMesh {
        var mesh = base
        for k in 0..<min(level, r.levels) {
            mesh = CatmullClark.subdivide(mesh)
            let d = r.displacements[k]
            guard d.count == mesh.vertexCount else { continue }
            let frames = tangentFrames(mesh)
            for v in 0..<mesh.vertexCount {
                let f = frames[v]
                mesh.positions[v] += f.t * d[v].x + f.b * d[v].y + f.n * d[v].z
            }
            mesh.touch()
        }
        return mesh
    }

    /// Whether the displacements still fit the base (its topology unchanged).
    package static func fits(_ base: EditMesh, _ r: MultiresData) -> Bool {
        r.baseFaces == base.faceCount && r.baseCorners == base.cornerCount
    }

    /// Subdivide (the modifier's button): a level more, with no displacement yet; sculpt and view it.
    package static func addLevel(_ base: EditMesh, _ r: inout MultiresData) {
        if !fits(base, r) { r = MultiresData() }
        r.baseFaces = base.faceCount
        r.baseCorners = base.cornerCount
        // The new level's points: the old level's vertices, edge points and face points.
        let below = levelMesh(base, r, level: r.levels)
        r.displacements.append([SIMD3<Float>](repeating: .zero, count: below.vertexCount + below.edgeCount + below.faceCount))
        r.sculptLevel = r.levels
        r.viewportLevel = r.levels
        r.renderLevel = r.levels
        r.changed()
    }

    /// Delete Higher: the levels above the sculpt level go.
    package static func deleteHigher(_ r: inout MultiresData) {
        r.displacements.removeSubrange(min(r.sculptLevel, r.displacements.count)...)
        r.viewportLevel = min(r.viewportLevel, r.levels)
        r.renderLevel = min(r.renderLevel, r.levels)
        r.changed()
    }

    /// Sculpt mode's mesh for the sculpt level (nil without levels, or when they don't fit the base).
    package static func sculptMesh(_ base: EditMesh, _ r: MultiresData) -> SculptMesh? {
        guard r.levels > 0, r.sculptLevel > 0, fits(base, r) else { return nil }
        return SculptMesh(levelMesh(base, r, level: r.sculptLevel))
    }

    /// The sculpted level back into its displacements: D_k = the new shape − S(shape_k−1), in S's frames.
    package static func store(_ s: SculptMesh, level: Int, base: EditMesh, into r: inout MultiresData) {
        guard level > 0, level <= r.levels else { return }
        let below = levelMesh(base, r, level: level - 1)
        let smooth = CatmullClark.subdivide(below)
        guard smooth.vertexCount == r.displacements[level - 1].count else { return }
        let frames = tangentFrames(smooth)
        var d = r.displacements[level - 1]
        for v in 0..<s.vertexCount {
            let src = Int(s.source[v])
            guard src >= 0 && src < smooth.vertexCount else { continue }
            let p = s.position[v]
            let off = SIMD3(p.x, p.y, p.z) - smooth.positions[src]
            let f = frames[src]
            d[src] = SIMD3(simd_dot(off, f.t), simd_dot(off, f.b), simd_dot(off, f.n))
        }
        r.displacements[level - 1] = d
        r.changed()
    }

    /// Each vertex's frame: its normal, a tangent toward its first neighbour, and the third.
    package static func tangentFrames(_ m: EditMesh) -> [(t: SIMD3<Float>, b: SIMD3<Float>, n: SIMD3<Float>)] {
        let t = MeshTopology(m)
        let normals = m.vertexNormals()
        var out = [(t: SIMD3<Float>, b: SIMD3<Float>, n: SIMD3<Float>)](repeating: (.zero, .zero, .zero), count: m.vertexCount)
        for v in 0..<m.vertexCount {
            let n = normals[v]
            var dir = SIMD3<Float>(1, 0, 0)
            if !t.edges(ofVertex: v).isEmpty {
                // The neighbour with the lowest index: the same one every time the topology is the same.
                var best = Int32.max
                for x in t.edges(ofVertex: v) { best = min(best, MeshTopology.other(m, edge: Int(x), from: Int32(v))) }
                dir = m.positions[Int(best)] - m.positions[v]
            }
            var tangent = dir - n * simd_dot(dir, n)
            if simd_length(tangent) < 1e-12 { tangent = abs(n.x) < 0.9 ? simd_cross(n, [1, 0, 0]) : simd_cross(n, [0, 1, 0]) }
            tangent = simd_normalize(tangent)
            out[v] = (tangent, simd_cross(n, tangent), n)
        }
        return out
    }
}
