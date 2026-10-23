import Foundation
import simd

/// M (merge), F (fill), J (connect), Subdivide, normals (Shift-N, Alt-N), triangulate (Ctrl-T) and its reverse
/// (Alt-J), duplicate (Shift-D), separate (P), join (Ctrl-J), edge marks (seams, sharp, crease) and shading.
package enum MergeKind: String, CaseIterable {
    case center, cursor, collapse, byDistance
    package var title: String {
        switch self {
        case .center: "At Center"
        case .cursor: "At Cursor"
        case .collapse: "Collapse"
        case .byDistance: "By Distance"
        }
    }
}

extension EditMesh {
    // MARK: Merge

    /// Merge the selected vertices: all at their centre or the 3D cursor, each connected group at its own centre
    /// (collapse), or those closer than `distance` (by distance). Faces left with fewer than three corners go, and so
    /// do faces that became the same face. Returns how many vertices went.
    @discardableResult
    package mutating func merge(_ kind: MergeKind, cursor: SIMD3<Float> = .zero, distance: Float = 1e-4) -> Int {
        let sel = selectedVertices
        guard sel.count > 1 else { return 0 }
        var target = Array(0..<Int32(vertexCount))
        var newPositions = positions
        switch kind {
        case .center, .cursor:
            let p = kind == .cursor ? cursor : centre(sel)
            for v in sel { target[v] = Int32(sel[0]) }
            newPositions[sel[0]] = p
        case .collapse:
            let t = MeshTopology(self)
            var group = [Int](repeating: -1, count: vertexCount)
            for v in sel where group[v] < 0 {
                var stack = [v], members: [Int] = []
                group[v] = v
                while let x = stack.popLast() {
                    members.append(x)
                    for e in t.edges(ofVertex: x) where isSelected(edge: Int(e)) {
                        let o = Int(MeshTopology.other(self, edge: Int(e), from: Int32(x)))
                        if group[o] < 0 { group[o] = v; stack.append(o) }
                    }
                }
                newPositions[v] = centre(members)
                for m in members { target[m] = Int32(v) }
            }
        case .byDistance:
            // A grid of cells the size of the distance: a vertex merges into the first within reach.
            let cell = max(distance, 1e-9)
            var grid: [SIMD3<Int32>: [Int]] = [:]
            for v in sel {
                let p = positions[v]
                let q = SIMD3<Int32>((p / cell).rounded(.down))
                var found: Int?
                search: for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    for o in grid[q &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(positions[o], p) <= distance {
                        found = o
                        break search
                    }
                } } }
                if let found { target[v] = Int32(found) } else { grid[q, default: []].append(v) }
            }
        }
        var removed = 0
        for v in 0..<vertexCount where target[v] != Int32(v) { removed += 1 }
        guard removed > 0 else { return 0 }
        var d = draft()
        d.positions = newPositions
        for c in 0..<d.cornerVerts.count { d.cornerVerts[c] = target[Int(d.cornerVerts[c])] }
        d.looseEdges = d.looseEdges.map { SIMD2(target[Int($0.x)], target[Int($0.y)]) }
        var attrs: [UInt64: (flags: UInt8, crease: Float)] = [:]
        for (k, a) in d.edgeAttributes {
            let x = target[Int(Int32(truncatingIfNeeded: k >> 32))], y = target[Int(Int32(truncatingIfNeeded: k & 0xFFFF_FFFF))]
            attrs[EditMesh.key(x, y)] = a
        }
        d.edgeAttributes = attrs
        var mesh = EditMesh(d)
        mesh.removeDuplicateFaces()
        // Merged-away vertices go; what they merged into stays (a lone vertex, if that is all that's left), and so
        // do loose ones.
        let loose = looseVertexMask(of: self, count: mesh.vertexCount)
        let selected = Set(sel)
        mesh.removeUnusedVertices(used: (0..<mesh.vertexCount).map { target[$0] == Int32($0) && (loose[$0] || selected.contains($0)) })
        mesh.flushSelection(from: .vertex)
        self = mesh
        return removed
    }

    /// Faces with the same vertices as an earlier one go.
    package mutating func removeDuplicateFaces() {
        var seen = Set<[Int32]>()
        var keep = [Bool](repeating: true, count: faceCount)
        for f in 0..<faceCount {
            let k = faceVerts(f).sorted()
            if !seen.insert(k).inserted { keep[f] = false }
        }
        guard keep.contains(false) else { return }
        var d = draft()
        d.clearFaces()
        for f in 0..<faceCount where keep[f] {
            d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
        }
        self = EditMesh(d)
    }

    // MARK: Fill and connect

    /// F: two selected vertices get an edge; selected edges that close a loop (or an open chain, closed) get a face;
    /// otherwise the selected vertices become one face round their centre. The new face turns to agree with a face it
    /// shares an edge with, or to face away from the mesh's centre.
    package mutating func fill() {
        let sel = selectedVertices
        guard sel.count >= 2 else { return }
        var d = draft()
        if sel.count == 2 {
            if MeshTopology(self).edge(self, Int32(sel[0]), Int32(sel[1])) == nil { d.looseEdges.append(SIMD2(Int32(sel[0]), Int32(sel[1]))) }
            self = EditMesh(d)
            flushSelection(from: .vertex)
            return
        }
        let t = MeshTopology(self)
        // Order: along the selected edges if they make one chain, else by angle round the centre in their plane.
        var order: [Int32] = []
        let selEdges = (0..<edgeCount).filter { isSelected(edge: $0) }
        var degree: [Int: Int] = [:]
        for e in selEdges { degree[Int(edges[e].x), default: 0] += 1; degree[Int(edges[e].y), default: 0] += 1 }
        let chain = selEdges.count >= 2 && degree.count == sel.count && degree.values.allSatisfy { $0 <= 2 }
            && degree.values.filter({ $0 == 1 }).count <= 2
        if chain {
            var start = degree.first { $0.value == 1 }?.key ?? Int(edges[selEdges[0]].x)
            var prev = -1
            order.append(Int32(start))
            while order.count < sel.count {
                guard let e = t.edges(ofVertex: start).first(where: { isSelected(edge: Int($0)) && Int(MeshTopology.other(self, edge: Int($0), from: Int32(start))) != prev && !order.contains(MeshTopology.other(self, edge: Int($0), from: Int32(start))) }) else { break }
                prev = start
                start = Int(MeshTopology.other(self, edge: Int(e), from: Int32(start)))
                order.append(Int32(start))
            }
        }
        if order.count != sel.count {
            let c = centre(sel)
            var n = SIMD3<Float>.zero
            for i in 0..<sel.count { n += simd_cross(positions[sel[i]] - c, positions[sel[(i + 1) % sel.count]] - c) }
            if simd_length(n) < 1e-9 { n = [0, 1, 0] }
            n = simd_normalize(n)
            let u = simd_normalize(abs(n.x) < 0.9 ? simd_cross(n, [1, 0, 0]) : simd_cross(n, [0, 1, 0])), w = simd_cross(n, u)
            order = sel.sorted { a, b in
                let pa = positions[a] - c, pb = positions[b] - c
                return atan2(simd_dot(pa, w), simd_dot(pa, u)) < atan2(simd_dot(pb, w), simd_dot(pb, u))
            }.map { Int32($0) }
        }
        // Agree with a neighbour across a shared edge: it runs a → b, so this face must run b → a.
        var flip: Bool?
        for i in 0..<order.count {
            let a = order[i], b = order[(i + 1) % order.count]
            if let e = t.edge(self, a, b), let c = t.corners(ofEdge: e).first {
                flip = cornerVerts[Int(c)] == a
                break
            }
        }
        if flip == nil {
            let mid = (bounds.lo + bounds.hi) / 2, c = centre(sel)
            var n = SIMD3<Float>.zero
            for i in 0..<order.count { n += simd_cross(positions[Int(order[i])], positions[Int(order[(i + 1) % order.count])]) }
            flip = simd_dot(n, c - mid) < 0
        }
        if flip == true { order.reverse() }
        for f in 0..<d.faceCount { d.faceFlags[f] &= ~Flag.select }
        d.addFace(order, flags: Flag.select | (faceFlags.first.map { $0 & Flag.smooth } ?? 0))
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        self = mesh
    }

    /// J: each face with two selected vertices that aren't neighbours is split in two between them.
    package mutating func connectVertices() {
        var d = draft()
        d.clearFaces()
        var changed = false
        for f in 0..<faceCount {
            let r = Array(corners(f))
            let picked = r.indices.filter { isSelected(vertex: Int(cornerVerts[r[$0]])) }
            let n = r.count
            if picked.count == 2, (picked[1] - picked[0]) % n != 1, (picked[0] - picked[1] + n) % n != 1 {
                let i = picked[0], j = picked[1]
                let first = Array(i...j).map { (cornerVerts[r[$0]], cornerUVs[r[$0]]) }
                let second = (Array(j..<n) + Array(0...i)).map { (cornerVerts[r[$0]], cornerUVs[r[$0]]) }
                d.addFace(first.map { (v: $0.0, uv: $0.1) }, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
                d.addFace(second.map { (v: $0.0, uv: $0.1) }, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
                changed = true
            } else {
                d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
            }
        }
        guard changed else { return }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .vertex)
        self = mesh
    }

    // MARK: Subdivide

    /// Subdivide: each selected face split by its edges' midpoints and its centre (a quad into four, a triangle into
    /// four, an n-gon into n quads); faces next to it get the midpoints in their shared edges. `smoothness` pulls the
    /// new points toward a sphere through the old ones (Blender's Smoothness, roughly).
    package mutating func subdivide(smoothness: Float = 0) {
        let sel = selectedFaceMask
        guard sel.contains(true) else { return }
        let t = MeshTopology(self)
        let vn = vertexNormals()
        var d = draft()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        var mid = [Int32](repeating: -1, count: edgeCount)
        for f in 0..<faceCount where sel[f] {
            for c in corners(f) where mid[Int(cornerEdges[c])] < 0 {
                let e = Int(cornerEdges[c])
                let a = Int(edges[e].x), b = Int(edges[e].y)
                var p = (positions[a] + positions[b]) / 2
                if smoothness > 0 {
                    let l = simd_distance(positions[a], positions[b])
                    p += simd_normalize(vn[a] + vn[b]) * l * 0.25 * smoothness * (1 - simd_dot(vn[a], vn[b]))
                }
                mid[e] = d.addVertex(p, flags: Flag.select)
            }
        }
        _ = t
        d.clearFaces()
        for f in 0..<faceCount {
            let r = Array(corners(f))
            let mf = faceMaterial[f], sf = faceSet[f], ff = faceFlags[f] & ~Flag.select
            if sel[f] {
                let mids = r.map { c -> (v: Int32, uv: SIMD2<Float>) in
                    (mid[Int(cornerEdges[c])], (cornerUVs[c] + cornerUVs[nextCorner(c, face: f)]) / 2)
                }
                if r.count == 3 {
                    let k = r.map { (v: cornerVerts[$0], uv: cornerUVs[$0]) }
                    d.addFace([k[0], mids[0], mids[2]], material: mf, set: sf, flags: ff | Flag.select)
                    d.addFace([k[1], mids[1], mids[0]], material: mf, set: sf, flags: ff | Flag.select)
                    d.addFace([k[2], mids[2], mids[1]], material: mf, set: sf, flags: ff | Flag.select)
                    d.addFace([mids[0], mids[1], mids[2]], material: mf, set: sf, flags: ff | Flag.select)
                } else {
                    var cuv = SIMD2<Float>.zero
                    for c in r { cuv += cornerUVs[c] }
                    let centre = (v: d.addVertex(faceCenter(f), flags: Flag.select), uv: cuv / Float(r.count))
                    for (i, c) in r.enumerated() {
                        let prev = mids[(i + r.count - 1) % r.count]
                        d.addFace([(cornerVerts[c], cornerUVs[c]), mids[i], centre, prev], material: mf, set: sf, flags: ff | Flag.select)
                    }
                }
            } else {
                var out: [(v: Int32, uv: SIMD2<Float>)] = []
                for c in r {
                    out.append((cornerVerts[c], cornerUVs[c]))
                    let m = mid[Int(cornerEdges[c])]
                    if m >= 0 { out.append((m, (cornerUVs[c] + cornerUVs[nextCorner(c, face: f)]) / 2)) }
                }
                d.addFace(out, material: mf, set: sf, flags: ff)
            }
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        self = mesh
    }

    // MARK: Normals

    /// Flip the selected faces (Alt-N › Flip).
    package mutating func flipNormals(onlySelected: Bool = true) {
        var d = draft()
        for f in 0..<faceCount where !onlySelected || isSelected(face: f) {
            let r = Int(d.faceStart[f])..<Int(d.faceStart[f + 1])
            d.cornerVerts[r].reverse()
            d.cornerUVs[r].reverse()
        }
        self = EditMesh(d)
    }

    /// Recalculate Outside (Shift-N): each connected part's faces turned to agree with each other across their
    /// edges, then all of them turned if the part's volume comes out negative (it faced in). `inside` the other way.
    package mutating func recalculateNormals(onlySelected: Bool = true, inside: Bool = false) {
        let t = MeshTopology(self)
        var flip = [Bool](repeating: false, count: faceCount)
        var seen = [Bool](repeating: false, count: faceCount)
        let use = (0..<faceCount).map { !onlySelected || isSelected(face: $0) }
        for start in 0..<faceCount where use[start] && !seen[start] {
            var part: [Int] = []
            var stack = [start]
            seen[start] = true
            while let f = stack.popLast() {
                part.append(f)
                for c in corners(f) {
                    let e = Int(cornerEdges[c])
                    guard t.faceCount(ofEdge: e) == 2 else { continue }
                    for o in t.corners(ofEdge: e) where Int(t.cornerFace[Int(o)]) != f {
                        let g = Int(t.cornerFace[Int(o)])
                        guard use[g], !seen[g] else { continue }
                        // Same direction along the edge (taking flips into account): g must turn.
                        let sameDirection = cornerVerts[Int(o)] == cornerVerts[c]
                        flip[g] = sameDirection != flip[f]
                        seen[g] = true
                        stack.append(g)
                    }
                }
            }
            // The part's signed volume, as its faces now face.
            var volume: Float = 0
            for f in part {
                let r = Array(corners(f))
                let o = positions[Int(cornerVerts[r[0]])]
                for k in 1..<(r.count - 1) {
                    let a = positions[Int(cornerVerts[r[k]])], b = positions[Int(cornerVerts[r[k + 1]])]
                    volume += simd_dot(o, simd_cross(a, b)) * (flip[f] ? -1 : 1)
                }
            }
            if (volume < 0) != inside { for f in part { flip[f].toggle() } }
        }
        var d = draft()
        for f in 0..<faceCount where flip[f] {
            let r = Int(d.faceStart[f])..<Int(d.faceStart[f + 1])
            d.cornerVerts[r].reverse()
            d.cornerUVs[r].reverse()
        }
        self = EditMesh(d)
    }

    // MARK: Triangles and quads

    /// Ctrl-T: the selected faces as triangles.
    package mutating func triangulate(onlySelected: Bool = true) {
        var d = draft()
        d.clearFaces()
        var tri: [Int32] = []
        for f in 0..<faceCount {
            if (!onlySelected || isSelected(face: f)) && faceSize(f) > 3 {
                tri.removeAll(keepingCapacity: true)
                triangulate(f, into: &tri)
                for k in 0..<(tri.count / 3) {
                    let cs = [Int(tri[3 * k]), Int(tri[3 * k + 1]), Int(tri[3 * k + 2])]
                    d.addFace(cs.map { cornerVerts[$0] }, uvs: cs.map { cornerUVs[$0] }, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
                }
            } else {
                d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
            }
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        self = mesh
    }

    /// Alt-J: selected triangles joined in pairs across their edges into quads, flattest pairs first (Blender's
    /// face and shape thresholds, 40°).
    package mutating func trianglesToQuads(maxAngle: Float = 40 * .pi / 180) {
        let t = MeshTopology(self)
        let fn = faceNormals()
        var candidates: [(cost: Float, e: Int)] = []
        for e in 0..<edgeCount where t.faceCount(ofEdge: e) == 2 && edgeFlags[e] & (Flag.sharp | Flag.seam) == 0 {
            let fs = t.faces(ofEdge: e)
            guard fs.allSatisfy({ faceSize($0) == 3 && isSelected(face: $0) }), faceMaterial[fs[0]] == faceMaterial[fs[1]] else { continue }
            let bend = acos(max(-1, min(1, simd_dot(fn[fs[0]], fn[fs[1]]))))
            guard bend <= maxAngle else { continue }
            candidates.append((bend, e))
        }
        candidates.sort { $0.cost < $1.cost }
        var used = [Bool](repeating: false, count: faceCount)
        var quads: [(Int, [(v: Int32, uv: SIMD2<Float>)])] = []
        for (_, e) in candidates {
            let cs = t.corners(ofEdge: e).map { Int($0) }
            let f0 = Int(t.cornerFace[cs[0]]), f1 = Int(t.cornerFace[cs[1]])
            guard !used[f0], !used[f1] else { continue }
            // f0: a b c with edge a → b; f1: b a d. The quad: a d b c... as a, (f1's third), b, (f0's third).
            let c0 = cs[0], c1 = cs[1]
            let a = (cornerVerts[c0], cornerUVs[c0]), b = (cornerVerts[nextCorner(c0, face: f0)], cornerUVs[nextCorner(c0, face: f0)])
            let third0 = prevCorner(c0, face: f0), third1 = prevCorner(c1, face: f1)
            let c = (cornerVerts[third0], cornerUVs[third0]), dv = (cornerVerts[third1], cornerUVs[third1])
            let quad = [a, dv, b, c].map { (v: $0.0, uv: $0.1) }
            // Convex only.
            let p = quad.map { positions[Int($0.v)] }
            let n = fn[f0] + fn[f1]
            var convex = true
            for i in 0..<4 where simd_dot(simd_cross(p[(i + 1) % 4] - p[i], p[(i + 2) % 4] - p[(i + 1) % 4]), n) <= 0 { convex = false }
            guard convex else { continue }
            used[f0] = true
            used[f1] = true
            quads.append((f0, quad))
        }
        guard !quads.isEmpty else { return }
        var d = draft()
        d.clearFaces()
        for f in 0..<faceCount where !used[f] {
            d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
        }
        for (f, q) in quads { d.addFace(q, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f]) }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        self = mesh
    }

    // MARK: Copies and parts

    /// Shift-D: the selection copied (its faces, edges and vertices); the copy is selected, the original not.
    package mutating func duplicateSelection() {
        let sel = selectedVertices
        guard !sel.isEmpty else { return }
        var d = draft()
        var map = [Int32](repeating: -1, count: vertexCount)
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        for f in 0..<d.faceCount { d.faceFlags[f] &= ~Flag.select }
        for v in sel { map[v] = d.addVertex(positions[v], flags: Flag.select) }
        let t = MeshTopology(self)
        for f in 0..<faceCount where isSelected(face: f) {
            d.addFace(corners(f).map { map[Int(cornerVerts[$0])] }, uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f],
                      set: faceSet[f], flags: faceFlags[f] | Flag.select)
        }
        for e in 0..<edgeCount where isSelected(edge: e) && !t.faces(ofEdge: e).contains(where: { isSelected(face: $0) }) {
            d.looseEdges.append(SIMD2(map[Int(edges[e].x)], map[Int(edges[e].y)]))
            if edgeFlags[e] != 0 || edgeCrease[e] != 0 {
                d.edgeAttributes[EditMesh.key(map[Int(edges[e].x)], map[Int(edges[e].y)])] = (edgeFlags[e], edgeCrease[e])
            }
        }
        // Copy face edges' marks too.
        for f in 0..<faceCount where isSelected(face: f) {
            for c in corners(f) {
                let e = Int(cornerEdges[c])
                if edgeFlags[e] & ~Flag.select != 0 || edgeCrease[e] != 0 {
                    d.edgeAttributes[EditMesh.key(map[Int(edges[e].x)], map[Int(edges[e].y)])] = (edgeFlags[e] | Flag.select, edgeCrease[e])
                }
            }
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .vertex)
        self = mesh
    }

    /// P › Selection: the selection taken out as a mesh of its own (returned); what is left stays.
    package mutating func separateSelection() -> EditMesh? {
        guard hasSelection else { return nil }
        // The part: the mesh without what isn't selected.
        var part = self
        part.invertSelection(mode: .vertex)
        part.delete(.vertices)
        part.selectAll(false)
        // What is left: without the selected faces (and what only they had), or the selected vertices.
        var left = self
        left.delete((0..<faceCount).contains { isSelected(face: $0) } ? .faces : .vertices)
        self = left
        return part
    }

    /// Ctrl-J: meshes put into one (each given in this mesh's space).
    package mutating func join(_ others: [EditMesh]) {
        var d = draft()
        for m in others {
            let base = Int32(d.positions.count)
            d.positions += m.positions
            d.vertFlags += m.vertFlags
            for f in 0..<m.faceCount {
                d.addFace(m.faceVerts(f).map { $0 + base }, uvs: Array(m.cornerUVs[m.corners(f)]), material: m.faceMaterial[f],
                          set: m.faceSet[f], flags: m.faceFlags[f])
            }
            let t = MeshTopology(m)
            for e in 0..<m.edgeCount {
                let k = EditMesh.key(m.edges[e].x + base, m.edges[e].y + base)
                if m.edgeFlags[e] != 0 || m.edgeCrease[e] != 0 { d.edgeAttributes[k] = (m.edgeFlags[e], m.edgeCrease[e]) }
                if t.faceCount(ofEdge: e) == 0 { d.looseEdges.append(m.edges[e] &+ SIMD2(repeating: base)) }
            }
        }
        self = EditMesh(d)
    }

    /// The mesh with every position moved by `m` (normals stay right for a transform that flips: the faces turn).
    package func transformed(by m: float4x4) -> EditMesh {
        var out = self
        for v in 0..<vertexCount {
            let p = m * SIMD4(positions[v], 1)
            out.positions[v] = SIMD3(p.x, p.y, p.z)
        }
        let det = simd_determinant(float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        if det < 0 { out.flipNormals(onlySelected: false) }
        out.touch()
        return out
    }

    // MARK: Marks

    package mutating func markEdges(_ flag: UInt8, _ on: Bool) {
        for e in 0..<edgeCount where isSelected(edge: e) {
            if on { edgeFlags[e] |= flag } else { edgeFlags[e] &= ~flag }
        }
        touch()
    }

    package mutating func setCrease(_ value: Float) {
        for e in 0..<edgeCount where isSelected(edge: e) { edgeCrease[e] = max(0, min(1, value)) }
        touch()
    }

    /// Shade Smooth / Flat: the selected faces (all, in object mode).
    package mutating func setSmooth(_ on: Bool, onlySelected: Bool = true) {
        for f in 0..<faceCount where !onlySelected || isSelected(face: f) {
            if on { faceFlags[f] |= Flag.smooth } else { faceFlags[f] &= ~Flag.smooth }
        }
        touch()
    }

    /// Shade Auto Smooth: smooth, with edges sharper than `angle` marked sharp.
    package mutating func autoSmooth(angle: Float) {
        let t = MeshTopology(self)
        let fn = faceNormals()
        setSmooth(true, onlySelected: false)
        for e in 0..<edgeCount {
            let fs = t.faces(ofEdge: e)
            guard fs.count == 2 else { continue }
            let a = acos(max(-1, min(1, simd_dot(fn[fs[0]], fn[fs[1]]))))
            if a > angle { edgeFlags[e] |= Flag.sharp } else { edgeFlags[e] &= ~Flag.sharp }
        }
        touch()
    }

    /// Material slot `slot` on the selected faces (Assign in the material panel).
    package mutating func assignMaterial(_ slot: Int) {
        for f in 0..<faceCount where isSelected(face: f) { faceMaterial[f] = UInt16(slot) }
        touch()
    }
}

extension EditMesh {
    /// Y: the selected faces cut loose from the rest (their own copies of the vertices they share with it).
    package mutating func splitSelection() {
        let sel = selectedFaceMask
        guard sel.contains(true) else { return }
        let t = MeshTopology(self)
        var d = draft()
        var copy = [Int32](repeating: -1, count: vertexCount)
        // A vertex used by both a selected and an unselected face gets a copy for the selected ones.
        for v in 0..<vertexCount {
            let fs = t.faces(ofVertex: v)
            if fs.contains(where: { sel[$0] }) && fs.contains(where: { !sel[$0] }) { copy[v] = d.addVertex(positions[v], flags: vertFlags[v]) }
        }
        d.clearFaces()
        for f in 0..<faceCount {
            let vs = corners(f).map { c -> Int32 in
                let v = cornerVerts[c]
                return sel[f] && copy[Int(v)] >= 0 ? copy[Int(v)] : v
            }
            d.addFace(vs, uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
        }
        var mesh = EditMesh(d)
        for v in 0..<vertexCount where copy[v] >= 0 { mesh.setSelected(vertex: v, false) }
        mesh.flushSelection(from: .face)
        self = mesh
    }

    /// Smooth Vertices: each selected vertex moved `factor` of the way to the mean of its neighbours, `repeat` times.
    package mutating func smoothVertices(factor: Float = 0.5, repeat count: Int = 1) {
        let t = MeshTopology(self)
        let sel = selectedVertices
        guard !sel.isEmpty else { return }
        for _ in 0..<count {
            let p = positions
            for v in sel {
                let es = t.edges(ofVertex: v)
                guard !es.isEmpty else { continue }
                var mean = SIMD3<Float>.zero
                for e in es { mean += p[Int(MeshTopology.other(self, edge: Int(e), from: Int32(v)))] }
                mean /= Float(es.count)
                positions[v] = simd_mix(p[v], mean, SIMD3(repeating: factor))
            }
        }
        touch()
    }

    /// Adds `other` (in this mesh's space) as new geometry, selected alone: Add in edit mode.
    package mutating func add(_ other: EditMesh) {
        selectAll(false)
        var o = other
        o.selectAll(true)
        join([o])
        flushSelection(from: .vertex)
    }
}
