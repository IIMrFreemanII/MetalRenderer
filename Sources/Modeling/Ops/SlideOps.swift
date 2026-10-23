import Foundation
import simd

/// Edge slide (G G) and vertex slide (Shift-V): the selected edges' vertices move along the edges that leave them,
/// toward one side of the selection or the other, so the shape stays where it is. Each chain of selected edges (a
/// loop or a path) has two sides, A and B, found through its faces: a face that runs along the chain's direction is
/// on side A. A vertex with no selected edge (vertex slide) goes along whichever of its edges the mouse points down.
package struct EdgeSlide {
    package struct Item {
        package var vertex: Int32
        package var start: SIMD3<Float>
        /// Where the vertex goes at factor 1 (side A) and −1 (side B): the mean of the far ends of its edges on that
        /// side; nil where it has none (a boundary).
        package var sideA: SIMD3<Float>?
        package var sideB: SIMD3<Float>?
        /// A lone vertex's edges' far ends (vertex slide).
        package var ends: [SIMD3<Float>] = []
        /// The chain it is on (-1: a lone vertex).
        package var chain: Int
    }

    package private(set) var items: [Item]
    package let chains: Int

    /// The slide of `m`'s selection; nil if there's nothing to slide, or the selected edges branch (a vertex with
    /// three or more of them), which has no two sides.
    package init?(_ m: EditMesh) {
        let t = MeshTopology(m)
        var selectedEdgesOf: [Int32: [Int]] = [:]
        for e in 0..<m.edgeCount where m.isSelected(edge: e) && !m.isHidden(edge: e) {
            selectedEdgesOf[m.edges[e].x, default: []].append(e)
            selectedEdgesOf[m.edges[e].y, default: []].append(e)
        }
        if selectedEdgesOf.values.contains(where: { $0.count > 2 }) { return nil }
        var items: [Item] = []
        var index: [Int32: Int] = [:]
        // The chains, in order: from an end (a vertex with one selected edge), then what's left (closed loops).
        var used = Set<Int>()
        var chain = 0
        let starts = selectedEdgesOf.keys.sorted { (selectedEdgesOf[$0]!.count, $0) < (selectedEdgesOf[$1]!.count, $1) }
        for s in starts {
            guard let first = selectedEdgesOf[s]?.first(where: { !used.contains($0) }) else { continue }
            var verts: [Int32] = [s]
            var edge = first, v = s
            while !used.contains(edge) {
                used.insert(edge)
                v = MeshTopology.other(m, edge: edge, from: v)
                verts.append(v)
                guard let next = selectedEdgesOf[v]?.first(where: { !used.contains($0) }) else { break }
                edge = next
            }
            let closed = verts.count > 2 && verts.first == verts.last
            if closed { verts.removeLast() }
            var sumA: [Int32: (SIMD3<Float>, Int)] = [:], sumB: [Int32: (SIMD3<Float>, Int)] = [:]
            let onChain = Set(verts)
            for k in 0..<(closed ? verts.count : verts.count - 1) {
                let a = verts[k], b = verts[(k + 1) % verts.count]
                guard let e = t.edge(m, a, b) else { continue }
                for c in t.corners(ofEdge: e) {
                    let f = Int(t.cornerFace[Int(c)])
                    let r = m.corners(f)
                    guard let ca = r.first(where: { m.cornerVerts[$0] == a }), let cb = r.first(where: { m.cornerVerts[$0] == b }) else { continue }
                    let along = m.nextCorner(ca, face: f) == cb
                    // Side A (the face runs a → b): a's edge comes from the corner before it, b's goes to the one after.
                    let ta = m.cornerVerts[along ? m.prevCorner(ca, face: f) : m.nextCorner(ca, face: f)]
                    let tb = m.cornerVerts[along ? m.nextCorner(cb, face: f) : m.prevCorner(cb, face: f)]
                    for (v, target) in [(a, ta), (b, tb)] where !onChain.contains(target) {
                        let p = m.positions[Int(target)]
                        if along { sumA[v] = ((sumA[v]?.0 ?? .zero) + p, (sumA[v]?.1 ?? 0) + 1) } else { sumB[v] = ((sumB[v]?.0 ?? .zero) + p, (sumB[v]?.1 ?? 0) + 1) }
                    }
                }
            }
            for v in verts {
                index[v] = items.count
                items.append(Item(vertex: v, start: m.positions[Int(v)], sideA: sumA[v].map { $0.0 / Float($0.1) },
                                  sideB: sumB[v].map { $0.0 / Float($0.1) }, chain: chain))
            }
            chain += 1
        }
        // Lone selected vertices: along one of their edges.
        for v in 0..<m.vertexCount where m.isSelected(vertex: v) && index[Int32(v)] == nil {
            let ends = t.edges(ofVertex: v).map { m.positions[Int(MeshTopology.other(m, edge: Int($0), from: Int32(v)))] }
            guard !ends.isEmpty else { continue }
            items.append(Item(vertex: Int32(v), start: m.positions[v], ends: ends, chain: -1))
        }
        guard !items.isEmpty else { return nil }
        self.items = items
        chains = chain
    }

    /// Each chain's sides turned so side A goes the same way on screen for all of them (as the first chain's), and
    /// that way and side B's, as the mean of the vertices' moves at factor 1 and −1 on screen (`project`: a point to
    /// the view, nil behind it).
    package mutating func alignSides(_ project: (SIMD3<Float>) -> SIMD2<Float>?) -> (a: SIMD2<Float>, b: SIMD2<Float>) {
        func axis(_ chain: Int, _ a: Bool) -> SIMD2<Float> {
            var s = SIMD2<Float>.zero, n = 0
            for i in items where i.chain == chain {
                guard let target = a ? i.sideA : i.sideB, let p = project(target), let q = project(i.start) else { continue }
                s += p - q
                n += 1
            }
            return n > 0 ? s / Float(n) : .zero
        }
        var ref = SIMD2<Float>.zero
        for c in 0..<chains {
            let dir = axis(c, true) - axis(c, false)
            if simd_length(ref) == 0 { ref = dir; continue }
            if simd_dot(dir, ref) < 0 {
                for k in items.indices where items[k].chain == c { (items[k].sideA, items[k].sideB) = (items[k].sideB, items[k].sideA) }
            }
        }
        var a = SIMD2<Float>.zero, b = SIMD2<Float>.zero
        for c in 0..<chains { a += axis(c, true); b += axis(c, false) }
        return chains > 0 ? (a / Float(chains), b / Float(chains)) : (.zero, .zero)
    }

    /// The vertices at `factor` (−1…1: toward side B … side A); lone vertices along the edge the screen direction
    /// `toward` (from where each starts, `project`ed) points down most, as far as it reaches along it.
    package func apply(to m: inout EditMesh, factor: Float, toward: SIMD2<Float> = .zero, project: ((SIMD3<Float>) -> SIMD2<Float>?)? = nil) {
        let f = max(-1, min(1, factor))
        for i in items {
            var p = i.start
            if i.chain >= 0 {
                if f > 0, let a = i.sideA { p = simd_mix(i.start, a, SIMD3(repeating: f)) }
                if f < 0, let b = i.sideB { p = simd_mix(i.start, b, SIMD3(repeating: -f)) }
            } else if let project, let s = project(i.start), simd_length(toward) > 0 {
                var best: (end: SIMD3<Float>, along: Float, score: Float)?
                for e in i.ends {
                    guard let q = project(e) else { continue }
                    let d = q - s, l2 = simd_length_squared(d)
                    guard l2 > 1e-6 else { continue }
                    let score = simd_dot(simd_normalize(d), simd_normalize(toward))
                    if score > (best?.score ?? 0) { best = (e, simd_dot(toward, d) / l2, score) }
                }
                if let b = best { p = simd_mix(i.start, b.end, SIMD3(repeating: max(0, min(1, b.along)))) }
            }
            m.positions[Int(i.vertex)] = p
        }
        m.touch()
    }
}
