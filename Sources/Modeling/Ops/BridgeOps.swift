import Foundation
import simd

/// Bridge Edge Loops: faces between loops of selected edges (two or more, each a closed loop or an open path), one
/// loop to the next nearest. With faces selected, those faces go and their boundaries are the loops (two caps of a
/// tube bridged into one). Loops of the same length get quads, turned and started so each vertex meets the nearest
/// one across; loops of different lengths are joined by walking both by length, a quad where both step, a triangle
/// where one does. The new faces turn the way the faces next to the loops do, and are selected.
extension EditMesh {
    /// Returns nil when done, else why it couldn't be (shown to the user).
    @discardableResult
    package mutating func bridgeEdgeLoops() -> String? {
        let t = MeshTopology(self)
        var removed = [Bool](repeating: false, count: faceCount)
        var edgeMask = [Bool](repeating: false, count: edgeCount)
        let faces = selectedFaces.filter { !isHidden(face: $0) }
        if !faces.isEmpty {
            // The selected faces' boundaries: the faces go.
            for f in faces { removed[f] = true }
            for loop in boundaryLoops(of: faces, topology: t) { for c in loop { edgeMask[Int(cornerEdges[c])] = true } }
        } else {
            for e in 0..<edgeCount where isSelected(edge: e) && !isHidden(edge: e) { edgeMask[e] = true }
        }
        var loops = EditMesh.chains(of: edgeMask, in: self)
        guard loops.count >= 2 else { return "Bridge Edge Loops: select two edge loops (or the faces between them)" }
        guard loops.allSatisfy({ $0.closed == loops[0].closed }) else { return "Bridge Edge Loops: the loops must all be closed, or all open" }
        // In a row: from the loop farthest from the rest, each to the nearest one left.
        let centres = loops.map { l in centre(l.verts.map { Int($0) }) }
        let mean = centres.reduce(.zero, +) / Float(centres.count)
        var order = [centres.indices.max { simd_distance(centres[$0], mean) < simd_distance(centres[$1], mean) }!]
        while order.count < loops.count {
            let last = centres[order.last!]
            order.append(centres.indices.filter { !order.contains($0) }.min { simd_distance(centres[$0], last) < simd_distance(centres[$1], last) }!)
        }
        loops = order.map { loops[$0] }

        var d = draft()
        d.clearFaces()
        for f in 0..<faceCount where !removed[f] {
            d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
        }
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        var made = 0
        for k in 0..<(loops.count - 1) {
            var a = loops[k].verts, b = loops[k + 1].verts
            let closed = loops[k].closed
            // Line b up with a: the same way round, and (closed, same length) started at a's nearest.
            EditMesh.align(&b, to: a, closed: closed, positions: positions)
            // Which way the faces turn: against the faces next to loop a (a face that runs a0 → a1 there means the
            // new one runs a1 → a0), else against those next to b, else so they face away from the loops' axis.
            var flip = false
            if let s = side(of: a, removed: removed, t) { flip = s } else if let s = side(of: b, removed: removed, t) { flip = !s } else {
                let ca = centre(a.map { Int($0) }), cb = centre(b.map { Int($0) })
                let p0 = positions[Int(a[0])], p1 = positions[Int(a[1 % a.count])], q0 = positions[Int(b[0])]
                let n = simd_cross(p1 - p0, q0 - p0), mid = (ca + cb) / 2
                flip = simd_dot(n, (p0 + p1 + q0) / 3 - mid) < 0
            }
            // The material and shading of a face next to the loops, if any.
            let near = (a + b).lazy.compactMap { v in t.faces(ofVertex: Int(v)).first { !removed[$0] } }.first
            let material = near.map { faceMaterial[$0] } ?? 0, flags = (near.map { faceFlags[$0] } ?? 0) & ~(Flag.select | Flag.hide)
            func add(_ verts: [Int32]) {
                d.addFace(flip ? verts.reversed() : verts, material: material, set: near.map { faceSet[$0] } ?? 0, flags: flags | Flag.select)
                made += 1
            }
            if closed { a.append(a[0]); b.append(b[0]) }
            if a.count == b.count {
                for i in 0..<(a.count - 1) { add([a[i], a[i + 1], b[i + 1], b[i]]) }
            } else {
                // By length along each: step the one whose next vertex comes first.
                func fractions(_ l: [Int32]) -> [Float] {
                    var s: [Float] = [0]
                    for i in 1..<l.count { s.append(s[i - 1] + simd_distance(positions[Int(l[i - 1])], positions[Int(l[i])])) }
                    return s.map { $0 / max(s.last!, 1e-12) }
                }
                let fa = fractions(a), fb = fractions(b)
                var i = 0, j = 0
                while i < a.count - 1 || j < b.count - 1 {
                    let stepA = j == b.count - 1 || (i < a.count - 1 && fa[i + 1] <= fb[j + 1])
                    if stepA { add([a[i], a[i + 1], b[j]]); i += 1 } else { add([a[i], b[j + 1], b[j]]); j += 1 }
                }
            }
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        self = mesh
        return made > 0 ? nil : "Bridge Edge Loops: nothing to bridge"
    }

    /// Whether the faces next to `loop` (not `removed`) run along it (a face with corners loop[0] then loop[1]):
    /// nil if none touch it.
    private func side(of loop: [Int32], removed: [Bool], _ t: MeshTopology) -> Bool? {
        for k in 0..<(loop.count - 1) {
            guard let e = t.edge(self, loop[k], loop[k + 1]) else { continue }
            for c in t.corners(ofEdge: e) where !removed[Int(t.cornerFace[Int(c)])] {
                return cornerVerts[Int(c)] == loop[k]
            }
        }
        return nil
    }

    /// The edges of `mask` as chains of vertices: closed loops (the first vertex not repeated) and open paths.
    /// Branching vertices end the chains through them.
    static func chains(of mask: [Bool], in m: EditMesh) -> [(verts: [Int32], closed: Bool)] {
        var at: [Int32: [Int]] = [:]
        for e in 0..<m.edgeCount where mask[e] {
            at[m.edges[e].x, default: []].append(e)
            at[m.edges[e].y, default: []].append(e)
        }
        var used = Set<Int>()
        var out: [(verts: [Int32], closed: Bool)] = []
        let starts = at.keys.sorted { (at[$0]!.count != 2 ? 0 : 1, $0) < (at[$1]!.count != 2 ? 0 : 1, $1) }
        for s in starts {
            guard let first = at[s]?.first(where: { !used.contains($0) }) else { continue }
            var verts: [Int32] = [s]
            var edge = first, v = s
            while !used.contains(edge) {
                used.insert(edge)
                v = MeshTopology.other(m, edge: edge, from: v)
                verts.append(v)
                guard at[v]?.count == 2, let next = at[v]?.first(where: { !used.contains($0) }) else { break }
                edge = next
            }
            let closed = verts.count > 2 && verts.first == verts.last
            if closed { verts.removeLast() }
            out.append((verts, closed))
        }
        return out
    }

    /// `b` turned (and, closed, started) to line up with `a`: the way and start with the least distance between
    /// the vertices that will face each other.
    static func align(_ b: inout [Int32], to a: [Int32], closed: Bool, positions p: [SIMD3<Float>]) {
        func cost(_ c: [Int32]) -> Float {
            if c.count == a.count { return zip(a, c).reduce(0) { $0 + simd_distance(p[Int($1.0)], p[Int($1.1)]) } }
            // Different lengths: the ends (and, closed, the starts) by fraction.
            let n = 8
            return (0..<n).reduce(0) { s, k in
                let x = Float(k) / Float(n - 1)
                return s + simd_distance(p[Int(a[Int(x * Float(a.count - 1))])], p[Int(c[Int(x * Float(c.count - 1))])])
            }
        }
        var best = b, bestCost = cost(b)
        for candidate in [b, Array(b.reversed())] {
            for shift in 0..<(closed ? candidate.count : 1) {
                let c = Array(candidate[shift...] + candidate[..<shift])
                let k = cost(c)
                if k < bestCost { best = c; bestCost = k }
            }
        }
        b = best
    }
}
