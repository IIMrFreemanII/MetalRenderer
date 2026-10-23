import EngineCore
import Foundation
import simd

/// A car's drawn panels: its model's (CarPack) body, its paint and lamps as one mesh, its glass as another (drawn as
/// glass), each vertex embedded in the node hull's triangles so that the GPU draws it where the nodes are (MSL
/// physicsSoftMeshKernel's triangle embeds: BeamNG's flexbodies). A vertex follows the hull triangle nearest it, and
/// those its neighbours follow, averaged (as a soft body's do: one triangle's alone creases the surface where two bend
/// apart).
///
/// Each triangle is on the part of the body (CarBlueprint.Part) over the hull triangle nearest it, or on the body, and
/// follows only that part's triangles: a door's panels go with the door when it comes off (a vertex two parts share
/// is two vertices, one on each). The glass is cut into panes (`panes`) by which way it faces and where, the lamps
/// into the four corners' (a pane or lamp is on the part most of it is over); each of their vertices names its pane
/// (`Part.flags`), which folds away (a pane) or goes dark (a lamp) when it breaks (CarDamage.swift).
package struct CarSurface {
    /// A mesh and where its vertices are embedded: per vertex the hull triangles it follows (its own first) and its
    /// place over each (the weights of its second and third nodes, how far out along its normal); the triangles round
    /// each vertex (as SoftModel.rings); per triangle its material's offset; per vertex its pane or lamp
    /// (PhysicsWorld.carVertexBit's flags: 1 + its place in `panes`, `lampBit`).
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

    /// A model's panels on blueprint `b` (fitted to it: CarSpec.fitted): its paint and lamps as the body (their materials'
    /// offsets 0 and 1: Scene.addCar makes them in that order), its glass. A seam's copies of one place (split for their
    /// texture coordinates or their normals) follow it alike, so it can't open, and those whose normals agree share
    /// their rings too, so the shading stays smooth across it (a hard edge's keep their own).
    package init(_ b: CarBlueprint, model: CarModel) {
        let glassPanes = CarSurface.glassPanes(model.glass, b), lampPanes = CarSurface.lampPanes(model.lamps)
        let glassCount = (glassPanes.max() ?? -1) + 1
        panes = (0..<glassCount).map { _ in Pane(lamp: false, part: 0, hull: []) }
            + (0..<((lampPanes.max() ?? -1) + 1)).map { _ in Pane(lamp: true, part: 0, hull: []) }
        body = part([(model.paint, 0, []), (model.lamps, 1, lampPanes.map { glassCount + $0 })], b)
        glass = part([(model.glass, 0, glassPanes)], b)
    }

    /// Mesh `meshes`' panels (each with its material's offset and, per triangle, its pane: -1 none) on `b`, the panes'
    /// parts and triangles noted in `panes`.
    private mutating func part(_ meshes: [(CarModel.Mesh, UInt8, [Int])], _ b: CarBlueprint) -> Part {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        var materials: [UInt8] = [], paneOf: [Int] = []
        for (m, material, panes) in meshes {
            let base = UInt32(positions.count)
            positions += m.positions
            normals += m.normals
            uvs += m.uvs.count == m.positions.count ? m.uvs : [SIMD2<Float>](repeating: .zero, count: m.positions.count)
            indices += m.indices.map { $0 + base }
            materials += [UInt8](repeating: material, count: m.indices.count / 3)
            paneOf += panes.count == m.indices.count / 3 ? panes : [Int](repeating: -1, count: m.indices.count / 3)
        }
        // Each triangle's part: the mirror's it is in, or the part over the body's hull triangle nearest its middle.
        var under = [Int](repeating: 0, count: b.hull.count)
        for (p, part) in b.parts.enumerated() { for t in part.under { under[t] = p + 1 } }
        let mirrors = b.parts.indices.filter { b.parts[$0].kind == .mirror }
        let body = b.hull.indices.filter { b.hullPart[$0] == 0 }
        var partOf = [Int](repeating: 0, count: indices.count / 3)
        for t in partOf.indices {
            let c = (positions[Int(indices[3 * t])] + positions[Int(indices[3 * t + 1])] + positions[Int(indices[3 * t + 2])]) / 3
            if let m = mirrors.first(where: { CarSurface.inMirror(c, b, side: b.parts[$0].side) }) {
                partOf[t] = m + 1
            } else {
                partOf[t] = under[CarSurface.nearestHull(c, b, among: body)]
            }
        }
        // The vertices split by part and pane: a vertex of triangles on two parts (or panes) is one on each.
        var split: [SIMD3<Int32>: UInt32] = [:]
        var source: [Int] = [], vertexPart: [Int] = [], vertexPane: [Int] = []
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
        // The triangles each part's vertices may follow: its own (the body's: the body's hull).
        let among = (0...b.parts.count).map { p in p == 0 ? body : b.parts[p - 1].triangles }
        var nearest: [SIMD4<Int32>: Int] = [:]
        func hull(_ v: UInt32) -> Int {
            let k = key(Int(v))
            if let h = nearest[k] { return h }
            let h = CarSurface.nearestHull(positions[Int(v)], b, among: among[vertexPart[Int(v)]])
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
        // The panes: their parts (a side window's its door's; otherwise the one most of their triangles are on) and the
        // triangles their vertices are on.
        var flags = [UInt32](repeating: 0, count: positions.count)
        var votes = [[Int]](repeating: [Int](repeating: 0, count: b.parts.count + 1), count: panes.count)
        var hulls = [Set<Int>](repeating: [], count: panes.count)
        var middles = [SIMD4<Float>](repeating: .zero, count: panes.count)
        for (k, v) in indices.enumerated() {
            let pane = vertexPane[Int(v)]
            guard pane >= 0 else { continue }
            flags[Int(v)] = UInt32(pane + 1) | (panes[pane].lamp ? PhysicsWorld.lampBit : 0)
            hulls[pane].insert(embedding[Int(v)][0].triangle)
            middles[pane] += SIMD4(positions[Int(v)], 1)
            if k % 3 == 0 { votes[pane][partOf[k / 3]] += 1 }
        }
        for j in panes.indices where !hulls[j].isEmpty {
            panes[j].hull = hulls[j].sorted()
            panes[j].part = votes[j].indices.max { votes[j][$0] < votes[j][$1] } ?? 0
            let c = PhysicsMath.xyz(middles[j]) / middles[j].w
            if !panes[j].lamp, let door = b.parts.firstIndex(where: { d in
                (d.kind == .frontDoor || d.kind == .rearDoor) && d.side * c.x > 0.5 * b.spec.halfWidth(c.z) && c.z > d.span.x - 0.15 && c.z < d.span.y + 0.15
            }) {
                panes[j].part = door + 1
            }
        }
        return Part(mesh: (positions, normals, indices), uvs: uvs, materials: materials, embedding: embedding, rings: rings, flags: flags)
    }

    /// The glass's panes, per triangle: the roof's (facing up), the windshield (facing forward, in front), the rear
    /// window (facing back, behind), and each side's, in front of and behind the front door's back (with rear doors).
    /// Numbered in that order, those with triangles only.
    package static func glassPanes(_ glass: CarModel.Mesh, _ b: CarBlueprint) -> [Int] {
        let split = b.parts.first { $0.kind == .frontDoor && $0.side > 0 }.flatMap { door in
            b.parts.contains { $0.kind == .rearDoor } ? door.span.x : nil
        }
        var kinds: [Int] = []
        for t in stride(from: 0, to: glass.indices.count, by: 3) {
            let a = glass.positions[Int(glass.indices[t])], u = glass.positions[Int(glass.indices[t + 1])], w = glass.positions[Int(glass.indices[t + 2])]
            let c = (a + u + w) / 3
            var n = cross(u - a, w - a)
            let smooth = glass.normals.isEmpty ? n : glass.normals[Int(glass.indices[t])] + glass.normals[Int(glass.indices[t + 1])]
                + glass.normals[Int(glass.indices[t + 2])]
            if dot(n, smooth) < 0 { n = -n }
            n = length(n) > 1e-12 ? normalize(n) : SIMD3(0, 1, 0)
            if n.y > 0.85 { kinds.append(0) }
            else if n.z > 0.4 && c.z > 0 { kinds.append(1) }
            else if n.z < -0.4 && c.z < 0 { kinds.append(2) }
            else { kinds.append((c.x > 0 ? 3 : 5) + (split.map { c.z < $0 ? 1 : 0 } ?? 0)) }
        }
        let used = Array(Set(kinds)).sorted()
        return kinds.map { used.firstIndex(of: $0)! }
    }

    /// The lamps' four corners, per triangle (front left, front right, rear left, rear right), those with triangles
    /// only, in that order.
    package static func lampPanes(_ lamps: CarModel.Mesh) -> [Int] {
        var kinds: [Int] = []
        for t in stride(from: 0, to: lamps.indices.count, by: 3) {
            let c = (lamps.positions[Int(lamps.indices[t])] + lamps.positions[Int(lamps.indices[t + 1])] + lamps.positions[Int(lamps.indices[t + 2])]) / 3
            kinds.append((c.z > 0 ? 0 : 2) + (c.x > 0 ? 0 : 1))
        }
        let used = Array(Set(kinds)).sorted()
        return kinds.map { used.firstIndex(of: $0)! }
    }

    /// Whether `p` is in the mirror's box on `side` (beyond the body's side, about its height, near it along the body).
    private static func inMirror(_ p: SIMD3<Float>, _ b: CarBlueprint, side: Float) -> Bool {
        guard let m = b.spec.mirror else { return false }
        return p.x * side > b.spec.halfWidth(p.z) + 0.02 && abs(p.y - m.y) < 0.2 && abs(p.z - m.z) < 0.3
    }

    /// The hull triangle among `among` nearest `p`.
    private static func nearestHull(_ p: SIMD3<Float>, _ b: CarBlueprint, among: [Int]) -> Int {
        var best = among.first ?? 0, nearest = Float.infinity
        for k in among {
            let t = b.hull[k]
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
