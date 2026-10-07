import Foundation
import simd

/// A soft body's make-up, in its shape's space (PhysicsWorld.addSoftBody places it): a lattice of tetrahedra filling
/// the SDF shape, whose corners are particles, and the shape's surface, each of its vertices embedded in a tet.
///
/// The lattice is a cubic grid of `spacing` over the shape, each cube kept whose centre is inside the shape shrunk by
/// a particle's radius (`radiusShare` of the spacing), cut into six tets along its main diagonal (Freudenthal's: every
/// cube the same way, so neighbours share their faces). The corners on the lattice's outside are moved onto the shrunk
/// shape, in or out, so that the particles' balls reach the shape's surface: what touches the floor or another soft
/// body is where the drawn surface is. The drawn surface (surface nets, SDFShape.triangles) follows its tets: each
/// vertex at fixed weights of the four corners of the tet it is in and of those its ring's vertices are in, averaged
/// (a little outside the lattice's hull, the weights go past 0 and 1, and one tet's alone creases the surface where
/// two tets bend apart); its normal across the triangles around it (`rings`).
struct SoftModel {
    var spacing: Float
    var points: [SIMD3<Float>] = []
    /// Each particle's share of the volume (a quarter of each of its tets').
    var shares: [Float] = []
    var tets: [SIMD4<UInt32>] = []
    var edges: [SIMD2<UInt32>] = []
    var surface: MeshGeometry = ([], [], [])
    /// Per surface vertex: the tets it follows (its own first) and its weights for each one's last three corners
    /// (GPUSoftEmbed).
    var embedding: [[(tet: Int, bary: SIMD3<Float>)]] = []
    /// Per surface vertex, the triangles around it as their other two vertices, wound so that (b - v) x (c - v) faces
    /// out: its normal is their sum (area-weighted).
    var rings: [[SIMD2<UInt32>]] = []

    /// A particle's radius, a share of the spacing: its ball reaches the surface, and its neighbours' leave no gap
    /// another's fits through (0.3 of the spacing between two, a ball 0.7 across). The drawn surface is as far outside
    /// the lattice, where its tets' bends crease it.
    static let radiusShare: Float = 0.35
    var radius: Float { spacing * SoftModel.radiusShare }

    /// The lattice's cubes (their lowest corners' grid places: lattice point `origin` + place x `spacing`), each tet's,
    /// and each tet's rest frame's inverse (its first corner, its edges from there): what finds the tet a point is in.
    var origin = SIMD3<Float>()
    var tetCells: [SIMD3<Int32>] = []
    var inverses: [simd_float3x3] = []

    /// `cells` cubes along the shape's longest side (and at least two thirds as many along its shortest); the drawn
    /// surface from `surfaceCells` along its longest.
    init(_ shape: SDFShape, cells: Int, surfaceCells: Int = 20, volumes: [SDFVolume] = []) {
        let box = shape.bounds(volumes: volumes)
        let cells = Float(max(cells, 1))
        let s = min(simd_reduce_max(box.hi - box.lo) / cells, simd_reduce_min(box.hi - box.lo) / (cells * 2 / 3))
        self.init(shape, spacing: s, volumes: volumes)
        // The drawn surface, on the shape, each vertex in the tet it is most inside of among those near it.
        let tris = shape.triangles(cells: surfaceCells, push: 0, volumes: volumes)
        let normals = tris.positions.map { p -> SIMD3<Float> in
            let g = shape.gradient(p, h: s * 0.02, volumes: volumes)
            return dot(g, g) > 1e-12 ? normalize(g) : SIMD3(0, 1, 0)
        }
        let own = tris.positions.map { p -> Int in
            guard let found = locate(p) else { preconditionFailure("a surface vertex far from its soft body's lattice") }
            return found.tet
        }
        embed((tris.positions, normals, tris.indices), in: own)
    }

    /// The lattice alone, of `spacing` (no drawn surface yet: `embed`).
    init(_ shape: SDFShape, spacing s: Float, volumes: [SDFVolume] = []) {
        spacing = s
        let r = s * SoftModel.radiusShare
        func eroded(_ p: SIMD3<Float>) -> Float { shape.distance(p, volumes: volumes).d + r }
        let box = shape.bounds(volumes: volumes)
        let lo = box.lo - s
        origin = lo
        let n = SIMD3<Int>(((box.hi - box.lo) / s).rounded(.up)) &+ 2
        // The cubes kept, and their corners, once each.
        var index: [SIMD3<Int32>: UInt32] = [:]
        var cubes: [SIMD3<Int32>] = []
        func corner(_ c: SIMD3<Int32>) -> UInt32 {
            if let i = index[c] { return i }
            index[c] = UInt32(points.count)
            points.append(lo + SIMD3<Float>(c) * s)
            return UInt32(points.count - 1)
        }
        for z in 0..<n.z {
            for y in 0..<n.y {
                for x in 0..<n.x {
                    // Inside the shrunk shape, and no corner much outside it (moved onto it, it would crush its tets).
                    let c = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    let corner = lo + SIMD3<Float>(c) * s
                    guard eroded(corner + 0.5 * s) < 0 else { continue }
                    if (0..<8).allSatisfy({ eroded(corner + SIMD3<Float>(Float($0 & 1), Float(($0 >> 1) & 1), Float(($0 >> 2) & 1)) * s) < 0.4 * s }) {
                        cubes.append(c)
                    }
                }
            }
        }
        precondition(!cubes.isEmpty, "a soft body thinner than its lattice: give it more cells")
        // Six tets a cube: from its lowest corner to its highest along the axes in each order.
        let orders: [(Int, Int)] = [(0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 1)]
        for c in cubes {
            for (a, b) in orders {
                var ea = SIMD3<Int32>(), eb = SIMD3<Int32>()
                ea[a] = 1
                eb[b] = 1
                var t = SIMD4(corner(c), corner(c &+ ea), corner(c &+ ea &+ eb), corner(c &+ 1))
                if SoftModel.sixVolume(points, t) < 0 { t = SIMD4(t.x, t.y, t.w, t.z) }
                tets.append(t)
                tetCells.append(c)
            }
        }
        // The corners on the lattice's outside (a corner of a cube not kept) onto the shrunk shape, halving a move until
        // none of its tets is crushed.
        let kept = Set(cubes)
        var outside = [Bool](repeating: false, count: points.count)
        for (c, i) in index {
            for k in 0..<8 where !kept.contains(c &- SIMD3<Int32>(Int32(k & 1), Int32((k >> 1) & 1), Int32((k >> 2) & 1))) {
                outside[Int(i)] = true
            }
        }
        var moves = points.indices.map { i -> SIMD3<Float> in
            guard outside[i] else { return .zero }
            let p = points[i], g = shape.gradient(p, h: s * 0.05, volumes: volumes)
            return dot(g, g) > 1e-12 ? -normalize(g) * eroded(p) : .zero
        }
        let rest = points
        for _ in 0..<8 {
            points = zip(rest, moves).map { $0 + $1 }
            var crushed = false
            for t in tets where SoftModel.sixVolume(points, t) < 0.05 * s * s * s {
                crushed = true
                for i in [t.x, t.y, t.z, t.w] { moves[Int(i)] *= 0.5 }
            }
            if !crushed { break }
        }
        points = zip(rest, moves).map { $0 + $1 }
        shares = [Float](repeating: 0, count: points.count)
        var links = Set<SIMD2<UInt32>>()
        for t in tets {
            let v = SoftModel.sixVolume(points, t) / 6
            let ids = [t.x, t.y, t.z, t.w]
            for i in ids { shares[Int(i)] += v / 4 }
            for a in 0..<4 {
                for b in (a + 1)..<4 { links.insert(SIMD2(min(ids[a], ids[b]), max(ids[a], ids[b]))) }
            }
        }
        edges = links.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        inverses = tets.map { t in
            let p0 = points[Int(t.x)]
            return simd_float3x3(columns: (points[Int(t.y)] - p0, points[Int(t.z)] - p0, points[Int(t.w)] - p0)).inverse
        }
    }

    /// The lattice with only the tets `keep` says, and the points, links and shares they have (renumbered; before a
    /// surface is embedded).
    mutating func prune(keeping keep: [Bool]) {
        let kept = tets.indices.filter { keep[$0] }
        var used = [Int](repeating: -1, count: points.count), renumbered: [SIMD3<Float>] = []
        for t in kept {
            for i in [tets[t].x, tets[t].y, tets[t].z, tets[t].w] where used[Int(i)] < 0 {
                used[Int(i)] = renumbered.count
                renumbered.append(points[Int(i)])
            }
        }
        func map(_ t: SIMD4<UInt32>) -> SIMD4<UInt32> {
            SIMD4(UInt32(used[Int(t.x)]), UInt32(used[Int(t.y)]), UInt32(used[Int(t.z)]), UInt32(used[Int(t.w)]))
        }
        tets = kept.map { map(tets[$0]) }
        tetCells = kept.map { tetCells[$0] }
        inverses = kept.map { inverses[$0] }
        points = renumbered
        nearCache = NearCache()
        shares = [Float](repeating: 0, count: points.count)
        var links = Set<SIMD2<UInt32>>()
        for t in tets {
            let v = SoftModel.sixVolume(points, t) / 6
            let ids = [t.x, t.y, t.z, t.w]
            for i in ids { shares[Int(i)] += v / 4 }
            for a in 0..<4 {
                for b in (a + 1)..<4 { links.insert(SIMD2(min(ids[a], ids[b]), max(ids[a], ids[b]))) }
            }
        }
        edges = links.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    }

    /// Point `p`'s weights in tet `t` (of its last three corners).
    func bary(_ p: SIMD3<Float>, in t: Int) -> SIMD3<Float> { inverses[t] * (p - points[Int(tets[t].x)]) }

    /// The tet `p` is most inside of among those within `reach` cubes of it (the nearest, if it is outside them all),
    /// and its weights there; nil if there are none.
    func locate(_ p: SIMD3<Float>, reach: Int32 = 4) -> (tet: Int, bary: SIMD3<Float>)? {
        if near.isEmpty {
            var cubes: [SIMD3<Int32>: [Int]] = [:]
            for (t, c) in tetCells.enumerated() { cubes[c, default: []].append(t) }
            near = cubes
        }
        let near = self.near
        let c = SIMD3<Int32>(((p - origin) / spacing).rounded(.down))
        var best = (tet: -1, bary: SIMD3<Float>(), inside: -Float.infinity)
        for r: Int32 in 1...reach where best.tet < 0 {
            for dz in -r...r {
                for dy in -r...r {
                    for dx in -r...r {
                        for t in near[c &+ SIMD3(dx, dy, dz)] ?? [] {
                            let b = bary(p, in: t)
                            let inside = min(min(b.x, b.y), min(b.z, 1 - b.x - b.y - b.z))
                            if inside > best.inside || (inside == best.inside && t < best.tet) { best = (t, b, inside) }
                        }
                    }
                }
            }
        }
        return best.tet < 0 ? nil : (best.tet, best.bary)
    }
    private var nearCache = NearCache()
    /// (The cubes' tets, made the first time a point is located.)
    private var near: [SIMD3<Int32>: [Int]] {
        get { nearCache.map }
        nonmutating set { nearCache.map = newValue }
    }
    private final class NearCache { var map: [SIMD3<Int32>: [Int]] = [:] }

    /// The drawn surface `mesh` (in the lattice's space), each vertex following the tet `own` gives it (-1: none: it is
    /// drawn some other way, PhysicsFlesh.swift) and those its ring's vertices follow. With `weld`, vertices at the
    /// same place share their ring (a mesh cut at its seams or made of pieces): its normal is smooth across them. A
    /// ring keeps 31 triangles at most.
    mutating func embed(_ mesh: MeshGeometry, in own: [Int], weld: Bool = false) {
        surface = mesh
        let positions = mesh.positions
        var key = Array(positions.indices)
        if weld {
            var first: [SIMD3<Float>: Int] = [:]
            for (v, p) in positions.enumerated() { key[v] = first[p] ?? v; if first[p] == nil { first[p] = v } }
        }
        var shared = [[SIMD2<UInt32>]](repeating: [], count: positions.count)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[t], b = mesh.indices[t + 1], c = mesh.indices[t + 2]
            shared[key[Int(a)]].append(SIMD2(b, c))
            shared[key[Int(b)]].append(SIMD2(c, a))
            shared[key[Int(c)]].append(SIMD2(a, b))
        }
        rings = positions.indices.map { Array(shared[key[$0]].prefix(31)) }
        embedding = positions.indices.map { v in
            guard own[v] >= 0 else { return [] }
            var follows = [own[v]]
            for pair in rings[v] {
                for u in [pair.x, pair.y] where own[Int(u)] >= 0 && !follows.contains(own[Int(u)]) { follows.append(own[Int(u)]) }
            }
            return follows.map { t in (t, bary(positions[v], in: t)) }
        }
        // Wound as the surface's normals face (surface nets' winding, whichever way it is).
        let agree = rings.indices.filter { dot(SoftModel.ringNormal(rings[$0], at: $0, positions), mesh.normals[$0]) > 0 }.count
        if agree < rings.count / 2 { rings = rings.map { $0.map { SIMD2($0.y, $0.x) } } }
    }

    /// The area-weighted normal at vertex `v` across the triangles of its ring, of `positions`.
    static func ringNormal(_ ring: [SIMD2<UInt32>], at v: Int, _ positions: [SIMD3<Float>]) -> SIMD3<Float> {
        let p = positions[v]
        return ring.reduce(SIMD3<Float>()) { $0 + cross(positions[Int($1.x)] - p, positions[Int($1.y)] - p) }
    }

    /// Six times tet `t`'s volume (positive when it is wound the right way).
    static func sixVolume(_ points: [SIMD3<Float>], _ t: SIMD4<UInt32>) -> Float {
        let p0 = points[Int(t.x)]
        return dot(cross(points[Int(t.y)] - p0, points[Int(t.z)] - p0), points[Int(t.w)] - p0)
    }
}

/// Soft bodies: tetrahedral lattices whose corners are particles (SoftModel), held by XPBD constraints on their edges'
/// lengths (with the cloths' links) and on their tets' volumes (Müller et al. 2020; Macklin et al. 2016's damping),
/// in the particles' substeps. Their particles meet the colliders and the other soft bodies' particles as any
/// particle does, not their own body's; like the cloths, they don't push the bodies back.
extension PhysicsWorld {
    /// How fast the air slows a soft body's particles (1/s), and how much its links' and tets' constraints damp what
    /// moves along them (s, XPBD's beta): what stops a jelly wobbling on for ever.
    static let softDrag: Float = 0.3
    static let softLinkDamping: Float = 3
    static let maxTetColours = 64
    /// The fastest a soft body's particle is pushed out of an overlap (m/s): faster than any particle's
    /// (`pushSpeed`), so that a ball rolling into a jelly at a few metres a second shoves it rather than sinks in.
    static let softPushSpeed: Float = 10

    /// A soft body made of `model`, placed by `transform` (a rotation and a translation); its drawn vertices start at
    /// `vertexBase` in the scene's vertex buffer, moving at `velocity`. `density` kg/m^3; `edge` and `volume`: the
    /// links' and the tets' compliance (0: rigid); `damping`: the tets' (s).
    @discardableResult
    func addSoftBody(_ model: SoftModel, transform: float4x4, vertexBase: Int, velocity: SIMD3<Float> = .zero, density: Float = 1000,
                     edge: Float = 1e-3, volume: Float = 1e-9, damping: Float = PhysicsWorld.softLinkDamping, friction: Float = 0.6) -> Int {
        let first = particles.count, body = softBodies.count
        let world = model.points.map { PhysicsMath.xyz(transform * SIMD4($0, 1)) }
        for (x, share) in zip(world, model.shares) {
            particles.append(GPUPhysicsParticle(position: SIMD4(x, model.radius), velocity: SIMD4(velocity, friction),
                                                prevPosition: SIMD4(x, 1 / max(density * share, 1e-6)),
                                                info: SIMD4(PhysicsWorld.none, PhysicsWorld.softBit, 0, UInt32(body))))
        }
        let base = UInt32(first)
        for e in model.edges {
            unsortedConstraints.append(GPUPhysicsConstraint(a: e.x + base, b: e.y + base, rest: length(world[Int(e.x)] - world[Int(e.y)]),
                                                            compliance: edge))
        }
        for t in model.tets {
            unsortedTets.append(GPUPhysicsTet(ids: t &+ base, rest: SoftModel.sixVolume(world, t), compliance: volume, damping: damping))
        }
        for (v, follows) in model.embedding.enumerated() {
            let ring = UInt32(softRings.count) << 5 | UInt32(model.rings[v].count)
            precondition(model.rings[v].count < 32 && softRings.count < 1 << 27, "a ring of 32 triangles or more")
            softRings += model.rings[v].map { $0 &+ UInt32(vertexBase) }
            softVertices.append(GPUSoftVertex(info: SIMD4(UInt32(vertexBase + v), 0, UInt32(body), ring),
                                              embeds: SIMD4(UInt32(softEmbeds.count), UInt32(follows.count), 0, 0)))
            let share = 1 / Float(follows.count)
            softEmbeds += follows.map { GPUSoftEmbed(bary: SIMD4($0.bary, share), ids: model.tets[$0.tet] &+ base) }
        }
        softBodies.append(SIMD2(UInt32(first), UInt32(model.points.count)))
        return body
    }

    /// The tets in colours, as the cloths' links are: each takes the first colour none of its particles' tets has.
    static func colourTets(_ unsorted: [GPUPhysicsTet]) -> (tets: [GPUPhysicsTet], starts: [UInt32]) {
        var used: [UInt32: UInt64] = [:]
        var colour = [Int](repeating: 0, count: unsorted.count)
        for (i, t) in unsorted.enumerated() {
            let ids = [t.ids.x, t.ids.y, t.ids.z, t.ids.w]
            let c = (~ids.reduce(UInt64(0)) { $0 | (used[$1] ?? 0) }).trailingZeroBitCount
            precondition(c < maxTetColours, "a particle in more than \(maxTetColours - 1) tets")
            colour[i] = c
            for id in ids { used[id, default: 0] |= 1 << c }
        }
        var buckets = [[GPUPhysicsTet]](repeating: [], count: (colour.max() ?? -1) + 1)
        for (i, t) in unsorted.enumerated() { buckets[colour[i]].append(t) }
        var starts: [UInt32] = [0]
        for b in buckets { starts.append(starts.last! + UInt32(b.count)) }
        return (buckets.flatMap { $0 }, starts)
    }

    /// Whether particles `q` and `o` may push each other: not a cloth's, nor two of one soft body's.
    @inline(__always) static func meets(_ q: GPUPhysicsParticle, _ o: GPUPhysicsParticle) -> Bool {
        (q.info.y | o.info.y) & clothBit == 0 && !(q.info.y & o.info.y & softBit != 0 && q.info.w == o.info.w)
    }

    /// The tets' volumes, a colour at a time (Gauss-Seidel), each an XPBD constraint on six times its volume with
    /// Macklin et al. 2016's damping along its gradient (one iteration a substep, so its lambda starts at 0).
    func solveTets(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for c in 0..<(tetStarts.count - 1) {
            for k in Int(tetStarts[c])..<Int(tetStarts[c + 1]) { solveTet(tets[k], h) }
        }
    }

    private func solveTet(_ t: GPUPhysicsTet, _ h: Float) {
        // A muscle's fibre first, then the volume: the last word is the volume's, so a contracting tet bulges (after
        // it, each pass's fibre took back the volume the pass before had put back).
        if t.fibre != 0 { solveFibre(t, h) }
        let i = [Int(t.ids.x), Int(t.ids.y), Int(t.ids.z), Int(t.ids.w)]
        let x = i.map { PhysicsMath.xyz(particles[$0].position) }
        let w = i.map { particles[$0].prevPosition.w }
        let a = x[1] - x[0], b = x[2] - x[0], c = x[3] - x[0]
        let g1 = cross(b, c), g2 = cross(c, a), g3 = cross(a, b)
        let g = [-(g1 + g2 + g3), g1, g2, g3]
        let alpha = t.compliance / (h * h), gamma = t.compliance * t.damping / h
        var sum: Float = 0, moved: Float = 0
        for k in 0..<4 {
            sum += w[k] * length_squared(g[k])
            moved += dot(g[k], x[k] - PhysicsMath.xyz(particles[i[k]].prevPosition))
        }
        let denominator = (1 + gamma) * sum + alpha
        guard denominator > 1e-12 else { return }
        let lambda = (-(dot(g3, c) - t.rest) - gamma * moved) / denominator   // 6V = (a x b) . c
        for k in 0..<4 { particles[i[k]].position += SIMD4(g[k] * (lambda * w[k]), 0) }
    }

    /// Soft body `body`'s volume now (m^3): its tets'.
    func softVolume(_ body: Int) -> Float {
        let range = softBodies[body].x..<(softBodies[body].x + softBodies[body].y)
        let points = particles.map { PhysicsMath.xyz($0.position) }
        return tets.filter { range.contains($0.ids.x) }.reduce(0) { $0 + SoftModel.sixVolume(points, $1.ids) } / 6
    }

    /// Drawn vertex `v` where the particles (and bodies) are: where each of its tets puts it, averaged (MSL
    /// physicsSoftMeshKernel); or a body, or a skin's triangle (PhysicsFlesh.swift).
    func drawnSoftVertex(_ v: Int, particles: [GPUPhysicsParticle]? = nil, bodies: [GPUPhysicsBody]? = nil) -> SIMD3<Float> {
        let q = particles ?? self.particles, s = softVertices[v]
        var p = SIMD3<Float>()
        for e in softEmbeds[Int(s.embeds.x)..<Int(s.embeds.x + s.embeds.y)] {
            if e.ids.w == GPUSoftEmbed.bodyKind {
                let b = (bodies ?? self.bodies)[Int(e.ids.x)]
                p += (PhysicsMath.xyz(b.position) + PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(e.bary))) * e.bary.w
                continue
            }
            if e.ids.w == GPUSoftEmbed.triangleKind {
                let a = PhysicsMath.xyz(q[Int(e.ids.x)].position)
                let u = PhysicsMath.xyz(q[Int(e.ids.y)].position) - a, w = PhysicsMath.xyz(q[Int(e.ids.z)].position) - a
                let n = cross(u, w), l = length(n)
                p += (a + u * e.bary.x + w * e.bary.y + (l > 1e-12 ? n / l : SIMD3(0, 1, 0)) * e.bary.z) * e.bary.w
                continue
            }
            let x0 = PhysicsMath.xyz(q[Int(e.ids.x)].position)
            let e1 = PhysicsMath.xyz(q[Int(e.ids.y)].position) - x0
            let e2 = PhysicsMath.xyz(q[Int(e.ids.z)].position) - x0
            let e3 = PhysicsMath.xyz(q[Int(e.ids.w)].position) - x0
            p += (x0 + e1 * e.bary.x + e2 * e.bary.y + e3 * e.bary.z) * e.bary.w
        }
        return p
    }

    /// Drawn vertex `v`'s normal across its ring, the drawn vertices at `position` (by their place in the scene's
    /// vertex buffer; MSL physicsSoftNormalsKernel).
    func drawnSoftNormal(_ v: Int, position: (Int) -> SIMD3<Float>) -> SIMD3<Float> {
        let s = softVertices[v], p = position(Int(s.info.x))
        var n = SIMD3<Float>()
        for k in Int(s.info.w >> 5)..<Int((s.info.w >> 5) + (s.info.w & 31)) {
            n += cross(position(Int(softRings[k].x)) - p, position(Int(softRings[k].y)) - p)
        }
        return length_squared(n) > 1e-20 ? normalize(n) : SIMD3(0, 1, 0)
    }
}
