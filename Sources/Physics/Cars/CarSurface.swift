import EngineCore
import Foundation
import simd

/// A car's drawn panels: its model's (CarPack) meshes, all but its glass as one mesh (the body), its glass as another
/// (drawn as glass), each vertex embedded in the node hull's triangles so that the GPU draws it where the nodes are (MSL
/// physicsSoftMeshKernel's triangle embeds: BeamNG's flexbodies). A vertex follows the hull triangle nearest it, and
/// those its neighbours follow, averaged (as a soft body's do: one triangle's alone creases the surface where two bend
/// apart).
///
/// A mesh the model names as on a part (CarModel.Mesh.part: a door, the hood...) follows only that part's triangles
/// (CarBlueprint.Part), so it goes with the part when it comes off; the rest follow the body's (a mirror's, where the
/// model doesn't name its mirrors, its mirror's: where CarSpec.mirror found it). Each window is a pane, the lamps are
/// the four corners' (a lamp's glass with its corner's lamp); each of their vertices names its pane (`Part.flags`),
/// which folds away (a window, a lamp's glass) or goes dark (a lamp) when it breaks (CarDamage.swift).
package struct CarSurface {
    /// A mesh and where its vertices are embedded: per vertex the hull triangles it follows (its own first) and its
    /// place over each (the weights of its second and third nodes, how far out along its normal); the triangles round
    /// each vertex (as SoftModel.rings); per triangle its material's offset (its place in the model's materials); per
    /// vertex its pane or lamp (PhysicsWorld.carVertexBit's flags: 1 + its place in `panes`, `lampBit`).
    package struct Part {
        package var mesh: MeshGeometry = ([], [], [])
        package var uvs: [SIMD2<Float>] = []
        package var materials: [UInt8] = []
        package var embedding: [[(triangle: Int, bary: SIMD3<Float>)]] = []
        package var rings: [[SIMD2<UInt32>]] = []
        package var flags: [UInt32] = []
    }

    /// A pane of the glass or a lamp (CarPane's): the part it is on (1 + its place in the blueprint's, 0: the body),
    /// the hull triangles its vertices are on (its frame is the beams among their nodes).
    package struct Pane {
        package var lamp: Bool
        package var part: Int
        package var hull: [Int]
    }

    package var body = Part()
    package var glass = Part()
    package var panes: [Pane] = []

    /// A model's panels on blueprint `b` (fitted to it: CarSpec.fitted). A seam's copies of one place (split for their
    /// texture coordinates or their normals) follow it alike, so it can't open, and those whose normals agree share
    /// their rings too, so the shading stays smooth across it (a hard edge's keep their own).
    package init(_ b: CarBlueprint, model: CarModel) {
        // The panes: the windows, then the lamps' corners (those with lamps).
        let lit = model.meshes.filter { $0.role == .lamp || $0.role == .lampGlass }
        let corners = Set(lit.flatMap { m in stride(from: 0, to: m.indices.count, by: 3).map { CarSurface.corner(m, triangle: $0 / 3) } }).sorted()
        panes = (0..<model.windows).map { _ in Pane(lamp: false, part: 0, hull: []) } + corners.map { _ in Pane(lamp: true, part: 0, hull: []) }
        let lampPane = Dictionary(uniqueKeysWithValues: corners.enumerated().map { ($1, model.windows + $0) })
        var grids = Grids(b)
        body = part(model.meshes.filter { !$0.role.isGlass }, b, lampPane, &grids)
        glass = part(model.meshes.filter(\.role.isGlass), b, lampPane, &grids)
    }

    /// Lamp triangle `t`'s corner of the car: front left, front right, rear left, rear right.
    private static func corner(_ m: CarModel.Mesh, triangle t: Int) -> Int {
        let c = m.positions[Int(m.indices[3 * t])] + m.positions[Int(m.indices[3 * t + 1])] + m.positions[Int(m.indices[3 * t + 2])]
        return (c.z > 0 ? 0 : 2) + (c.x > 0 ? 0 : 1)
    }

    /// Meshes `meshes`' panels on `b`, the panes' parts and triangles noted in `panes`.
    private mutating func part(_ meshes: [CarModel.Mesh], _ b: CarBlueprint, _ lampPane: [Int: Int], _ grids: inout Grids) -> Part {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        var materials: [UInt8] = [], paneOf: [Int] = [], partOf: [Int] = [], litOf: [Bool] = []
        for m in meshes {
            let base = UInt32(positions.count), triangles = m.indices.count / 3
            positions += m.positions
            normals += m.normals.count == m.positions.count ? m.normals : [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: m.positions.count)
            uvs += m.uvs.count == m.positions.count ? m.uvs : [SIMD2<Float>](repeating: .zero, count: m.positions.count)
            indices += m.indices.map { $0 + base }
            materials += [UInt8](repeating: UInt8(clamping: max(m.material, 0)), count: triangles)
            litOf += [Bool](repeating: m.role == .lamp, count: triangles)
            // Its part: the one the model names (the blueprint's of that kind and side), or the body (a mirror's: its
            // mirror's, where the model doesn't name it).
            let named = m.part.flatMap { kind in b.parts.firstIndex { $0.kind == kind && $0.side == m.side }.map { $0 + 1 } }
            for t in 0..<triangles {
                switch m.role {
                case .window: paneOf.append(m.window)
                case .lamp, .lampGlass: paneOf.append(lampPane[CarSurface.corner(m, triangle: t)] ?? -1)
                default: paneOf.append(-1)
                }
                if let named {
                    partOf.append(named)
                    continue
                }
                let c = (m.positions[Int(m.indices[3 * t])] + m.positions[Int(m.indices[3 * t + 1])] + m.positions[Int(m.indices[3 * t + 2])]) / 3
                partOf.append(b.parts.indices.first { b.parts[$0].kind == .mirror && CarSurface.inMirror(c, b, side: b.parts[$0].side) }.map { $0 + 1 } ?? 0)
            }
        }
        // The vertices split by part and pane: a vertex of triangles on two parts (or panes) is one on each.
        var split: [SIMD3<Int32>: UInt32] = [:]
        var source: [Int] = [], vertexPart: [Int] = [], vertexPane: [Int] = [], vertexLit: [Bool] = []
        var newIndices = indices
        for (k, v) in indices.enumerated() {
            let t = k / 3, key = SIMD3(Int32(v), Int32(partOf[t]), Int32(paneOf[t]))
            if let u = split[key] {
                newIndices[k] = u
                continue
            }
            let u = UInt32(source.count)
            split[key] = u
            source.append(Int(v))
            vertexPart.append(partOf[t])
            vertexPane.append(paneOf[t])
            vertexLit.append(litOf[t])
            newIndices[k] = u
        }
        positions = source.map { positions[$0] }
        normals = source.map { normals[$0] }
        uvs = source.map { uvs[$0] }
        indices = newIndices
        // Each vertex's own ring, and the copies of its place (on its part and pane).
        var own = [[SIMD2<UInt32>]](repeating: [], count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[t], c1 = indices[t + 1], c2 = indices[t + 2]
            own[Int(a)].append(SIMD2(c1, c2))
            own[Int(c1)].append(SIMD2(c2, a))
            own[Int(c2)].append(SIMD2(a, c1))
        }
        func key(_ v: Int) -> SIMD4<Int32> {
            let p = SIMD3<Int32>((positions[v] * 5000).rounded(.toNearestOrAwayFromZero))
            return SIMD4(p, Int32(vertexPart[v] << 8 | (vertexPane[v] + 1)))
        }
        var copies: [SIMD4<Int32>: [Int]] = [:]
        for v in positions.indices { copies[key(v), default: []].append(v) }
        // The triangle each place follows: its part's nearest.
        var nearest: [SIMD4<Int32>: Int] = [:]
        func hull(_ v: UInt32) -> Int {
            let k = key(Int(v))
            if let h = nearest[k] { return h }
            let h = grids.nearest(positions[Int(v)], part: vertexPart[Int(v)], b)
            nearest[k] = h
            return h
        }
        var rings = [[SIMD2<UInt32>]](repeating: [], count: positions.count)
        var embedding = [[(triangle: Int, bary: SIMD3<Float>)]](repeating: [], count: positions.count)
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
        // The panes: their parts (the one most of their triangles are on) and the triangles their vertices are on.
        var flags = [UInt32](repeating: 0, count: positions.count)
        var votes = [[Int]](repeating: [Int](repeating: 0, count: b.parts.count + 1), count: panes.count)
        var hulls = [Set<Int>](repeating: [], count: panes.count)
        for (k, v) in indices.enumerated() {
            let pane = vertexPane[Int(v)]
            guard pane >= 0 else { continue }
            flags[Int(v)] = UInt32(pane + 1) | (vertexLit[Int(v)] ? PhysicsWorld.lampBit : 0)
            hulls[pane].insert(embedding[Int(v)][0].triangle)
            if k % 3 == 0 { votes[pane][vertexPart[Int(v)]] += 1 }
        }
        for j in panes.indices where !hulls[j].isEmpty {
            panes[j].hull = Array(Set(panes[j].hull).union(hulls[j])).sorted()
            panes[j].part = votes[j].indices.max { votes[j][$0] < votes[j][$1] } ?? 0
        }
        return Part(mesh: (positions, normals, indices), uvs: uvs, materials: materials, embedding: embedding, rings: rings, flags: flags)
    }

    /// Per part (0: the body) a grid of the hull triangles its vertices may follow, made when first asked.
    private struct Grids {
        var grids: [Int: HullGrid] = [:]
        let among: [[Int]]

        init(_ b: CarBlueprint) {
            let body = b.hull.indices.filter { b.hullPart[$0] == 0 }
            among = (0...b.parts.count).map { p in p == 0 ? body : b.parts[p - 1].triangles }
        }

        mutating func nearest(_ p: SIMD3<Float>, part: Int, _ b: CarBlueprint) -> Int {
            if let g = grids[part] { return g.nearest(p, b) }
            let g = HullGrid(b, among: among[part])
            grids[part] = g
            return g.nearest(p, b)
        }
    }

    /// Hull triangles in a grid of cells (each in every cell its box meets), for the one nearest a point: the cells in
    /// rings out from its own, until no farther ring can hold a nearer one.
    private struct HullGrid {
        static let cell: Float = 0.2
        var lo = SIMD3<Float>(), hi = SIMD3<Float>()
        var size = SIMD3<Int>(1, 1, 1)
        var start: [Int32] = [0, 0]
        var items: [Int32] = []

        init(_ b: CarBlueprint, among: [Int]) {
            guard !among.isEmpty else { return }
            func box(_ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
                let t = b.hull[k], a = b.nodes[Int(t.x)], u = b.nodes[Int(t.y)], w = b.nodes[Int(t.z)]
                return (simd_min(a, simd_min(u, w)), simd_max(a, simd_max(u, w)))
            }
            lo = SIMD3(repeating: .infinity)
            hi = SIMD3(repeating: -.infinity)
            for k in among {
                let (l, h) = box(k)
                lo = simd_min(lo, l)
                hi = simd_max(hi, h)
            }
            size = simd_max(SIMD3<Int>(((hi - lo) / HullGrid.cell).rounded(.down)) &+ 1, SIMD3(repeating: 1))
            var cells = [[Int32]](repeating: [], count: size.x * size.y * size.z)
            for k in among {
                let (l, h) = box(k)
                let a = cellOf(l), c = cellOf(h)
                for z in a.z...c.z {
                    for y in a.y...c.y {
                        for x in a.x...c.x { cells[(z * size.y + y) * size.x + x].append(Int32(k)) }
                    }
                }
            }
            start = [0]
            for c in cells {
                items += c
                start.append(Int32(items.count))
            }
        }

        func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int> {
            simd_clamp(SIMD3<Int>(((p - lo) / HullGrid.cell).rounded(.down)), SIMD3(repeating: 0), size &- 1)
        }

        func nearest(_ p: SIMD3<Float>, _ b: CarBlueprint) -> Int {
            // (From the point's place in the grid's box: no triangle is nearer it than to the point.)
            let q = simd_clamp(p, lo, hi), c = cellOf(q)
            var best = Int(items.first ?? 0), nearest = Float.infinity
            for r in 0...max(size.x, size.y, size.z) {
                for z in max(c.z - r, 0)...min(c.z + r, size.z - 1) {
                    for y in max(c.y - r, 0)...min(c.y + r, size.y - 1) {
                        for x in max(c.x - r, 0)...min(c.x + r, size.x - 1) {
                            guard max(abs(x - c.x), abs(y - c.y), abs(z - c.z)) == r else { continue }
                            let cell = (z * size.y + y) * size.x + x
                            for i in Int(start[cell])..<Int(start[cell + 1]) {
                                let k = Int(items[i]), t = b.hull[k]
                                let d = CarSurface.distanceSquared(p, b.nodes[Int(t.x)], b.nodes[Int(t.y)], b.nodes[Int(t.z)])
                                if d < nearest || (d == nearest && k < best) { (best, nearest) = (k, d) }
                            }
                        }
                    }
                }
                // (A triangle not seen yet is in a cell r + 1 or more out: at least r cells from the point's place.)
                let reach = Float(r) * HullGrid.cell
                if nearest.isFinite && nearest <= reach * reach + simd_distance_squared(p, q) { break }
            }
            return best
        }
    }

    /// Whether `p` is in the mirror's box on `side` (beyond the body's side, about its height, near it along the body).
    private static func inMirror(_ p: SIMD3<Float>, _ b: CarBlueprint, side: Float) -> Bool {
        guard let m = b.spec.mirror else { return false }
        return p.x * side > b.spec.halfWidth(p.z) + 0.02 && abs(p.y - m.y) < 0.2 && abs(p.z - m.z) < 0.3
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
    fileprivate static func distanceSquared(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
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
