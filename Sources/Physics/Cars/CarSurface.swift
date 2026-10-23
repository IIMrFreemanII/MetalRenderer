import EngineCore
import Foundation
import simd

/// A car's drawn panels: its model's (CarPack) body, its paint and lamps as one mesh, its glass as another (drawn as
/// glass), each vertex embedded in the node hull's triangles so that the GPU draws it where the nodes are (MSL
/// physicsSoftMeshKernel's triangle embeds: BeamNG's flexbodies). A vertex follows the hull triangle nearest it, and
/// those its neighbours follow, averaged (as a soft body's do: one triangle's alone creases the surface where two bend
/// apart).
package struct CarSurface {
    /// A mesh and where its vertices are embedded: per vertex the hull triangles it follows (its own first) and its
    /// place over each (the weights of its second and third nodes, how far out along its normal); the triangles round
    /// each vertex (as SoftModel.rings); per triangle its material's offset.
    package struct Part {
        package var mesh: MeshGeometry = ([], [], [])
        package var uvs: [SIMD2<Float>] = []
        package var materials: [UInt8] = []
        package var embedding: [[(triangle: Int, bary: SIMD3<Float>)]] = []
        package var rings: [[SIMD2<UInt32>]] = []
    }

    package var body = Part()
    package var glass = Part()

    /// A model's panels on blueprint `b` (fitted to it: CarSpec.fitted): its paint and lamps as the body (their materials'
    /// offsets 0 and 1: Scene.addCar makes them in that order), its glass. A seam's copies of one place (split for their texture coordinates or their normals)
    /// follow it alike, so it can't open, and those whose normals agree share their rings too, so the shading stays
    /// smooth across it (a hard edge's keep their own).
    package init(_ b: CarBlueprint, model: CarModel) {
        body = CarSurface.part([(model.paint, 0), (model.lamps, 1)], b)
        glass = CarSurface.part([(model.glass, 0)], b)
    }

    private static func part(_ meshes: [(CarModel.Mesh, UInt8)], _ b: CarBlueprint) -> Part {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        var materials: [UInt8] = []
        for (m, material) in meshes {
            let base = UInt32(positions.count)
            positions += m.positions
            normals += m.normals
            uvs += m.uvs.count == m.positions.count ? m.uvs : [SIMD2<Float>](repeating: .zero, count: m.positions.count)
            indices += m.indices.map { $0 + base }
            materials += [UInt8](repeating: material, count: m.indices.count / 3)
        }
        // Each vertex's own ring, and the copies of its place.
        var own = [[SIMD2<UInt32>]](repeating: [], count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[t], c1 = indices[t + 1], c2 = indices[t + 2]
            own[Int(a)].append(SIMD2(c1, c2))
            own[Int(c1)].append(SIMD2(c2, a))
            own[Int(c2)].append(SIMD2(a, c1))
        }
        var copies: [SIMD3<Int32>: [Int]] = [:]
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p * 5000).rounded(.toNearestOrAwayFromZero)) }
        for (v, p) in positions.enumerated() { copies[key(p), default: []].append(v) }
        var rings = [[SIMD2<UInt32>]](repeating: [], count: positions.count)
        var embedding = [[(triangle: Int, bary: SIMD3<Float>)]](repeating: [], count: positions.count)
        var nearest: [SIMD3<Int32>: Int] = [:]
        func hull(_ v: UInt32) -> Int {
            let k = key(positions[Int(v)])
            if let h = nearest[k] { return h }
            let h = CarSurface.nearestHull(positions[Int(v)], b)
            nearest[k] = h
            return h
        }
        for group in copies.values {
            let p = positions[group[0]]
            // Its embedding: its place's hull triangle, then those of its neighbours round all its copies.
            var follows = [hull(UInt32(group[0]))]
            for v in group {
                for pair in own[v] {
                    for u in [pair.x, pair.y] {
                        let h = hull(u)
                        if !follows.contains(h) { follows.append(h) }
                    }
                }
            }
            let embed = follows.map { ($0, CarSurface.bary(p, hull: b.hull[$0], b.nodes)) }
            for v in group {
                embedding[v] = embed
                var ring = own[v]
                for u in group where u != v && dot(normals[u], normals[v]) > 0.95 { ring += own[u] }
                rings[v] = Array(ring.prefix(31))
            }
        }
        return Part(mesh: (positions, normals, indices), uvs: uvs, materials: materials, embedding: embedding, rings: rings)
    }

    /// The hull triangle nearest `p`.
    private static func nearestHull(_ p: SIMD3<Float>, _ b: CarBlueprint) -> Int {
        var best = 0, nearest = Float.infinity
        for (k, t) in b.hull.enumerated() {
            let d = CarSurface.distanceSquared(p, b.nodes[Int(t.x)], b.nodes[Int(t.y)], b.nodes[Int(t.z)])
            if d < nearest { (best, nearest) = (k, d) }
        }
        return best
    }

    /// `p`'s place over triangle `t` of `nodes`: the weights of its second and third corners, and how far out along its
    /// normal (normalize(cross(b - a, c - a)), as MSL physicsSoftMeshKernel takes it).
    package static func bary(_ p: SIMD3<Float>, hull t: SIMD3<Int32>, _ nodes: [SIMD3<Float>]) -> SIMD3<Float> {
        let a = nodes[Int(t.x)], u = nodes[Int(t.y)] - a, w = nodes[Int(t.z)] - a
        let n = normalize(cross(u, w))
        let d = p - a, h = dot(d, n), q = d - n * h
        let uu = dot(u, u), uw = dot(u, w), ww = dot(w, w), qu = dot(q, u), qw = dot(q, w)
        let det = uu * ww - uw * uw
        guard abs(det) > 1e-12 else { return SIMD3(0, 0, h) }
        return SIMD3((qu * ww - qw * uw) / det, (qw * uu - qu * uw) / det, h)
    }

    /// The squared distance from `p` to triangle (a, b, c) (Ericson's closest point).
    private static func distanceSquared(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return length_squared(ap) }
        let bp = p - b, d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return length_squared(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return length_squared(p - (a + ab * (d1 / (d1 - d3)))) }
        let cp = p - c, d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return length_squared(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return length_squared(p - (a + ac * (d2 / (d2 - d6)))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 { return length_squared(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))) }
        let denom = 1 / (va + vb + vc)
        return length_squared(p - (a + ab * (vb * denom) + ac * (vc * denom)))
    }
}
