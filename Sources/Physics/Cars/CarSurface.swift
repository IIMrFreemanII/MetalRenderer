import EngineCore
import Foundation
import simd

/// A car's drawn panels (CarBlueprint's body, finer): the body's paint, trim and lamps as one mesh, its glass as another
/// (drawn as glass), each vertex embedded in the node hull's triangles so that the GPU draws it where the nodes are
/// (MSL physicsSoftMeshKernel's triangle embeds: BeamNG's flexbodies).
///
/// The surface is lofted from the same profile as the nodes (CarSpec): a cross-section every few centimetres, round
/// it the ten ring slots joined by straight sides and a rounded greenhouse, closed at the bumpers by caps that carry
/// the lamps. A vertex follows the hull triangle nearest it, and those its neighbours follow, averaged (as a soft body's
/// do: one triangle's alone creases the surface where two bend apart).
package struct CarSurface {
    /// A mesh and where its vertices are embedded: per vertex the hull triangles it follows (its own first) and its
    /// place over each (the weights of its second and third nodes, how far out along its normal); the triangles round
    /// each vertex (as SoftModel.rings); per triangle its material's offset (`paint`...).
    package struct Part {
        package var mesh: MeshGeometry = ([], [], [])
        /// Its texture coordinates (a model's; none for the procedural panels).
        package var uvs: [SIMD2<Float>]?
        package var materials: [UInt8] = []
        package var embedding: [[(triangle: Int, bary: SIMD3<Float>)]] = []
        package var rings: [[SIMD2<UInt32>]] = []
    }

    package var body = Part()
    package var glass = Part()

    /// The body's materials, as offsets from its paint (Scene.addCar makes them in this order).
    package static let paint: UInt8 = 0, trim: UInt8 = 1, chrome: UInt8 = 2, headlamp: UInt8 = 3, taillamp: UInt8 = 4
    /// Cross-sections along the body, and points round each between the ring's slots (the greenhouse's rounded).
    package static let sections = 60
    package static let between = [3, 3, 3, 3, 3, 3, 2, 2, 2, 2]

    package init(_ b: CarBlueprint) {
        let spec = b.spec
        let around = CarSurface.between.reduce(0, +)
        let zs = (0..<CarSurface.sections).map { spec.rearEnd + (spec.frontEnd - spec.rearEnd) * Float($0) / Float(CarSurface.sections - 1) }
        // The loft's grid, and per point the segment of the ring it is on.
        var grid: [SIMD3<Float>] = []
        var segmentOf: [Int] = []
        for z in zs {
            let slots = CarBlueprint.Slot.allCases.map { b.ringPoint($0, z) }
            for (s, count) in CarSurface.between.enumerated() {
                for k in 0..<count {
                    grid.append(CarSurface.section(slots, s, Float(k) / Float(count)))
                    segmentOf.append(s)
                }
            }
        }
        var bodyTris: [(SIMD3<UInt32>, UInt8)] = [], glassTris: [SIMD3<UInt32>] = []
        for k in 0..<(zs.count - 1) {
            for j in 0..<around {
                let j1 = (j + 1) % around
                let a = UInt32(k * around + j), bb = UInt32(k * around + j1), c = UInt32((k + 1) * around + j1), d = UInt32((k + 1) * around + j)
                let z = (zs[k] + zs[k + 1]) / 2
                let look = CarSurface.look(spec, segment: segmentOf[j], z: z, height: (grid[Int(a)].y + grid[Int(c)].y) / 2)
                for t in [SIMD3(a, bb, c), SIMD3(a, c, d)] {
                    let w = CarSurface.outward(t, grid, spec)
                    if look == nil { glassTris.append(w) } else { bodyTris.append((w, look!)) }
                }
            }
        }
        // The caps: each end's section drawn in toward its middle, in rings.
        for (k, front) in [(0, false), (zs.count - 1, true)] {
            let first = grid.count
            let edge = (0..<around).map { grid[k * around + $0] }
            let centre = edge.reduce(SIMD3<Float>(), +) / Float(around)
            let levels = 3
            for l in 0..<levels {
                for p in edge { grid.append(centre + (p - centre) * (1 - Float(l) / Float(levels))) }
            }
            grid.append(centre)
            let middle = UInt32(grid.count - 1)
            let z = zs[k]
            for l in 0..<levels {
                for j in 0..<around {
                    let j1 = (j + 1) % around
                    let a = UInt32(first + l * around + j), bb = UInt32(first + l * around + j1)
                    let tris: [SIMD3<UInt32>] = l + 1 < levels
                        ? [SIMD3(a, bb, UInt32(first + (l + 1) * around + j1)), SIMD3(a, UInt32(first + (l + 1) * around + j1), UInt32(first + (l + 1) * around + j))]
                        : [SIMD3(a, bb, middle)]
                    for t in tris {
                        let p = (grid[Int(t.x)] + grid[Int(t.y)] + grid[Int(t.z)]) / 3
                        let n = cross(grid[Int(t.y)] - grid[Int(t.x)], grid[Int(t.z)] - grid[Int(t.x)])
                        let w = (n.z >= 0) == front ? t : SIMD3(t.x, t.z, t.y)
                        bodyTris.append((w, CarSurface.capLook(spec, p, z: z, front: front, outer: l == 0)))
                    }
                }
            }
        }
        body = CarSurface.part(grid, bodyTris.map(\.0), bodyTris.map(\.1), b)
        glass = CarSurface.part(grid, glassTris, [UInt8](repeating: 0, count: glassTris.count), b)
    }

    /// A model's panels (CarPack) on blueprint `b` (fitted to it: CarSpec.fitted): its paint and lamps as the body (their
    /// materials' offsets 0 and 1: Scene.addCar makes them in that order), its glass. Each vertex follows the hull as the
    /// procedural panels' do; a seam's copies of one place (split for their texture coordinates or their normals)
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

    /// The section's point `t` of the way along segment `s` (slot s to s + 1): straight on the sides and underneath,
    /// a little full on the doors, rounded over the greenhouse (Catmull-Rom through the slots).
    private static func section(_ slots: [SIMD3<Float>], _ s: Int, _ t: Float) -> SIMD3<Float> {
        let n = slots.count
        let p1 = slots[s], p2 = slots[(s + 1) % n]
        switch s {
        case 1, 2, 3, 4:
            let p0 = slots[(s + n - 1) % n], p3 = slots[(s + 2) % n]
            let t2 = t * t, t3 = t2 * t
            let a = 2 * p1, b = p2 - p0, c = 2 * p0 - 5 * p1 + 4 * p2 - p3, d = -p0 + 3 * p1 - 3 * p2 + p3
            return 0.5 * (a + b * t + c * t2 + d * t3)
        case 0, 5:
            var p = p1 + (p2 - p1) * t
            p.x += (p.x > 0 ? 1 : -1) * 0.025 * sin(.pi * t)
            return p
        default:
            return p1 + (p2 - p1) * t
        }
    }

    /// A loft triangle wound to face away from the body's middle line.
    private static func outward(_ t: SIMD3<UInt32>, _ grid: [SIMD3<Float>], _ spec: CarSpec) -> SIMD3<UInt32> {
        let a = grid[Int(t.x)], b = grid[Int(t.y)], c = grid[Int(t.z)]
        let centre = (a + b + c) / 3
        let middle = SIMD3<Float>(0, (spec.sill + spec.belt) / 2, centre.z)
        return dot(cross(b - a, c - a), centre - middle) >= 0 ? t : SIMD3(t.x, t.z, t.y)
    }

    /// What a loft panel is: glass (nil) in the windows (the side windows between the pillars, the windshield, the rear
    /// window), the underside's trim, the bumpers' trim low down at the ends, paint elsewhere.
    private static func look(_ spec: CarSpec, segment s: Int, z: Float, height: Float) -> UInt8? {
        if s >= 6 { return trim }
        let toEnd = min(z - spec.rearEnd, spec.frontEnd - z)
        if (s == 0 || s == 5) && toEnd < 0.3 && height < spec.sill + 0.22 { return trim }
        let cabin = spec.roofness(z) > 0.5
        switch s {
        case 1, 4:
            // The side windows: from the A pillar to the C pillar, a B pillar between.
            let front = min(spec.windshieldBase, spec.roofFront + 0.35) - 0.1, rear = max(spec.rearWindowBase, spec.roofRear - 0.35) + 0.12
            let bPillar = (front + rear) / 2
            if cabin && z < front && z > rear && abs(z - bPillar) > 0.05 && height > spec.belt + 0.04 { return nil }
            return paint
        case 2, 3:
            let windshield = z > spec.roofFront + 0.04 && z < spec.windshieldBase - 0.05
            let rearWindow = z < spec.roofRear - 0.04 && z > spec.rearWindowBase + 0.05
            return windshield || rearWindow ? nil : paint
        default:
            return paint
        }
    }

    /// What a cap's triangle is: lamps at its top corners, a grille (the front's) or a bumper's trim low down, paint.
    private static func capLook(_ spec: CarSpec, _ p: SIMD3<Float>, z: Float, front: Bool, outer: Bool) -> UInt8 {
        let hw = spec.halfWidth(z), belt = spec.beltHeight(z)
        if outer && abs(p.x) > 0.5 * hw && p.y > belt - 0.17 && p.y < belt + 0.03 { return front ? headlamp : taillamp }
        if p.y < spec.sill + 0.16 { return trim }
        if front && abs(p.x) < 0.45 * hw && p.y < belt - 0.12 { return trim }
        return paint
    }

    /// A part of the loft: its triangles' vertices (only those it uses, renumbered), their normals, rings and
    /// embedding in the hull.
    private static func part(_ grid: [SIMD3<Float>], _ tris: [SIMD3<UInt32>], _ materials: [UInt8], _ b: CarBlueprint) -> Part {
        var used = [Int](repeating: -1, count: grid.count), positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for t in tris {
            for v in [t.x, t.y, t.z] {
                if used[Int(v)] < 0 {
                    used[Int(v)] = positions.count
                    positions.append(grid[Int(v)])
                }
                indices.append(UInt32(used[Int(v)]))
            }
        }
        var rings = [[SIMD2<UInt32>]](repeating: [], count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            rings[Int(a)].append(SIMD2(b, c))
            rings[Int(b)].append(SIMD2(c, a))
            rings[Int(c)].append(SIMD2(a, b))
        }
        rings = rings.map { Array($0.prefix(31)) }
        let normals = positions.indices.map { v -> SIMD3<Float> in
            let n = rings[v].reduce(SIMD3<Float>()) { $0 + cross(positions[Int($1.x)] - positions[v], positions[Int($1.y)] - positions[v]) }
            return length_squared(n) > 1e-20 ? normalize(n) : SIMD3(0, 1, 0)
        }
        let own = positions.map { CarSurface.nearestHull($0, b) }
        let embedding = positions.indices.map { v -> [(triangle: Int, bary: SIMD3<Float>)] in
            var follows = [own[v]]
            for pair in rings[v] {
                for u in [pair.x, pair.y] where !follows.contains(own[Int(u)]) { follows.append(own[Int(u)]) }
            }
            return follows.map { ($0, CarSurface.bary(positions[v], hull: b.hull[$0], b.nodes)) }
        }
        return Part(mesh: (positions, normals, indices), uvs: nil, materials: materials, embedding: embedding, rings: rings)
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
