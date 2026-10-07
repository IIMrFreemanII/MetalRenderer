import Foundation
import simd

/// A skin that slides over the flesh (PhysicsFlesh.swift): a thin shell of particles (a surface of the flesh's shape)
/// held together by its links' lengths and bends, each particle held to where it rests on the flesh: hard along the
/// flesh's normal there, softly across it, and no further across than `maxSlide`. So it stays on the flesh, and the
/// flesh moves under it: over a bulging muscle it slides and stretches as skin does, and what is drawn rides on it.
/// One-way: the flesh never feels it. The normal comes from a second point under the first in the same tet, so it
/// turns as the tet does.
extension PhysicsWorld {
    /// Where `bary` puts a point in the tet whose particles are `ids` (weights of the last three).
    @inline(__always) func inTet(_ ids: SIMD4<UInt32>, _ bary: SIMD4<Float>) -> SIMD3<Float> {
        let x0 = PhysicsMath.xyz(particles[Int(ids.x)].position)
        return x0 + (PhysicsMath.xyz(particles[Int(ids.y)].position) - x0) * bary.x
            + (PhysicsMath.xyz(particles[Int(ids.z)].position) - x0) * bary.y
            + (PhysicsMath.xyz(particles[Int(ids.w)].position) - x0) * bary.z
    }

    /// `x`, a skin particle of inverse mass `w`, held by `a` to `target` (and `deep` under it) over a substep of `h`.
    @inline(__always) static func skinHold(_ x: SIMD3<Float>, _ a: GPUSkinAttach, target: SIMD3<Float>, deep: SIMD3<Float>,
                                           w: Float, h: Float) -> SIMD3<Float> {
        let up = target - deep, l = length(up)
        let n = l > 1e-9 ? up / l : SIMD3<Float>()
        var y = x - n * (dot(x - target, n) * (w / (w + a.compliance / (h * h))))
        var d = y - target
        y -= (d - n * dot(d, n)) * (w / (w + a.deep.w / (h * h)))
        d = y - target
        let across = d - n * dot(d, n), slide = length(across)
        if slide > a.bary.w { y -= across * (1 - a.bary.w / slide) }
        return y
    }

    /// Every skin particle held to the flesh (after the flesh's links and tets, before the collisions).
    func solveSkin(_ p: GPUPhysicsParams) {
        for a in skinAttachments {
            let i = Int(a.particle), w = particles[i].prevPosition.w
            guard w > 0 else { continue }
            let y = PhysicsWorld.skinHold(PhysicsMath.xyz(particles[i].position), a, target: inTet(a.ids, a.bary),
                                          deep: inTet(a.ids, a.deep), w: w, h: p.gravity.w)
            particles[i].position = SIMD4(y, particles[i].position.w)
        }
    }
}

/// A figure's skin shell (PhysicsWorld.addSkin): its particles (from `first`, one a vertex of `mesh`, its rest
/// surface), and a finder of the triangle nearest a point.
struct SkinShell {
    var mesh: MeshGeometry
    var first: Int
    private var cells: [SIMD3<Int32>: [Int]] = [:]
    private let cell: Float

    init(mesh: MeshGeometry, first: Int, cell: Float = 0.05) {
        self.mesh = mesh
        self.first = first
        self.cell = cell
        for t in 0..<(mesh.indices.count / 3) {
            let c = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0])] }.reduce(.zero, +) / 3
            cells[SIMD3<Int32>((c / cell).rounded(.down)), default: []].append(t)
        }
    }

    /// The triangle nearest `p` (rest space): its corners, `p`'s weights for the last two at the nearest point on it,
    /// and how far out from there along its normal `p` is.
    func nearest(_ p: SIMD3<Float>) -> (corners: SIMD3<UInt32>, weights: SIMD2<Float>, out: Float)? {
        let c = SIMD3<Int32>((p / cell).rounded(.down))
        var best: (d: Float, t: Int, w: SIMD2<Float>, q: SIMD3<Float>)?
        for r: Int32 in 1...3 where best == nil {
            for dz in -r...r {
                for dy in -r...r {
                    for dx in -r...r {
                        for t in cells[c &+ SIMD3(dx, dy, dz)] ?? [] {
                            let (q, w) = SkinShell.closest(p, mesh.positions[Int(mesh.indices[3 * t])], mesh.positions[Int(mesh.indices[3 * t + 1])],
                                                           mesh.positions[Int(mesh.indices[3 * t + 2])])
                            let d = simd_length(p - q)
                            if best.map({ d < $0.d }) ?? true { best = (d, t, w, q) }
                        }
                    }
                }
            }
        }
        guard let b = best else { return nil }
        let a = mesh.positions[Int(mesh.indices[3 * b.t])], u = mesh.positions[Int(mesh.indices[3 * b.t + 1])] - a,
            v = mesh.positions[Int(mesh.indices[3 * b.t + 2])] - a
        let n = simd_normalize(simd_cross(u, v))
        return (SIMD3(mesh.indices[3 * b.t], mesh.indices[3 * b.t + 1], mesh.indices[3 * b.t + 2]), b.w, simd_dot(p - b.q, n))
    }

    /// The point of triangle (a, b, c) nearest `p`, and its weights for b and c (Ericson's Real-Time Collision Detection).
    static func closest(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (SIMD3<Float>, SIMD2<Float>) {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (a, .zero) }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (b, [1, 0]) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return (a + ab * v, [v, 0]) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (c, [0, 1]) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return (a + ac * w, [0, w]) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (b + (c - b) * w, [1 - w, w])
        }
        let denom = 1 / (va + vb + vc), v = vb * denom, w = vc * denom
        return (a + ab * v + ac * w, [v, w])
    }
}

extension PhysicsWorld {
    /// How the skin is made: its links' compliance across and bending, how hard it is held along the flesh's normal
    /// and across it, how far it may slide, how heavy it is (kg/m^2), and its particles' radius.
    struct SkinOptions {
        var stretch: Float = 1e-6
        var bend: Float = 1e-3
        var normal: Float = 0
        var slide: Float = 2e-4
        var maxSlide: Float = 0.02
        var density: Float = 3
        var radius: Float = 0.006
    }

    /// A skin shell over `flesh` (its figure's): `mesh`, a surface of the flesh's shape in its rest space, each vertex
    /// a particle held to where it rests in the flesh (and 1 cm under it, its normal), starting where the flesh puts it.
    func addSkin(_ mesh: MeshGeometry, over flesh: Flesh, figure: FleshFigure, _ o: SkinOptions = SkinOptions()) -> SkinShell {
        let first = particles.count, base = UInt32(first), bones = figure.bodies
        // Each vertex's share of the area.
        var area = [Float](repeating: 0, count: mesh.positions.count)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])], c = mesh.positions[Int(mesh.indices[t + 2])]
            let third = simd_length(simd_cross(b - a, c - a)) / 6
            for k in 0..<3 { area[Int(mesh.indices[t + k])] += third }
        }
        let fleshBase = UInt32(flesh.first)
        for (v, p) in mesh.positions.enumerated() {
            // Where it rests in the flesh, and a point 1 cm under it in the same tet.
            let found = flesh.model.locate(p) ?? (0, .zero)
            let ids = flesh.model.tets[found.tet] &+ fleshBase
            let deep = flesh.model.bary(p - mesh.normals[v] * 0.01, in: found.tet)
            var attach = GPUSkinAttach()
            attach.bary = SIMD4(found.bary, o.maxSlide)
            attach.deep = SIMD4(deep, o.slide)
            attach.ids = ids
            attach.particle = UInt32(first + v)
            attach.compliance = o.normal
            skinAttachments.append(attach)
            let x = inTet(ids, attach.bary)
            particles.append(GPUPhysicsParticle(position: SIMD4(x, o.radius), velocity: SIMD4(.zero, 0.6),
                                                prevPosition: SIMD4(x, 1 / max(o.density * area[v], 1e-7)),
                                                info: SIMD4(PhysicsWorld.none, PhysicsWorld.softBit | PhysicsWorld.skinBit,
                                                            UInt32(bones.lowerBound) << 8 | UInt32(bones.count), UInt32(flesh.body))))
        }
        // Its links: each triangle's edges (once), and across each edge the two triangles' far corners (its bend).
        var edges: [SIMD2<UInt32>: [UInt32]] = [:]
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            for k in 0..<3 {
                let a = mesh.indices[t + k], b = mesh.indices[t + (k + 1) % 3], far = mesh.indices[t + (k + 2) % 3]
                edges[SIMD2(min(a, b), max(a, b)), default: []].append(far)
            }
        }
        func link(_ a: UInt32, _ b: UInt32, _ compliance: Float) {
            unsortedConstraints.append(GPUPhysicsConstraint(a: a + base, b: b + base,
                                                            rest: simd_length(mesh.positions[Int(a)] - mesh.positions[Int(b)]), compliance: compliance))
        }
        for (e, far) in edges.sorted(by: { $0.key.x != $1.key.x ? $0.key.x < $1.key.x : $0.key.y < $1.key.y }) {
            link(e.x, e.y, o.stretch)
            if far.count == 2 && far[0] != far[1] { link(far[0], far[1], o.bend) }
        }
        return SkinShell(mesh: mesh, first: first)
    }
}
